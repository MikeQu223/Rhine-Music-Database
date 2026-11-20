'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { createHost } = require('./core/host.cjs');
const { PluginRegistry } = require('./core/registry.cjs');
const { preparePackage, validatePluginDirectory } = require('./plugin-package.cjs');
const { checkCompatibility, compareVersions, createHostContext } = require('./plugins/sdk/compatibility.cjs');

function controlFailure(code, message) {
    return Object.assign(new Error(message), { code });
}

function createRegistry(message, context) {
    const bundled = message.root ? path.join(message.root, 'MusicBridge', 'local-plugins') : '';
    return new PluginRegistry(bundled, {
        context,
        userRoot: message.userRoot,
        disabled: message.disabled,
    });
}

function inspectCompatibility(manifest, context, message) {
    const compatibility = checkCompatibility(manifest, context, { legacy: !message.requireDeclarations });
    if (!compatibility.compatible) {
        throw controlFailure(compatibility.code, compatibility.message);
    }
    if (createRegistry(message, context).routeConflict(manifest)) {
        throw controlFailure('route.duplicate', '插件声明的路由与当前已启用的插件冲突');
    }
    return compatibility;
}

/** 用户确认后运行 create，使用独立的运行时和无账号的宿主上下文。 */
async function initialize(message, context) {
    const directory = message.path;
    const manifest = await validatePluginDirectory(directory, {
        host: context,
        expected: message.expected,
        requireDeclarations: message.requireDeclarations,
    });
    inspectCompatibility(manifest, context, message);
    const probeParent = message.scratchPath || path.dirname(directory);
    const probeData = await fs.mkdtemp(path.join(probeParent, '.rhine-plugin-probe-'));
    try {
        const env = Object.fromEntries(
            Object.entries(manifest.runtime?.env || {}).map(([key, value]) => [
                key,
                value.replaceAll('$variant', '').replaceAll('$dataDir', probeData),
            ]),
        );
        const host = createHost({ authenticated: false, env }, () =>
            Promise.reject(new Error('插件初始化验证期间音乐接口不可用')),
        );
        const adapter = await createRegistry({}, context).loadEntry({ directory, manifest }, host);
        if (typeof adapter.dispose === 'function') {
            await adapter.dispose();
        }
    } catch (error) {
        // 插件异常可能包含环境、请求等数据，验证结果仅返回稳定的加载错误。
        const fallback = '插件初始化失败，请联系发布者检查入口与运行依赖';
        throw controlFailure(
            'plugin.load-failed',
            error?.errorKey === 'plugin.load-failed' ? error.message : fallback,
        );
    } finally {
        await fs.rm(probeData, { recursive: true, force: true });
    }
    return { initialized: true };
}

/** 处理桥接控制请求。控制请求与音乐路由、会话缓存和账号状态相互独立。 */
async function executePluginControl(message) {
    const context = createHostContext({ clientVersion: message.clientVersion, platform: message.platform });
    if (message.control === 'plugins.compare') {
        const comparisons = Object.fromEntries(
            Object.entries(message.pairs || {}).map(([key, pair]) => [
                key,
                Array.isArray(pair) ? compareVersions(pair[0], pair[1]) : null,
            ]),
        );
        return { comparisons };
    }
    if (message.control === 'plugins.discover') {
        const registry = createRegistry(message, context);
        return { accepted: registry.catalog(), problems: registry.getProblems() };
    }
    if (message.control === 'plugins.validate') {
        const prepared = await preparePackage(message.path, message.stagedPath, {
            kind: message.kind,
            expected: message.expected,
            host: context,
        });
        try {
            const compatibility = inspectCompatibility(prepared.manifest, context, {
                ...message,
                requireDeclarations: prepared.format === 'zip',
            });
            return { ...prepared, compatibility };
        } catch (error) {
            await fs.rm(message.stagedPath, { recursive: true, force: true });
            throw error;
        }
    }
    if (message.control === 'plugins.inspect') {
        const manifest = await validatePluginDirectory(message.path, {
            expected: message.expected,
            host: context,
            requireDeclarations: message.requireDeclarations,
        });
        const compatibility = inspectCompatibility(manifest, context, message);
        return { manifest, compatibility };
    }
    if (message.control === 'plugins.initialize') {
        return initialize(message, context);
    }
    throw controlFailure('plugin.control', '未知的插件校验请求');
}

module.exports = { executePluginControl };
