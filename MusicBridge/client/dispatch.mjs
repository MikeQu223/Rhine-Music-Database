import { API } from './netease.mjs';
import { QQAPI } from './qq.mjs';
import { KugouAPI } from './kugou.mjs';
import { safeLoginDetails } from './failure.mjs';
import { fetchLyrics } from './lyrics.mjs';

const OPERATIONS = new Set([
    'mv',
    'mvVersions',
    'request',
    'search',
    'songs',
    'detail',
    'artistAlbums',
    'wiki',
    'account',
    'userPlaylists',
    'likedIDs',
    'likedSongs',
    'likedAlbums',
    'playback',
    'preview',
    'trackPage',
    'catalog',
    'discover',
    'categories',
    'lyrics',
    'mutate',
    'subscriptionStatus',
    'capabilities',
    'vip',
]);

function providerFor(route) {
    if (route.startsWith('/qq/')) {
        return 'qq';
    }
    if (route.startsWith('/kugou/')) {
        return 'kugou';
    }
    return 'netease';
}

/**
 * 为原生业务提供无界面状态的 SDK 适配入口。
 * 每个操作独立持有传输上下文，账号/队列/目录/显示状态均由 Qt 保存。
 */
export async function dispatch(message, request) {
    const [, prefix, provider, operation] = String(message.route).split('/');
    if (
        prefix !== 'native' ||
        !['netease', 'qq', 'kugou', 'siren'].includes(provider) ||
        !OPERATIONS.has(operation) ||
        !Array.isArray(message.params?.args)
    ) {
        return { body: { code: 400, message: '不支持的音乐接口操作' }, cookies: [] };
    }
    const cookies = { ...message.cookies };
    const receivedCookies = [];
    let qqSessions;
    let kugouCredentials;
    const host = {
        delay: (milliseconds, callback) => setTimeout(callback, milliseconds),
        authenticated() {
            if (provider === 'kugou') {
                // Host 已按当前版本选出凭据；桥接只读取本次请求的账号。
                return !!cookies.__kugou?.token;
            }
            return !!cookies[provider === 'qq' ? 'qqmusic_session' : 'MUSIC_U'];
        },
        acceptCookies(values) {
            for (const line of JSON.parse(values)) {
                receivedCookies.push(line);
                const match = String(line).match(/^\s*([^=;]+)=([^;]*)/);
                if (match) {
                    cookies[match[1]] = match[2];
                }
            }
        },
        request(route, params, callback) {
            if (providerFor(route) !== provider) {
                callback('', '音乐接口来源不匹配');
                return;
            }
            Promise.resolve(request({ ...message, route, params, cookies: { ...cookies } })).then(
                (response) => {
                    if (response.qqSessions) {
                        qqSessions = response.qqSessions;
                        cookies.__qqSessions = qqSessions;
                    }
                    if (response.kugouCredentials) {
                        kugouCredentials = response.kugouCredentials;
                    }
                    const body = { ...response, _epoch: 0 };
                    delete body.qqSessions;
                    delete body.kugouCredentials;
                    callback(JSON.stringify(body), '');
                },
                (error) => {
                    if (error.body && typeof error.body === 'object') {
                        callback(
                            JSON.stringify({ body: error.body, cookies: error.cookie || [], _epoch: 0 }),
                            '',
                        );
                    } else {
                        callback('', error.message || '音乐接口请求失败');
                    }
                },
            );
        },
    };
    const base = new API(host);
    let api = base;
    if (provider === 'qq') {
        api = new QQAPI(base);
    } else if (provider === 'kugou') {
        api = new KugouAPI(base);
    } else if (provider === 'siren') {
        // 塞壬模块
        const { SirenAPI } = await import('./siren.mjs');
        api = new SirenAPI(base);
    }
    if (operation !== 'lyrics' && typeof api[operation] !== 'function') {
        return { body: { code: 400, message: '此来源不支持该接口' }, cookies: [] };
    }
    try {
        const value =
            operation === 'lyrics'
                ? await fetchLyrics(api, provider, message.params.args[0])
                : await api[operation](...message.params.args);
        return {
            body: { code: 200, value: value ?? null },
            cookies: receivedCookies,
            ...(qqSessions ? { qqSessions } : {}),
            ...(kugouCredentials ? { kugouCredentials } : {}),
        };
    } catch (error) {
        return {
            body: {
                code: typeof error.code === 'number' ? error.code : 503,
                message: error.message || '音乐接口请求失败',
                authExpired: !!error.authExpired,
                ...safeLoginDetails(error),
            },
            cookies: receivedCookies,
            ...(qqSessions ? { qqSessions } : {}),
        };
    }
}
