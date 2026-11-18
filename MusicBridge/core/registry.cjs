'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { PluginError } = require('./errors.cjs');

// 与 plugins/sdk/contract-lock.json 的 apiVersion 保持同步。
const HOST_API_VERSION = '2.0';
const API_VERSION = /^(\d+)\.(\d+)$/;
const PROVIDER_ID = /^[a-z0-9-]{1,40}$/;

function parseVersion(value) {
    const match = API_VERSION.exec(String(value || ''));
    return match ? { major: Number(match[1]), minor: Number(match[2]) } : null;
}

/** 插件要求的 apiVersion 不能高于 host，且必须同一主版本。 */
function compatibleVersion(required, host) {
    return !!required && !!host && required.major === host.major && required.minor <= host.minor;
}

function isStringArray(value) {
    return Array.isArray(value) && value.every((entry) => typeof entry === 'string' && entry.startsWith('/'));
}

function duplicateEntry(values) {
    const seen = new Set();
    for (const value of values) {
        if (seen.has(value)) {
            return value;
        }
        seen.add(value);
    }
    return null;
}

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

function findConflict(values, owners, overlap = false) {
    for (const value of values) {
        if (owners.has(value)) {
            return value;
        }
        if (overlap) {
            for (const other of owners.keys()) {
                if (value.startsWith(other + '/') || other.startsWith(value + '/')) {
                    return value;
                }
            }
        }
    }
    return null;
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
        this.apiVersion = options.apiVersion || HOST_API_VERSION;
        this.entries = new Map();
        this.modules = new Map();
        this.legacy = new Map();
        this.prefixes = new Map();
        this.problems = [];
        this.discover();
    }

    problem(directory, id, code, message) {
        this.problems.push({ directory, id: id || null, code, message });
    }

    validate(manifest) {
        if (!manifest || typeof manifest !== 'object') {
            return 'manifest 不是对象';
        }
        if (typeof manifest.id !== 'string' || !PROVIDER_ID.test(manifest.id)) {
            return '插件 id 无效';
        }
        if (manifest.id === 'local' || manifest.id === 'siren') {
            return '插件 id 为保留 id';
        }
        if (typeof manifest.version !== 'string' || !manifest.version) {
            return '插件版本无效';
        }
        if (typeof manifest.apiVersion !== 'string' || !API_VERSION.test(manifest.apiVersion)) {
            return 'apiVersion 无效';
        }
        if (!manifest.entry || typeof manifest.entry.file !== 'string' || !manifest.entry.file) {
            return '入口文件无效';
        }
        if (
            !isStringArray(manifest.routes?.legacyRoutes || []) ||
            !isStringArray(manifest.routes?.prefixes || [])
        ) {
            return '路由表无效';
        }
        return null;
    }

    discover() {
        this.entries.clear();
        this.modules.clear();
        this.legacy.clear();
        this.prefixes.clear();
        this.problems = [];
        const roots = [...new Set([this.userRoot, this.pluginsRoot].filter(Boolean))];
        const seenRoot = new Map();
        for (const root of roots) {
            if (!fs.existsSync(root)) {
                continue;
            }
            const directories = fs
                .readdirSync(root, { withFileTypes: true })
                .filter(
                    (entry) =>
                        entry.isDirectory() &&
                        !entry.name.startsWith('.') &&
                        entry.name !== 'sdk' &&
                        entry.name !== 'node_modules',
                )
                .sort((left, right) => left.name.localeCompare(right.name));
            for (const entry of directories) {
                const directory = path.join(root, entry.name);
                const manifestFile = path.join(directory, 'manifest.json');
                if (!fs.existsSync(manifestFile)) {
                    continue;
                }
                let manifest;
                try {
                    manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
                } catch {
                    this.problem(entry.name, null, 'manifest.invalid', 'manifest 无法解析');
                    continue;
                }
                const invalid = this.validate(manifest);
                if (invalid) {
                    this.problem(entry.name, manifest?.id, 'manifest.invalid', invalid);
                    continue;
                }
                if (
                    manifest.schemaVersion !== 2 ||
                    !compatibleVersion(parseVersion(manifest.apiVersion), parseVersion(this.apiVersion))
                ) {
                    this.problem(
                        entry.name,
                        manifest.id,
                        'plugin.incompatible',
                        '插件版本与当前 host 不兼容',
                    );
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
                const legacyRoutes = manifest.routes?.legacyRoutes || [];
                const prefixRoutes = manifest.routes?.prefixes || [];
                const duplicate = duplicateEntry(legacyRoutes) || duplicateEntry(prefixRoutes);
                const overlap = overlappingPrefix(prefixRoutes);
                const conflict =
                    findConflict(legacyRoutes, this.legacy) ||
                    findConflict(prefixRoutes, this.prefixes, true);
                if (duplicate || overlap || conflict) {
                    this.problem(entry.name, manifest.id, 'route.duplicate', '插件路由与其他插件冲突');
                    continue;
                }
                seenRoot.set(manifest.id, root);
                this.entries.set(manifest.id, { directory, manifest });
                for (const route of legacyRoutes) {
                    this.legacy.set(route, manifest.id);
                }
                for (const route of prefixRoutes) {
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
        let module = this.modules.get(id);
        if (!module) {
            module = await this.importModule(entry);
            this.modules.set(id, module);
        }
        host.manifest = entry.manifest;
        let adapter;
        try {
            adapter = await module.create(host, options);
        } catch (error) {
            if (error instanceof PluginError) {
                throw error;
            }
            throw new PluginError(503, 'plugin.load-failed', '插件初始化失败');
        }
        if (!adapter) {
            throw new PluginError(503, 'plugin.load-failed', '插件初始化失败');
        }
        return adapter;
    }

    async importModule(entry) {
        const entryFile = path.join(entry.directory, entry.manifest.entry.file);
        let imported;
        try {
            imported = entryFile.endsWith('.cjs')
                ? require(entryFile)
                : await import(pathToFileURL(entryFile).href);
        } catch (error) {
            // 设备上没有控制台：附上安全的错误类型，便于区分缺依赖、语法不受支持和权限问题。
            const name = error?.name === 'Error' ? '' : String(error?.name || '');
            const reason = String(error?.code || name)
                .replace(/[^A-Za-z_]/g, '')
                .slice(0, 40);
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
