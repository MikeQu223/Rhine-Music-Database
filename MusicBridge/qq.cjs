const http = require('node:http');
const crypto = require('node:crypto');
const allowed = new Set([
    '/login/qr/key',
    '/login/qr/create',
    '/login/qr/check',
    '/login/qr/cancel',
    '/login/status',
    '/login/channels',
    '/logout',
    '/user/detail',
    '/user/playlist',
    '/user/albums',
    '/user/liked-songs',
    '/user/playlist-detail',
    '/user/vip',
    '/user/subscription-status',
    '/user/daily-songs',
    '/user/guess-you-like',
    '/recommend/playlists',
    '/recommend/categories',
    '/recommend/category-playlists',
    '/recommend/new-songs',
    '/recommend/new-albums',
    '/recommend/toplists',
    '/recommend/toplist',
    '/search',
    '/search/suggest',
    '/getSongInfo',
    '/getSongListDetail',
    '/getAlbumInfo',
    '/getSingerHotsong',
    '/getSingerAlbum',
    '/getMusicPlay',
    '/getLyric',
]);
const writes = new Set([
    '/user/song/like',
    '/user/album/subscribe',
    '/user/playlist/subscribe',
    '/user/playlist/tracks',
    '/user/playlist/create',
    '/user/playlist/rename',
    '/user/playlist/delete',
]);
let ready;
let server;
let sessions = [];
function failureMessage(status, body, write) {
    if (status === 401) {
        return 'QQ 登录已失效，请重新登录';
    }
    if (body.errorKey === 'search.rejected') {
        return 'QQ 拒绝了本次搜索，请登录后重试';
    }
    if (write) {
        return 'QQ 写入未确认，请先刷新列表核实结果，不要重复提交';
    }
    return 'QQ 音乐暂不可用，请稍后重试';
}
// 只透传固定枚举及数字码，未知字段与原始异常始终留在私有服务内部。
function safeQrDiagnostics(body, includePrevious = true) {
    const result = {};
    for (const name of ['failureStage', 'failureReason', 'errorKey', 'upstreamErrorKey']) {
        if (typeof body?.[name] === 'string' && /^[a-z.-]{1,80}$/.test(body[name])) {
            result[name] = body[name];
        }
    }
    for (const name of ['upstreamHttpStatus', 'upstreamCode', 'upstreamGlobalCode', 'upstreamSubCode']) {
        if (typeof body?.[name] === 'number' && Number.isFinite(body[name])) {
            result[name] = body[name];
        }
    }
    if (includePrevious && body?.lastFailure) {
        result.lastFailure = safeQrDiagnostics(body.lastFailure, false);
    }
    if (includePrevious && body?.primaryFailure) {
        result.primaryFailure = safeQrDiagnostics(body.primaryFailure, false);
    }
    for (const name of ['retryable', 'writeAttempted']) {
        if (typeof body?.[name] === 'boolean') {
            result[name] = body[name];
        }
    }
    if (body?.verification === 'unconfirmed') {
        result.verification = 'unconfirmed';
    }
    return result;
}
/**
 * 建立仅回环可访问的 QQ 桥接服务。
 * 用随机认证值保护请求，认证记录只保存到已配置的凭据仓库。
 */
async function start(cookies) {
    // 上游测试入口只跳过自动监听；在桥内创建仅回环可访问、带随机认证的服务。
    const previous = process.env.NODE_ENV;
    process.env.NODE_ENV = 'test';
    process.env.QQ_AUTH_STATE_PATH = process.env.RHINE_QQ_DEVICE_STATE_PATH || 'memory';
    process.env.QQ_ENABLE_UPDATE_CHECK = 'false';
    // 首次启用持久设备配置时优先复用已保存账号的设备，避免升级额外注册设备。
    const deviceContext = require('./node_modules/@yakult-green-tea/qq-music-api/dist/src/services/auth/deviceContext.js');
    const repository = deviceContext.createDefaultDeviceContextRepository();
    if (!repository.load()) {
        const previousSession = (Array.isArray(cookies.__qqSessions) ? cookies.__qqSessions : []).find(
            (session) => session?.token === cookies.qqmusic_session && session?.expiresAt > Date.now(),
        );
        if (previousSession && deviceContext.isAndroidDevice(previousSession.device)) {
            repository.save(previousSession.device);
        }
    }
    const qq = require('@yakult-green-tea/qq-music-api');
    if (previous === undefined) {
        delete process.env.NODE_ENV;
    } else {
        process.env.NODE_ENV = previous;
    }
    sessions = Array.isArray(cookies.__qqSessions) ? cookies.__qqSessions : [];
    qq.configureAuthSessionRepository({
        kind: 'rhine-system-credential',
        load: () => sessions,
        save: (values) => {
            sessions = values;
        },
    });
    const secret = crypto.randomBytes(32).toString('hex');
    const callback = qq.default.callback();
    server = http.createServer((req, res) => {
        if (req.headers['x-rhine-bridge'] !== secret) {
            res.writeHead(403);
            res.end();
            return;
        }
        callback(req, res);
    });
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(0, '127.0.0.1', resolve);
    });
    return {
        port: server.address().port,
        secret,
    };
}
/**
 * 校验 QQ 路由并通过私有回环服务调用锁定上游。
 * 保留响应封装和会话交付，不把敏感错误原文送入界面。
 */
async function dispatch(message) {
    const route = message.route.slice(3);
    const write = writes.has(route);
    if (!allowed.has(route) && !write) {
        throw new Error('Unsupported QQ route');
    }
    ready ||= start(message.cookies || {}).catch((error) => {
        ready = undefined;
        throw error;
    });
    const { port, secret } = await ready;
    const url = new URL(`http://127.0.0.1:${port}${route}`);
    if (!write) {
        for (const [key, value] of Object.entries(message.params || {})) {
            url.searchParams.set(key, String(value));
        }
    }
    const response = await fetch(url, {
        method: write ? 'POST' : 'GET',
        headers: {
            'x-rhine-bridge': secret,
            'x-qq-session': message.cookies?.qqmusic_session || '',
            ...(write ? { 'content-type': 'application/json' } : {}),
        },
        ...(write ? { body: JSON.stringify(message.params || {}) } : {}),
        signal: AbortSignal.timeout(24000),
        redirect: 'error',
    }).catch((error) => {
        if (!write) {
            throw error;
        }
        const failure = new Error('QQ 写入结果未确认，请刷新个人库核实，不要重复提交');
        failure.body = {
            code: 502,
            message: failure.message,
            retryable: false,
            writeAttempted: true,
            verification: 'unconfirmed',
        };
        throw failure;
    });
    const body = await response.json().catch((error) => {
        if (!write) {
            throw error;
        }
        const failure = new Error('QQ 写入响应无法确认，请刷新个人库核实，不要重复提交');
        failure.body = {
            code: 502,
            message: failure.message,
            retryable: false,
            writeAttempted: true,
            verification: 'unconfirmed',
        };
        throw failure;
    });
    const cookies = response.headers.getSetCookie();
    if (typeof body.cookie === 'string') {
        cookies.push(body.cookie);
        delete body.cookie;
    }
    if (!response.ok) {
        // 不把上游异常原文或包含签名的 URL 交给界面。
        return {
            body: {
                code: response.status,
                message: failureMessage(response.status, body, write),
                retryAfterMs: body.retryAfterMs ?? Number(response.headers.get('Retry-After') || 0) * 1000,
                ...safeQrDiagnostics(body),
            },
            cookies: [],
            qqSessions: sessions,
        };
    }
    return {
        body:
            route === '/getLyric'
                ? require('./lyrics-format.cjs').normalizeLyrics('qq', body, message.params)
                : body,
        cookies,
        qqSessions: sessions,
    };
}
module.exports = {
    dispatch,
};
