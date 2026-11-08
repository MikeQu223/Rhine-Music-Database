'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

/**
 * 通用插件 Registry：只扫描 manifest，不包含平台语义。
 * 插件目录由构建/部署层决定；P1 使用 MusicBridge/plugins 下的本地试点包。
 */
class PluginRegistry {
    constructor(pluginsRoot) {
        this.pluginsRoot = pluginsRoot;
        this.entries = new Map();
        this.modules = new Map();
        this.legacy = new Map();
        this.discover();
    }

    discover() {
        if (!fs.existsSync(this.pluginsRoot)) {
            return;
        }
        for (const entry of fs.readdirSync(this.pluginsRoot, { withFileTypes: true })) {
            if (!entry.isDirectory() || entry.name === 'sdk' || entry.name === 'node_modules') {
                continue;
            }
            const directory = path.join(this.pluginsRoot, entry.name);
            const manifestFile = path.join(directory, 'manifest.json');
            if (!fs.existsSync(manifestFile)) {
                continue;
            }
            try {
                const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
                if (manifest && manifest.id) {
                    this.entries.set(manifest.id, { directory, manifest });
                    for (const route of manifest.routes?.legacyRoutes || []) {
                        this.legacy.set(route, manifest.id);
                    }
                }
            } catch {
                // 损坏的 manifest 不应阻塞其他插件；加载时再给出明确错误。
            }
        }
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
            const entryFile = path.join(entry.directory, entry.manifest.entry.file);
            const imported = entryFile.endsWith('.cjs')
                ? require(entryFile)
                : await import(pathToFileURL(entryFile).href);
            const create = imported.create || imported.default?.create;
            if (typeof create !== 'function') {
                throw new Error('Plugin entry must export create(host)');
            }
            module = { create };
            this.modules.set(id, module);
        }
        host.manifest = entry.manifest;
        const adapter = await module.create(host, options);
        if (!adapter) {
            throw new Error('Plugin create(host) returned no adapter');
        }
        return adapter;
    }

    async dispatchNative(id, operation, args, host, options) {
        const adapter = await this.load(id, host, options);
        if (!adapter) {
            throw new Error('未知插件：' + id);
        }
        return adapter.dispatchNative(operation, args);
    }

    async dispatchRoute(id, route, params, host, options) {
        const adapter = await this.load(id, host, options);
        if (!adapter) {
            throw new Error('未知插件：' + id);
        }
        return adapter.dispatchRoute(route, params);
    }
}

module.exports = { PluginRegistry };
