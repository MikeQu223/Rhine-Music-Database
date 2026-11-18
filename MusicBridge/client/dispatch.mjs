import { SirenAPI } from './siren.mjs';
import { safeLoginDetails } from '../plugins/sdk/failure.mjs';

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

/**
 * 内置来源（塞壬）分派。第三方平台由插件 Registry 处理，不经过本文件。
 */
export async function dispatch(message) {
    const [, prefix, provider, operation] = String(message.route).split('/');
    if (
        prefix !== 'native' ||
        provider !== 'siren' ||
        !OPERATIONS.has(operation) ||
        !Array.isArray(message.params?.args)
    ) {
        return { body: { code: 400, message: '不支持的音乐接口操作' }, cookies: [] };
    }
    const host = {
        delay: (milliseconds, callback) => setTimeout(callback, milliseconds),
        authenticated: () => false,
        acceptCookies() {},
    };
    const api = new SirenAPI({ host });
    if (operation !== 'lyrics' && typeof api[operation] !== 'function') {
        return { body: { code: 400, message: '此来源不支持该接口' }, cookies: [] };
    }
    try {
        const value =
            operation === 'lyrics'
                ? await api.lyrics(message.params.args[0])
                : await api[operation](...message.params.args);
        return { body: { code: 200, value: value ?? null }, cookies: [] };
    } catch (error) {
        return {
            body: {
                code: typeof error.code === 'number' ? error.code : 503,
                message: error.message || '音乐接口请求失败',
                authExpired: !!error.authExpired,
                ...safeLoginDetails(error),
            },
            cookies: [],
        };
    }
}
