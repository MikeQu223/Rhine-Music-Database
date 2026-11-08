/**
 * 内置来源（塞壬）歌词读取。第三方平台歌词由各自插件提供。
 */
export async function fetchLyrics(api, provider, track) {
    if (provider !== 'siren') {
        throw new Error('Unsupported provider');
    }
    return api.lyrics(track);
}
