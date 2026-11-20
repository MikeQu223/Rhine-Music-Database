'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { PluginError } = require('./errors.cjs');

const { attachCompatibility } = require('./host.cjs');
const { checkCompatibility, createHostContext } = require('../plugins/sdk/compatibility.cjs');

const MAX_MANIFEST_BYTES = 1024 * 1024;
const LOAD_ERROR_REASONS = new Set([
    'MODULE_NOT_FOUND',
    'ERR_MODULE_NOT_FOUND',
    'ERR_REQUIRE_ESM',
    'ERR_DLOPEN_FAILED',
    'SyntaxError',
    'ReferenceError',
    'TypeError',
]);

function overlappingPrefix(values) {
    for (let index = 0; index < values.length; index++) {
        for (let other = index + 1; other < values.length; other++) {
            const left = values[index];
            const right = values[other];
            if (left.startsWith(right + '/') || right.startsWith(left + '/')) {
                return [left, right];
            }
        }
    }
    return null;
}

function findConflict(values, owners, id, overlap = false) {
    for (const value of values) {
        if (owners.has(value) && owners.get(value) !== id) {
            return value;
        }
        if (overlap) {
            for (const [other, owner] of owners) {
                if (owner !== id && (value.startsWith(other + '/') || other.startsWith(value + '/'))) {
                    return value;
                }
            }
        }
    }
    return null;
}

function entryPath(directory, entryFile) {
    try {
        let current = directory;
        if (!fs.lstatSync(current).isDirectory()) {
            return null;
        }
        for (const part of entryFile.split('/')) {
            current = path.join(current, part);
            if (fs.lstatSync(current).isSymbolicLink()) {
                return null;
            }
        }
        return fs.lstatSync(current).isFile() ? current : null;
    } catch {
        // 插件文件可能已被移除或不可访问，此时不能执行入口。
        return null;
    }
}

function readManifest(directory) {
    const file = path.join(directory, 'manifest.json');
    const info = fs.lstatSync(file, { throwIfNoEntry: false });
    if (!info) {
        return undefined;
    }
    if (!info.isFile() || info.size > MAX_MANIFEST_BYTES) {
        throw new Error('manifest 必须是限制大小内的普通文件');
    }
    return JSON.parse(fs.readFileSync(file, 'utf8'));
}

/**
 * 通用插件 Registry：只扫描 manifest，不包含平台语义。
 * 插件目录由构建/部署层决定；冲突或版本不兼容的包在发现阶段整体拒绝，避免静默覆盖。
 */
class PluginRegistry {
    constructor(pluginsRoot, options = {}) {
        this.pluginsRoot = pluginsRoot;
        this.userRoot = options.userRoot || '';
        this.disabled = new Set(options.disabled || []);
        this.context = options.context || createHostContext({ apiVersion: options.apiVersion });
        this.entries = new Map();
        this.modules = new Map();
        this.loadFailures = new Map();
        this.legacy = new Map();
        this.prefixes = new Map();
        this.problems = [];
        this.discover();
    }

    problem(directory, id, code, message) {
        this.problems.push({ directory, id: typeof id === 'string' ? id : null, code, message });
    }

    // 替换同 id 插件时，候选仍须检查与其他插件的路由冲突。
    routeConflict(manifest) {
        const legacyRoutes = manifest.routes?.legacyRoutes || [];
        const prefixRoutes = manifest.routes?.prefixes || [];
        return (
            overlappingPrefix(prefixRoutes)?.[0] ||
            findConflict(legacyRoutes, this.legacy, manifest.id) ||
            findConflict(prefixRoutes, this.prefixes, manifest.id, true)
        );
    }

    discover() {
        this.entries.clear();
        this.modules.clear();
        this.loadFailures.clear();
        this.legacy.clear();
        this.prefixes.clear();
        this.problems = [];
        const roots = [...new Set([this.userRoot, this.pluginsRoot].filter(Boolean))];
        const seenRoot = new Map();
        for (const root of roots) {
            let directories;
            try {
                directories = fs.readdirSync(root, { withFileTypes: true });
            } catch (error) {
                if (error.code !== 'ENOENT') {
                    this.problem('', null, 'plugin.directory', '插件目录无法扫描');
                }
                continue;
            }
            const candidates = directories
                .filter(
                    (entry) =>
                        entry.isDirectory() &&
                        !entry.name.startsWith('.') &&
                        entry.name !== 'sdk' &&
                        entry.name !== 'node_modules',
                )
                .sort((left, right) => left.name.localeCompare(right.name));
            for (const entry of candidates) {
                const directory = path.join(root, entry.name);
                let manifest;
                try {
                    manifest = readManifest(directory);
                } catch {
                    this.problem(entry.name, null, 'manifest.invalid', 'manifest 无法解析');
                    continue;
                }
                if (manifest === undefined) {
                    continue;
                }
                const compatibility = checkCompatibility(manifest, this.context);
                if (!compatibility.compatible) {
                    this.problem(entry.name, manifest?.id, compatibility.code, compatibility.message);
                    continue;
                }
                if (!entryPath(directory, manifest.entry.file)) {
                    this.problem(entry.name, manifest.id, 'plugin.load-failed', '插件入口缺失或路径无效');
                    continue;
                }
                if (seenRoot.has(manifest.id)) {
                    // 用户目录优先；同一目录内重复 id 仍视为冲突。
                    if (seenRoot.get(manifest.id) === root) {
                        this.problem(entry.name, manifest.id, 'plugin.conflict', '插件 id 重复');
                    }
                    continue;
                }
                if (this.disabled.has(manifest.id)) {
                    seenRoot.set(manifest.id, root);
                    continue;
                }
                if (this.routeConflict(manifest)) {
                    this.problem(entry.name, manifest.id, 'route.duplicate', '插件路由与其他插件冲突');
                    continue;
                }
                seenRoot.set(manifest.id, root);
                this.entries.set(manifest.id, { directory, manifest, compatibility });
                for (const route of manifest.routes?.legacyRoutes || []) {
                    this.legacy.set(route, manifest.id);
                }
                for (const route of manifest.routes?.prefixes || []) {
                    this.prefixes.set(route, manifest.id);
                }
            }
        }
    }

    getProblems() {
        return this.problems.map((problem) => ({ ...problem }));
    }

    status(id) {
        return this.entries.has(id) ? 'bundled' : 'missing';
    }

    /** 只有唯一一个插件声明 default 时才返回；多个默认视为配置错误，不猜。 */
    default() {
        const defaults = this.list().filter((manifest) => manifest.display?.default === true);
        return defaults.length === 1 ? defaults[0].id : null;
    }

    can(id, operation) {
        const entry = this.entries.get(id);
        if (!entry) {
            return false;
        }
        return (
            entry.manifest.operations?.[operation] === true ||
            entry.manifest.capabilities?.[operation] === true
        );
    }

    /** Native operation dispatch is allowlisted by manifest.operations only. */
    supportsOperation(id, operation) {
        const entry = this.entries.get(id);
        return !!entry && entry.manifest.operations?.[operation] === true;
    }

    providerForRoute(route) {
        const value = String(route || '');
        if (value.startsWith('/native/') || value.startsWith('/plugin/')) {
            const provider = value.split('/')[2] || '';
            return this.entries.has(provider) ? provider : '';
        }
        const exact = this.legacy.get(value);
        if (exact) {
            return exact;
        }
        let match = '';
        for (const [prefix, provider] of this.prefixes) {
            if ((value === prefix || value.startsWith(prefix + '/')) && prefix.length > match.length) {
                match = prefix;
            }
        }
        return match ? this.prefixes.get(match) : '';
    }

    cachePolicy(id) {
        return this.entries.get(id)?.manifest.cache || {};
    }

    credentialPolicy(id) {
        return this.entries.get(id)?.manifest.credentials || {};
    }

    list() {
        return [...this.entries.values()].map(({ manifest }) => manifest);
    }

    catalog() {
        return [...this.entries.values()];
    }

    has(id) {
        return this.entries.has(id);
    }

    legacyProvider(route) {
        return this.legacy.get(route) || null;
    }

    prefixProvider(route) {
        for (const { manifest } of this.entries.values()) {
            for (const prefix of manifest.routes?.prefixes || []) {
                if (route === prefix || route.startsWith(prefix + '/')) {
                    return { provider: manifest.id, route: route.slice(prefix.length) || '/' };
                }
            }
        }
        return null;
    }

    async load(id, host, options) {
        const entry = this.entries.get(id);
        if (!entry) {
            return null;
        }
        if (this.loadFailures.has(id)) {
            throw this.loadFailures.get(id);
        }
        try {
            return await this.loadEntry(entry, host, options);
        } catch (error) {
            const failure =
                error instanceof PluginError
                    ? error
                    : new PluginError(503, 'plugin.load-failed', '插件初始化失败');
            const firstFailure = this.loadFailures.get(id) || failure;
            this.loadFailures.set(id, firstFailure);
            throw firstFailure;
        }
    }

    loadFailure(id) {
        return this.loadFailures.get(id);
    }

    /** 候选和业务请求均走实际的入口加载与 create 契约。 */
    async loadEntry(entry, host, options) {
        const { manifest, directory } = entry;
        const compatibility = checkCompatibility(manifest, this.context);
        if (!compatibility.compatible) {
            throw new PluginError(503, compatibility.code, compatibility.message);
        }
        const entryFile = entryPath(directory, manifest.entry.file);
        if (!entryFile) {
            throw new PluginError(503, 'plugin.load-failed', '插件入口缺失或路径无效');
        }
        const id = manifest.id;
        let module = this.modules.get(id);
        if (!module) {
            module = await this.importModule(entryFile);
            this.modules.set(id, module);
        }
        attachCompatibility(host, structuredClone(manifest), this.context, compatibility);
        let adapter;
        try {
            adapter = await module.create(host, options);
        } catch {
            // 入口异常可能带有上游请求细节，只对宿主暴露固定诊断。
            throw new PluginError(503, 'plugin.load-failed', '插件初始化失败');
        }
        if (!adapter || typeof adapter.dispatchNative !== 'function') {
            throw new PluginError(503, 'plugin.load-failed', '插件初始化未提供 dispatchNative 接口');
        }
        if (
            (manifest.routes?.prefixes?.length || manifest.routes?.legacyRoutes?.length) &&
            typeof adapter.dispatchRoute !== 'function'
        ) {
            throw new PluginError(503, 'plugin.load-failed', '插件声明了路由但未提供 dispatchRoute 接口');
        }
        return adapter;
    }

    async importModule(entryFile) {
        let imported;
        try {
            imported = entryFile.endsWith('.cjs')
                ? require(entryFile)
                : await import(pathToFileURL(entryFile).href);
        } catch (error) {
            // 设备上没有控制台：附上安全的错误类型，便于区分缺依赖、语法不受支持和权限问题。
            const reason = [error?.code, error?.name].find((value) => LOAD_ERROR_REASONS.has(value));
            throw new PluginError(
                503,
                'plugin.load-failed',
                reason ? '插件加载失败（' + reason + '）' : '插件加载失败',
            );
        }
        const create = imported.create || imported.default?.create;
        if (typeof create !== 'function') {
            throw new PluginError(503, 'plugin.load-failed', '插件入口缺少 create');
        }
        return { create };
    }

    async dispatchNative(id, operation, args, host, options) {
        const adapter = await this.load(id, host, options);
        if (!adapter) {
            throw new PluginError(404, 'plugin.missing', '插件不可用');
        }
        return adapter.dispatchNative(operation, args);
    }

    async dispatchRoute(id, route, params, host, options) {
        const adapter = await this.load(id, host, options);
        if (!adapter) {
            throw new PluginError(404, 'plugin.missing', '插件不可用');
        }
        return adapter.dispatchRoute(route, params);
    }
}

module.exports = { PluginRegistry };
