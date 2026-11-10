// 塞壬唱片上游适配：只负责官网目录、播放直链和歌词，账号/收藏/歌单由 Qt 本地实现。
import { createHash } from 'node:crypto';
import lyricsFormat from '../lyrics-format.cjs';

const { normalizeLyrics } = lyricsFormat;

const ORIGIN = 'https://monster-siren.hypergryph.com';
const PAGE_SIZE = 30;
const CATALOG_TTL = 24 * 60 * 60 * 1000;
const DETAIL_TTL = 10 * 60 * 1000;
const MAX_LYRIC_LENGTH = 1000000;
// 官网少数早期专辑没有填写艺人；塞壬唱片目录统一回退到厂牌名，避免条目显示为空。
const DEFAULT_ARTIST = '塞壬唱片-MSR';

const array = (value) => (Array.isArray(value) ? value : []);
const text = (value) => (typeof value === 'string' ? value : '');
const trimmed = (value) => text(value).trim();

function artistNames(raw, album) {
    const names = array(raw.artists).map(trimmed).filter(Boolean);
    if (names.length) {
        return names;
    }
    const fallback = array(album?.artistes).map(trimmed).filter(Boolean);
    return fallback.length ? fallback : [DEFAULT_ARTIST];
}

function artistID(name) {
    return 'a' + createHash('sha1').update(name).digest('hex').slice(0, 16);
}

function formatOf(url) {
    const path = text(url).split('?')[0];
    const dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.slice(dot + 1).toLowerCase();
}

// 封面路径里的日期是官网目前唯一可用的发行日期线索，只作为展示回退。
function dateOf(coverUrl) {
    const match = /\/(\d{4})(\d{2})(\d{2})\//.exec(text(coverUrl));
    return match ? `${match[1]}-${match[2]}-${match[3]}` : '';
}

function page(values, offset, total = values.length, notice = '') {
    const start = Math.max(0, Number(offset) || 0);
    const items = values.slice(start, start + PAGE_SIZE);
    return {
        items,
        rawCount: items.length,
        total,
        more: start + items.length < total,
        ...(notice ? { notice } : {}),
    };
}

async function getText(url, valid) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
        if (!valid()) {
            throw new Error('Stale operation');
        }
        const response = await fetch(url, {
            headers: { 'User-Agent': 'RhineMusicDatabase/1.0', Accept: '*/*' },
            signal: controller.signal,
        });
        if (!response.ok) {
            throw new Error(`塞壬唱片资源请求失败（HTTP ${response.status}）`);
        }
        return await response.text();
    } finally {
        clearTimeout(timer);
    }
}

export class SirenAPI {
    constructor(base) {
        this.host = base.host;
        this.provider = 'siren';
        this.catalogCache = null;
        this.details = new Map();
        this.albums = new Map();
    }

    delay(milliseconds) {
        return new Promise((resolve) => this.host.delay(milliseconds, resolve));
    }

    async request(path, valid = () => true) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 20000);
        try {
            if (!valid()) {
                throw new Error('Stale operation');
            }
            const response = await fetch(ORIGIN + path, {
                headers: { 'User-Agent': 'RhineMusicDatabase/1.0', Accept: 'application/json' },
                signal: controller.signal,
            });
            if (!response.ok) {
                throw new Error(`塞壬唱片请求失败（HTTP ${response.status}）`);
            }
            const body = await response.json();
            if (body?.code !== 0) {
                throw new Error(`塞壬唱片返回 ${body?.code ?? '未知错误'}：${body?.msg || '请稍后重试'}`);
            }
            return body.data;
        } finally {
            clearTimeout(timer);
        }
    }

    /** 目录只用两条全量接口，一次拉取后在进程内复用；Host 仍会做二级缓存。 */
    async load(valid = () => true) {
        if (this.catalogCache && Date.now() - this.catalogCache.at < CATALOG_TTL) {
            return this.catalogCache;
        }
        const [songData, albumData] = await Promise.all([
            this.request('/api/songs', valid),
            this.request('/api/albums', valid),
        ]);
        const songs = Array.isArray(songData) ? songData : array(songData?.list);
        const albums = Array.isArray(albumData) ? albumData : array(albumData?.list);
        const albumByID = new Map();
        const albumSongs = new Map();
        for (const raw of albums) {
            const id = trimmed(raw.cid);
            if (!id) {
                continue;
            }
            albumByID.set(id, raw);
            albumSongs.set(id, []);
        }
        const songByID = new Map();
        const artistStats = new Map();
        const albumArtists = new Map();
        for (const raw of songs) {
            const id = trimmed(raw.cid);
            if (!id) {
                continue;
            }
            songByID.set(id, raw);
            const albumID = trimmed(raw.albumCid);
            if (albumSongs.has(albumID)) {
                albumSongs.get(albumID).push(raw);
            }
            for (const name of artistNames(raw, albumByID.get(albumID))) {
                const entry = artistStats.get(name) || { name, songs: 0, cover: '' };
                entry.songs += 1;
                if (!entry.cover) {
                    entry.cover = text(albumByID.get(albumID)?.coverUrl);
                }
                artistStats.set(name, entry);
                if (albumID) {
                    const names = albumArtists.get(albumID) || new Set();
                    names.add(name);
                    albumArtists.set(albumID, names);
                }
            }
        }
        for (const raw of albums) {
            const albumID = trimmed(raw.cid);
            for (const name of array(raw.artistes).map(trimmed).filter(Boolean)) {
                const entry = artistStats.get(name) || { name, songs: 0, cover: '' };
                if (!entry.cover) {
                    entry.cover = text(raw.coverUrl);
                }
                artistStats.set(name, entry);
                const names = albumArtists.get(albumID) || new Set();
                names.add(name);
                albumArtists.set(albumID, names);
            }
        }
        this.catalogCache = {
            at: Date.now(),
            songs,
            albums,
            songByID,
            albumByID,
            albumSongs,
            albumArtists,
            artistStats,
        };
        this.details.clear();
        this.albums.clear();
        return this.catalogCache;
    }

    songItem(raw, catalog = this.catalogCache) {
        const id = trimmed(raw?.cid);
        if (!id) {
            return null;
        }
        const albumID = trimmed(raw.albumCid);
        const album = catalog?.albumByID.get(albumID);
        const names = artistNames(raw, album);
        const artists = names.map((name) => ({ id: artistID(name), name }));
        return {
            provider: 'siren',
            kind: 'song',
            id,
            key: 'siren:song:' + id,
            title: trimmed(raw.name) || '正在读取…',
            artist: names.join(' / '),
            artists,
            creatorID: '',
            albumID,
            album: trimmed(album?.name),
            cover: text(album?.coverUrl),
            description: '',
            wiki: '',
            date: dateOf(album?.coverUrl),
            duration: 0,
            trackCount: 0,
        };
    }

    albumItem(raw, catalog = this.catalogCache) {
        const id = trimmed(raw?.cid);
        if (!id) {
            return null;
        }
        const names = array(raw.artistes).map(trimmed).filter(Boolean);
        if (!names.length) {
            for (const song of catalog?.albumSongs.get(id) || []) {
                for (const name of array(song.artists).map(trimmed).filter(Boolean)) {
                    if (!names.includes(name)) {
                        names.push(name);
                    }
                }
            }
        }
        if (!names.length) {
            names.push(DEFAULT_ARTIST);
        }
        const artists = names.map((name) => ({ id: artistID(name), name }));
        return {
            provider: 'siren',
            kind: 'album',
            id,
            key: 'siren:album:' + id,
            title: trimmed(raw.name) || '正在读取…',
            artist: names.join(' / '),
            artists,
            creatorID: '',
            albumID: id,
            album: trimmed(raw.name),
            cover: text(raw.coverUrl),
            description: trimmed(raw.intro),
            wiki: '',
            date: dateOf(raw.coverUrl),
            duration: 0,
            trackCount: (catalog?.albumSongs.get(id) || []).length,
        };
    }

    artistItem(name, catalog = this.catalogCache) {
        const entry = catalog?.artistStats.get(name);
        if (!entry) {
            return null;
        }
        return {
            provider: 'siren',
            kind: 'artist',
            id: artistID(name),
            key: 'siren:artist:' + artistID(name),
            title: name,
            artist: name,
            artists: [{ id: artistID(name), name }],
            creatorID: '',
            albumID: '',
            album: '',
            cover: text(entry.cover),
            description: '',
            wiki: '',
            date: '',
            duration: 0,
            trackCount: entry.songs,
        };
    }

    async songDetail(id, valid = () => true) {
        const key = String(id);
        const hit = this.details.get(key);
        if (hit && Date.now() - hit.at < DETAIL_TTL) {
            return hit.data;
        }
        const data = await this.request('/api/song/' + encodeURIComponent(key), valid);
        this.details.set(key, { at: Date.now(), data });
        return data;
    }

    /** 播放直链带时效签名，必须实时读取，不能复用 detail 缓存。 */
    async freshSong(id, valid = () => true) {
        return this.request('/api/song/' + encodeURIComponent(String(id)), valid);
    }

    async albumDetail(id, valid = () => true) {
        const key = String(id);
        const hit = this.albums.get(key);
        if (hit && Date.now() - hit.at < DETAIL_TTL) {
            return hit.data;
        }
        const data = await this.request('/api/album/' + encodeURIComponent(key) + '/detail', valid);
        this.albums.set(key, { at: Date.now(), data });
        return data;
    }

    /** 一次性返回完整曲库；Qt 侧持有后搜索、播放全部都不再请求官网。 */
    async catalog(valid = () => true) {
        const catalog = await this.load(valid);
        return {
            songs: catalog.songs.map((raw) => this.songItem(raw, catalog)).filter(Boolean),
            albums: catalog.albums.map((raw) => this.albumItem(raw, catalog)).filter(Boolean),
        };
    }

    async search(input, kind = 'song', offset = 0, valid = () => true) {
        const catalog = await this.load(valid);
        const query = trimmed(input).toLowerCase();
        const matches = (value) => !query || value.toLowerCase().includes(query);
        if (kind === 'song') {
            const items = [];
            for (const raw of catalog.songs) {
                const item = this.songItem(raw, catalog);
                if (!item) {
                    continue;
                }
                if (query && !matches(item.title) && !matches(item.album) && !matches(item.artist)) {
                    continue;
                }
                items.push(item);
            }
            return page(items, offset);
        }
        if (kind === 'album') {
            const items = [];
            for (const raw of catalog.albums) {
                const item = this.albumItem(raw, catalog);
                if (!item) {
                    continue;
                }
                if (query && !matches(item.title) && !matches(item.artist)) {
                    continue;
                }
                items.push(item);
            }
            return page(items, offset);
        }
        if (kind === 'artist') {
            const items = [];
            for (const [name, entry] of catalog.artistStats) {
                if (query && !matches(name)) {
                    continue;
                }
                const item = this.artistItem(name, catalog);
                if (item) {
                    item.trackCount = entry.songs;
                    items.push(item);
                }
            }
            items.sort((left, right) => {
                if (left.trackCount !== right.trackCount) {
                    return right.trackCount - left.trackCount;
                }
                return left.title.localeCompare(right.title);
            });
            return page(items, offset);
        }
        if (kind === 'playlist') {
            return page([], offset, 0, '塞壬唱片没有在线歌单，本地歌单将在后续版本提供');
        }
        throw new Error('塞壬唱片不支持此搜索类别');
    }

    async songs(ids, valid = () => true) {
        const catalog = await this.load(valid);
        const result = [];
        for (const id of array(ids)) {
            const item = this.songItem(catalog.songByID.get(trimmed(id)), catalog);
            if (item) {
                result.push(item);
            }
        }
        return result;
    }

    async trackPage(value, offset = 0, valid = () => true) {
        const catalog = await this.load(valid);
        const id = trimmed(value?.id);
        let items = [];
        if (value?.kind === 'album') {
            const detail = await this.albumDetail(id, valid);
            items = array(detail.songs)
                .map((raw) => this.songItem({ ...raw, albumCid: id, artists: raw.artistes }, catalog))
                .filter(Boolean);
            if (!items.length) {
                items = (catalog.albumSongs.get(id) || [])
                    .map((raw) => this.songItem(raw, catalog))
                    .filter(Boolean);
            }
        } else if (value?.kind === 'artist') {
            const name = this.artistName(id);
            items = catalog.songs
                .filter((raw) =>
                    artistNames(raw, catalog.albumByID.get(trimmed(raw.albumCid))).includes(name),
                )
                .map((raw) => this.songItem(raw, catalog))
                .filter(Boolean);
        }
        return page(items, offset, items.length);
    }

    async detail(value, valid = () => true) {
        const catalog = await this.load(valid);
        const kind = value?.kind;
        const id = trimmed(value?.id);
        if (kind === 'song') {
            const item = this.songItem(catalog.songByID.get(id), catalog) || value;
            return [item, [], []];
        }
        if (kind === 'album') {
            const detail = await this.albumDetail(id, valid);
            const merged = { ...(catalog.albumByID.get(id) || {}), ...detail };
            const album = this.albumItem(merged, catalog) || value;
            const songs = array(detail.songs)
                .map((raw) => this.songItem({ ...raw, albumCid: id, artists: raw.artistes }, catalog))
                .filter(Boolean);
            const ids = songs.map((song) => song.id);
            album.trackCount = songs.length;
            return [album, songs, ids];
        }
        if (kind === 'artist') {
            const name = this.artistName(id) || trimmed(value?.title);
            const artist = this.artistItem(name, catalog) || value;
            return [artist, [], []];
        }
        return [value, [], []];
    }

    async artistAlbums(id, offset = 0, valid = () => true) {
        const catalog = await this.load(valid);
        const name = this.artistName(id);
        if (!name) {
            return page([], offset, 0);
        }
        const items = catalog.albums
            .filter((raw) => {
                const id = trimmed(raw.cid);
                return (
                    array(raw.artistes).map(trimmed).includes(name) || catalog.albumArtists.get(id)?.has(name)
                );
            })
            .map((raw) => this.albumItem(raw, catalog))
            .filter(Boolean);
        return page(items, offset, items.length);
    }

    artistName(id) {
        if (!this.catalogCache) {
            return '';
        }
        for (const [name] of this.catalogCache.artistStats) {
            if (artistID(name) === trimmed(id)) {
                return name;
            }
        }
        return '';
    }

    async wiki(id, valid = () => true) {
        const catalog = await this.load(valid);
        const song = catalog.songByID.get(trimmed(id));
        const album = song ? catalog.albumByID.get(trimmed(song.albumCid)) : null;
        if (!album) {
            return '塞壬唱片 · Monster Siren Records';
        }
        const intro = trimmed(album.intro);
        return intro ? `${trimmed(album.name)} / ${intro}` : trimmed(album.name);
    }

    async playback(value, quality, alternative, valid = () => true) {
        const detail = await this.freshSong(value?.id, valid);
        const url = text(detail.sourceUrl);
        if (!url) {
            throw new Error('塞壬唱片未提供可播放音源');
        }
        const format = formatOf(url);
        const lossless = ['wav', 'flac', 'ape', 'alac'].includes(format);
        let tier = '';
        if (lossless) {
            tier = 'sq';
        } else if (['mp3', 'm4a', 'aac'].includes(format)) {
            tier = 'hq';
        }
        return {
            url,
            type: format,
            format,
            extName: format,
            quality: format === 'wav' ? 'flac' : '',
            tier: tier || 'auto',
        };
    }

    async lyrics(track, valid = () => true) {
        const detail = await this.songDetail(track?.id, valid);
        const url = text(detail.lyricUrl);
        if (!url) {
            return null;
        }
        const content = await getText(url, valid);
        if (!content.trim() || content.length > MAX_LYRIC_LENGTH) {
            return null;
        }
        const result = normalizeLyrics('siren', { lrc: { lyric: content } });
        if (!result?.document) {
            return null;
        }
        result.document.source = 'siren';
        return result.document;
    }

    async capabilities() {
        return {
            login: false,
            mutations: {
                likeSong: false,
                subscribeAlbum: false,
                subscribePlaylist: false,
                updatePlaylistTracks: false,
            },
            playlistManagement: { createPlaylist: false, renamePlaylist: false, deletePlaylist: false },
        };
    }

    async account() {
        throw new Error('塞壬唱片无需登录');
    }

    async userPlaylists() {
        return page([], 0, 0);
    }

    async likedIDs() {
        return [];
    }

    async likedSongs(offset = 0) {
        return page([], offset, 0);
    }

    async likedAlbums(offset = 0) {
        return page([], offset, 0);
    }

    async mutate() {
        throw new Error('塞壬唱片本地收藏将在后续版本提供');
    }

    async subscriptionStatus() {
        return 'unknown';
    }

    async vip() {
        return { vipLevel: 'none' };
    }

    async discover(tab, offset = 0) {
        return page([], offset, 0);
    }

    async categories() {
        return [];
    }
}
