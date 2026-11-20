const { AsyncLocalStorage } = require('node:async_hooks');
const playbackDiagnosticContext = new AsyncLocalStorage();
const pluginLoadFailureResponses = new WeakMap();

process.env.LOG_LEVEL = 'silent';
process.env.JSON_LOG = 'true';
delete process.env.LOG_FILE;
const path = require('node:path');
const readline = require('node:readline');
const { PluginRegistry } = require('./core/registry.cjs');
const { createHost } = require('./core/host.cjs');
const { assertValid } = require('./plugins/sdk/models.cjs');
const { createHostContext } = require('./plugins/sdk/compatibility.cjs');
const {
    errorBody,
    pluginMissing,
    providerUnsupported,
    routeInvalid,
    routeUnknown,
} = require('./core/errors.cjs');
function buildRegistry({ clientVersion, platform, userRoot, disabled }) {
    return new PluginRegistry(path.join(__dirname, 'local-plugins'), {
        context: createHostContext({ clientVersion, platform }),
        userRoot,
        disabled: typeof disabled === 'string' ? disabled.split(',').filter(Boolean) : disabled,
    });
}

let pluginRegistry;
let hostConfiguration = {
    clientVersion: process.env.RHINE_CLIENT_VERSION,
    platform: process.env.RHINE_PLATFORM,
    userRoot: process.env.RHINE_USER_PLUGINS,
    disabled: process.env.RHINE_DISABLED_PLUGINS,
};
// 上游诊断可能包含 URL 或 Cookie，禁止混入 IPC 消息和日志。
console.log = console.info = console.warn = console.error = console.debug = () => {};

/**
 * 根据私有 IPC 消息分派允许的音乐请求。
 * 沿用锁定上游的协议与错误语义，响应 Cookie 交给父进程隔离处理。
 */
function recordPluginDiagnostic(events, fields) {
    if (!events) {
        return;
    }
    if (events.length >= 64) {
        events.omitted = (events.omitted || 0) + 1;
        return;
    }
    const values = {};
    for (const [key, value] of Object.entries(fields || {})) {
        if (typeof value === 'number' && Number.isFinite(value)) {
            values[key] = value;
        } else if (typeof value === 'boolean') {
            values[key] = value;
        }
    }
    events.push(values);
}

function pluginDispatchFailure(provider, error, host) {
    const failure = pluginRegistry.loadFailure(provider);
    const response = {
        body: errorBody(error),
        cookies: host.receivedCookies(),
        ...host.secretState(),
    };
    // 记录可信加载结果，插件的普通请求错误和 secretState 不能触发宿主停用。
    if (failure && error === failure) {
        pluginLoadFailureResponses.set(response, {
            provider,
            errorKey: failure.errorKey,
            message: failure.message,
        });
    }
    return response;
}

async function dispatchPluginNative(message, provider, operation, args) {
    const events = playbackDiagnosticContext.getStore();
    const host = createHost(
        message,
        dispatchRequest,
        events ? (fields) => recordPluginDiagnostic(events, fields) : undefined,
    );
    try {
        if (!pluginRegistry.has(provider)) {
            return {
                body: pluginMissing(),
                cookies: host.receivedCookies(),
                ...host.secretState(),
            };
        }
        if (!pluginRegistry.supportsOperation(provider, operation)) {
            return {
                body: providerUnsupported(operation),
                cookies: host.receivedCookies(),
                ...host.secretState(),
            };
        }
        const plugin = await pluginRegistry.load(provider, host);
        const value = await plugin.dispatchNative(operation, args);
        if (operation !== 'request') {
            assertValid(operation, value);
        }
        if (events && ['playback', 'preview'].includes(operation)) {
            recordPluginDiagnostic(events, {
                operation: 4,
                workerOffsetMs: 0,
                serviceCode: 200,
                transportFailed: false,
            });
        }
        return {
            body: { code: 200, value: value ?? null },
            cookies: host.receivedCookies(),
            ...host.secretState(),
        };
    } catch (error) {
        if (events && ['playback', 'preview'].includes(operation)) {
            recordPluginDiagnostic(events, {
                operation: 4,
                workerOffsetMs: 0,
                serviceCode: typeof error?.code === 'number' ? error.code : 503,
                transportFailed: true,
            });
        }
        return pluginDispatchFailure(provider, error, host);
    }
}

async function dispatchPluginRoute(message, provider, route, params) {
    const events = playbackDiagnosticContext.getStore();
    const host = createHost(
        message,
        dispatchRequest,
        events ? (fields) => recordPluginDiagnostic(events, fields) : undefined,
    );
    try {
        const plugin = await pluginRegistry.load(provider, host);
        if (!plugin) {
            return { body: pluginMissing(), cookies: host.receivedCookies(), ...host.secretState() };
        }
        const body = await plugin.dispatchRoute(route, params || {});
        return { body, cookies: host.receivedCookies(), ...host.secretState() };
    } catch (error) {
        return pluginDispatchFailure(provider, error, host);
    }
}

async function dispatchRequest(message) {
    if (message.route === '/plugin') {
        return { body: routeInvalid(), cookies: [] };
    }
    if (message.route?.startsWith('/plugin/')) {
        const parts = String(message.route).split('/');
        const provider = parts[2];
        const operation = parts[3];
        if (!provider || !operation) {
            return { body: routeInvalid(), cookies: [] };
        }
        if (operation === 'route') {
            const route = '/' + parts.slice(4).join('/');
            if (route === '/') {
                return { body: routeInvalid(), cookies: [] };
            }
            return dispatchPluginRoute(message, provider, route, message.params?.params || {});
        }
        const host = createHost(message, dispatchRequest);
        try {
            const plugin = await pluginRegistry.load(provider, host);
            if (!plugin) {
                return {
                    body: pluginMissing(),
                    cookies: host.receivedCookies(),
                    ...host.secretState(),
                };
            }
            if (!pluginRegistry.supportsOperation(provider, operation)) {
                return {
                    body: providerUnsupported(operation),
                    cookies: host.receivedCookies(),
                    ...host.secretState(),
                };
            }
            const args = Array.isArray(message.params?.args) ? message.params.args : [];
            const value = await plugin.dispatchNative(operation, args);
            if (operation !== 'request') {
                assertValid(operation, value);
            }
            return {
                body: { code: 200, value: value ?? null },
                cookies: host.receivedCookies(),
                ...host.secretState(),
            };
        } catch (error) {
            return {
                body: errorBody(error),
                cookies: host.receivedCookies(),
                ...host.secretState(),
            };
        }
    }
    if (message.route === '/local/lyrics') {
        let content = message.params?.content;
        let encoding;
        const encoded = message.params?.contentBase64;
        if (encoded !== undefined) {
            if (
                typeof encoded !== 'string' ||
                encoded.length > 1333336 ||
                encoded.length % 4 !== 0 ||
                /[^A-Za-z0-9+/=]/.test(encoded)
            ) {
                return { body: { code: 400, message: '本地歌词字节无效' }, cookies: [] };
            }
            try {
                const bytes = Buffer.from(encoded, 'base64');
                if (bytes.toString('base64') !== encoded) {
                    return { body: { code: 400, message: '本地歌词字节无效' }, cookies: [] };
                }
                const decoded = require('./lyrics-text.cjs').decodeLyrics(bytes);
                if (decoded.text.trim()) {
                    content = decoded.text;
                    encoding = decoded.encoding;
                }
            } catch {
                // 可用的内嵌歌词仍是合法回退；没有内嵌文本时返回明确失败，不交付替换字符。
                if (typeof content !== 'string' || !content.trim()) {
                    return { body: { code: 400, message: '无法识别本地歌词编码' }, cookies: [] };
                }
            }
        }
        if (typeof content !== 'string' || content.length > 1000000) {
            return { body: { code: 400, message: '本地歌词内容无效' }, cookies: [] };
        }
        const result = require('./lyrics-format.cjs').normalizeLyrics('local', { lrc: { lyric: content } });
        if (result.document) {
            result.document.source = 'local';
            if (encoding) {
                result.document.encoding = encoding;
            }
        }
        return { body: result, cookies: [] };
    }
    if (message.route?.startsWith('/native/')) {
        const [, , provider, operation] = String(message.route).split('/');
        if (!provider || !operation) {
            return { body: routeInvalid(), cookies: [] };
        }
        if (pluginRegistry.has(provider)) {
            return dispatchPluginNative(message, provider, operation, message.params?.args || []);
        }
        if (provider === 'siren') {
            const client = await import('./client/dispatch.mjs');
            return client.dispatch(message, dispatch);
        }
        return { body: pluginMissing(), cookies: [] };
    }
    const prefix = pluginRegistry.prefixProvider(message.route);
    if (prefix) {
        return dispatchPluginRoute(message, prefix.provider, prefix.route, message.params || {});
    }
    const legacyProvider = pluginRegistry.legacyProvider(message.route);
    if (legacyProvider) {
        return dispatchPluginRoute(message, legacyProvider, message.route, message.params || {});
    }
    return { body: routeUnknown(), cookies: [] };
}

/** 诊断期间记录音源请求的数值结果 */
async function dispatch(message) {
    const events = playbackDiagnosticContext.getStore();
    if (!events || message.route?.startsWith('/native/')) {
        return dispatchRequest(message);
    }
    const started = performance.now();
    const values = { operation: 4, workerOffsetMs: started - events.started };
    try {
        const result = await dispatchRequest(message);
        const body = result?.body;
        for (const [source, target] of [
            ['code', 'serviceCode'],
            ['upstreamHttpStatus', 'upstreamHttpStatus'],
            ['upstreamCode', 'upstreamCode'],
        ]) {
            if (typeof body?.[source] === 'number' && Number.isFinite(body[source])) {
                values[target] = body[source];
            }
        }
        values.transportFailed = false;
        return result;
    } catch (error) {
        values.transportFailed = true;
        if (typeof error?.body?.code === 'number' && Number.isFinite(error.body.code)) {
            values.serviceCode = error.body.code;
        }
        const status = error?.response?.status;
        if (Number.isInteger(status) && status >= 100 && status <= 599) {
            values.upstreamHttpStatus = status;
        }
        values.networkError = Math.max(
            0,
            [
                'other',
                'ETIMEDOUT',
                'ECONNRESET',
                'ENOTFOUND',
                'EAI_AGAIN',
                'ECONNREFUSED',
                'ENETUNREACH',
                'EHOSTUNREACH',
                'ERR_CANCELED',
            ].indexOf(error?.code),
        );
        throw error;
    } finally {
        if (events.length < 64) {
            values.workerMs = performance.now() - started;
            events.push(values);
        } else {
            events.omitted = (events.omitted || 0) + 1;
        }
    }
}

function send(value) {
    process.stdout.write(JSON.stringify(value) + '\n');
}
readline
    .createInterface({
        input: process.stdin,
    })
    .on('line', async (line) => {
        let message;
        try {
            message = JSON.parse(line);
            // 移动端 Worker 不保证继承 env。仅接受来自父进程的首帧配置，不通过插件音乐路由分派。
            if (message.control === 'plugins.configure' && !pluginRegistry) {
                hostConfiguration = message;
                return;
            }
            pluginRegistry ||= buildRegistry(hostConfiguration);
            const collect =
                message._collectPlaybackDiagnostics === true &&
                String(message.route).startsWith('/native/') &&
                ['playback', 'preview'].includes(String(message.route).split('/')[3]);
            const events = collect ? [] : undefined;
            if (events) {
                events.started = performance.now();
            }
            const result = await playbackDiagnosticContext.run(events, () => dispatch(message));
            send({
                id: message.id,
                ...result,
                _pluginLoadFailure: pluginLoadFailureResponses.get(result),
                ...(events
                    ? { _playbackDiagnostics: events, _playbackDiagnosticsOmitted: events.omitted || 0 }
                    : {}),
            });
        } catch (error) {
            send({
                id: message?.id,
                body: errorBody(error, '音乐请求失败，请重试'),
                cookies: error?.cookies || error?.cookie || [],
                ...(error?.secretState || {}),
                _pluginLoadFailure: undefined,
            });
        }
    })
    .on('close', () => process.exit(0));
