const { AsyncLocalStorage } = require('node:async_hooks');
const playbackDiagnosticContext = new AsyncLocalStorage();

/** 记录 HTTP 传输 */
function recordHttpResult(events, started, status, error, phase) {
    if (events.length >= 64) {
        events.omitted = (events.omitted || 0) + 1;
        return;
    }
    const values = {
        operation: 5,
        workerMs: performance.now() - started,
        transportFailed: !!error,
        httpPhase: phase,
        workerOffsetMs: started - events.started,
    };
    if (Number.isInteger(status) && status >= 100 && status <= 599) {
        values.upstreamHttpStatus = status;
    }
    if (error) {
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
            ].indexOf(error.code || error.cause?.code),
        );
    }
    events.push(values);
}

const axios = require('axios');
const httpTimings = new WeakMap();
axios.interceptors.request.use((config) => {
    const events = playbackDiagnosticContext.getStore();
    if (events) {
        httpTimings.set(config, { events, started: performance.now() });
    }
    return config;
});
axios.interceptors.response.use(
    (response) => {
        const timing = httpTimings.get(response.config);
        if (timing) {
            recordHttpResult(timing.events, timing.started, response.status, undefined, 2);
        }
        return response;
    },
    (error) => {
        const timing = error.config && httpTimings.get(error.config);
        if (timing) {
            recordHttpResult(timing.events, timing.started, error.response?.status, error, 2);
        }
        return Promise.reject(error);
    },
);
const originalFetch = global.fetch;
global.fetch = function (...args) {
    const events = playbackDiagnosticContext.getStore();
    if (!events) {
        return originalFetch(...args);
    }
    const started = performance.now();
    return originalFetch(...args).then(
        (response) => {
            recordHttpResult(events, started, response.status, undefined, 1);
            return response;
        },
        (error) => {
            recordHttpResult(events, started, undefined, error, 1);
            throw error;
        },
    );
};
// 网易云协议使用锁定的 Enhanced 原包；QQ 协议使用锁定的 QQ API 原包。
// 本文件仅通过父子进程的私有管道传递请求。
// 替代音源组件的日志也必须静默，避免污染私有 IPC。
process.env.LOG_LEVEL = 'silent';
process.env.JSON_LOG = 'true';
delete process.env.LOG_FILE;
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const tokenPath = path.join(require('node:os').tmpdir(), 'anonymous_token');
if (!fs.existsSync(tokenPath)) {
    fs.writeFileSync(tokenPath, '', {
        mode: 0o600,
    });
}
// 上游诊断可能包含 URL 或 Cookie，禁止混入 IPC 消息和日志。
console.log = console.info = console.warn = console.error = console.debug = () => {};
const routes = Object.freeze({
    '/login/qr/key': 'login_qr_key',
    '/login/qr/check': 'login_qr_check',
    '/user/account': 'user_account',
    '/search': 'search',
    '/search/suggest': 'search_suggest',
    '/song/detail': 'song_detail',
    '/album': 'album',
    '/playlist/detail': 'playlist_detail',
    '/user/playlist': 'user_playlist',
    '/likelist': 'likelist',
    '/album/sublist': 'album_sublist',
    '/artists': 'artists',
    '/artist/album': 'artist_album',
    '/playlist/delete': 'playlist_delete',
    '/like': 'like',
    '/album/sub': 'album_sub',
    '/playlist/subscribe': 'playlist_subscribe',
    '/artist/sub': 'artist_sub',
    '/artist/sublist': 'artist_sublist',
    '/playlist/create': 'playlist_create',
    '/playlist/name/update': 'playlist_name_update',
    '/playlist/tracks': 'playlist_tracks',
    '/login/cellphone': 'login_cellphone',
    '/captcha/sent': 'captcha_sent',
    '/song/url': 'song_url',
    '/song/url/v1': 'song_url_v1',
    '/personalized': 'personalized',
    '/recommend/songs': 'recommend_songs',
    '/album/newest': 'album_newest',
    '/top/playlist': 'top_playlist',
    '/playlist/catlist': 'playlist_catlist',
    '/toplist': 'toplist',
    '/song/wiki/summary': 'song_wiki_summary',
    '/lyric/new': 'lyric_new',
    '/lyric': 'lyric',
});
// 沿用上游 main.js 的函数适配方式，只加载允许的接口。
const { cookieToJson, generateDeviceId } = require('./node_modules/@neteasecloudmusicapienhanced/api/util');
const { getXeapiPublicKey } = require('./node_modules/@neteasecloudmusicapienhanced/api/util/xeapiKey');
const xeapiKeyPath = path.join(require('node:os').tmpdir(), 'xeapi_public_key');
global.deviceId = generateDeviceId();
let xeapiPublicKey;
let xeapiInitializing;
let requestModule;
/**
 * 在真实 XEAPI 请求前准备上游密钥，并让并发请求共享一次初始化或刷新。
 * 密钥仅写入当前桥接的私有临时目录；不修改上游协议和加密实现。
 */
async function prepareXeapiKey() {
    if (xeapiInitializing) {
        return xeapiInitializing;
    }
    if (!xeapiPublicKey && fs.existsSync(xeapiKeyPath)) {
        try {
            const cachedKey = JSON.parse(fs.readFileSync(xeapiKeyPath, 'utf8'));
            if (cachedKey.publicKey && cachedKey.sk) {
                xeapiPublicKey = cachedKey;
                global.deviceId = cachedKey.deviceId || global.deviceId;
            }
        } catch {
            // 损坏的临时缓存不能作为可用密钥，接下来重新向上游注册。
        }
    }
    const nextUpdateTime = Number(xeapiPublicKey?.nextUpdateTime) || 0;
    const updateAtMs = nextUpdateTime < 1e12 ? nextUpdateTime * 1000 : nextUpdateTime;
    if (xeapiPublicKey && (!updateAtMs || Date.now() < updateAtMs)) {
        return;
    }
    xeapiInitializing = (async () => {
        try {
            const publicKey = await getXeapiPublicKey(xeapiPublicKey || {}, global.deviceId);
            if (!publicKey.publicKey || !publicKey.sk) {
                throw new Error('Incomplete XEAPI key');
            }
            fs.writeFileSync(xeapiKeyPath, JSON.stringify(publicKey), { mode: 0o600 });
            xeapiPublicKey = publicKey;
            // 上游 request 在模块内缓存密钥和会话，刷新后必须重新读取。
            // 打包后的模块实例常驻，改用上游模块上的构建钩子清空密钥缓存；
            const upstreamRequest = require('./node_modules/@neteasecloudmusicapienhanced/api/util/request.js');
            if (typeof upstreamRequest.__rhineResetXeapiKeyCache === 'function') {
                upstreamRequest.__rhineResetXeapiKeyCache();
                requestModule = upstreamRequest;
            } else {
                const requestPath = path.join(
                    __dirname,
                    'node_modules/@neteasecloudmusicapienhanced/api/util/request.js',
                );
                delete require.cache[requestPath];
                requestModule = undefined;
            }
        } catch {
            // 初始化错误不得悄悄改成旧版码率接口，否则母带等档位会丢失。
            const error = new Error('网易云音源初始化失败，请重试');
            error.body = { code: 503, message: error.message };
            throw error;
        } finally {
            xeapiInitializing = undefined;
        }
    })();
    return xeapiInitializing;
}

// 随包放置占位文件满足存在性检查，并把真实模块预置到 require 缓存。
const Module = require('node:module');
const unblockModules = require('./unblock-modules.cjs');
for (const [name, exported] of Object.entries(unblockModules)) {
    let filename;
    try {
        filename = require.resolve(path.join(__dirname, '..', 'modules', name + '.js'));
    } catch {
        // 未打包开发运行时没有占位目录，继续沿用上游的按目录加载。
        continue;
    }
    const cached = new Module(filename);
    cached.filename = filename;
    cached.loaded = true;
    cached.exports = exported;
    require.cache[filename] = cached;
}
// 生成文件只包含 routes 引用的接口
const neteaseEndpoints = require('./netease-endpoints.cjs');
const api = Object.fromEntries(
    Object.values(routes).map((name) => {
        const endpoint = neteaseEndpoints[name];
        if (typeof endpoint !== 'function') {
            throw new Error('Missing NetEase endpoint module: ' + name);
        }
        return [
            name,
            (data = {}) =>
                endpoint(
                    {
                        ...data,
                        cookie:
                            typeof data.cookie === 'string' ? cookieToJson(data.cookie) : data.cookie || {},
                    },
                    async (...args) => {
                        if (args[2]?.crypto === 'xeapi') {
                            await prepareXeapiKey();
                        }
                        requestModule ||= require('./node_modules/@neteasecloudmusicapienhanced/api/util/request.js');
                        return requestModule(...args);
                    },
                ),
        ];
    }),
);
// 原样执行上游前端的认证和用户函数；加载时仅适配 ES 模块的
// 导入导出语法，使其能使用私有传输层。
const vm = require('node:vm');
/**
 * 载入锁定的上游认证或用户模块。
 * 仅适配导入导出和请求入口，禁止改写协议实现。
 */
function loadClient(name, request) {
    const source = fs.readFileSync(path.join(__dirname, 'upstream', name + '.js'), 'utf8');
    const names = [...source.matchAll(/export function (\w+)/g)].map((m) => m[1]);
    const executable = source
        .replace(/^import request from '@\/utils\/request';\s*/m, '')
        .replace(/export function /g, 'function ');
    return vm.runInNewContext(executable + '\n({' + names.join(',') + '})', {
        request,
        Date,
    });
}
/**
 * 根据私有 IPC 消息分派允许的音乐请求。
 * 沿用锁定上游的协议与错误语义，响应 Cookie 交给父进程隔离处理。
 */
async function dispatchRequest(message) {
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
        const result = require('./lyrics-format.cjs').normalizeLyrics('netease', { lrc: { lyric: content } });
        if (result.document) {
            result.document.source = 'local';
            if (encoding) {
                result.document.encoding = encoding;
            }
        }
        return { body: result, cookies: [] };
    }
    if (message.route?.startsWith('/native/')) {
        const client = await import('./client/dispatch.mjs');
        return client.dispatch(message, dispatch);
    }
    if (message.route?.startsWith('/qq/')) {
        return require('./qq.cjs').dispatch(message);
    }
    if (message.route?.startsWith('/kugou/')) {
        return require('./kugou.cjs').dispatch(message);
    }
    let responseCookies = [];
    const request = async (config) => {
        const moduleName = routes[config.url];
        if (!moduleName) {
            throw new Error('Unsupported metadata route');
        }
        const query = Object.fromEntries(Object.entries(config.params || {}).map(([k, v]) => [k, String(v)]));
        query.cookie = Object.fromEntries(
            Object.entries(message.cookies || {}).filter(
                ([key]) => !key.startsWith('__') && key !== 'qqmusic_session',
            ),
        );
        const result = await api[moduleName](query);
        responseCookies.push(...(result.cookie || []));
        return result.body;
    };
    const auth = loadClient('auth', request);
    const user = loadClient('user', request);
    const p = message.params || {};
    const calls = {
        '/login/qr/key': () => auth.loginQrCodeKey(),
        '/login/qr/check': () => auth.loginQrCodeCheck(p.key),
        '/user/account': () => user.userAccount(),
        '/user/playlist': () => user.userPlaylist(p),
        '/likelist': () => user.userLikedSongsIDs(p.uid),
        '/album/sublist': () => user.likedAlbums(p),
    };
    const body = await (calls[message.route]
        ? calls[message.route]()
        : request({
              url: message.route,
              params: p,
          }));
    return {
        body: ['/lyric', '/lyric/new'].includes(message.route)
            ? require('./lyrics-format.cjs').normalizeLyrics('netease', body, message.params)
            : body,
        cookies: responseCookies,
    };
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
// 离线测试通过预加载脚本注入上游传输替身；发布运行不设置该变量。
if (process.env.RHINE_TEST_BRIDGE) {
    globalThis.__rhineBridgeTestSetup?.({
        axios,
        upstreamCrypto: require('./node_modules/@neteasecloudmusicapienhanced/api/util/crypto.js'),
        kugouConfig: require('./node_modules/kugoumusicapi/util/config.json'),
    });
}
readline
    .createInterface({
        input: process.stdin,
    })
    .on('line', async (line) => {
        let message;
        try {
            message = JSON.parse(line);
            const collect =
                message._collectPlaybackDiagnostics === true &&
                /^\/native\/(netease|qq|kugou|siren)\/(playback|preview)$/.test(message.route);
            const events = collect ? [] : undefined;
            if (events) {
                events.started = performance.now();
            }
            const result = await playbackDiagnosticContext.run(events, () => dispatch(message));
            send({
                id: message.id,
                ...result,
                ...(events
                    ? { _playbackDiagnostics: events, _playbackDiagnosticsOmitted: events.omitted || 0 }
                    : {}),
            });
        } catch (error) {
            send({
                id: message?.id,
                body: error.body || {
                    code: 503,
                    message: '音乐请求失败，请重试',
                },
                cookies: error.cookie || [],
            });
        }
    })
    .on('close', () => process.exit(0));
