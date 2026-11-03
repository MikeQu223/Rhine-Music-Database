// QQ 数据在此转换成资料库模型；mid 和媒体文件标识保持原值。
const array = (value) => (Array.isArray(value) ? value : []);
const identifier = (value) => (/^[a-zA-Z0-9_-]{1,80}$/.test(String(value ?? '')) ? String(value) : '');
function unconfirmedWrite(message) {
    const error = new Error(message);
    error.code = 502;
    error.writeAttempted = true;
    error.retryable = false;
    return error;
}
const art = (mid) =>
    mid ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + encodeURIComponent(mid) + '.jpg' : '';
// 部分接口把条目包在 songInfo、musicData 或 data 外层，只在外层对象确实含条目标识时拆包。
const itemIdentityKeys = [
    'mid',
    'songmid',
    'albumMid',
    'albumMID',
    'albummid',
    'album_mid',
    'tid',
    'dissid',
    'disstid',
    'topId',
    'singermid',
    'id',
];
const hasItemIdentity = (value) => Boolean(value) && itemIdentityKeys.some((key) => value[key] !== undefined);
export function qqItem(raw, kind = 'song') {
    const wrapped = [raw.songInfo, raw.musicData, raw.data].find((value) => hasItemIdentity(value));
    const d = wrapped || raw;
    const album = d.album || {};
    const singers = array(d.singer || d.singers);
    // 保持原有判断顺序，仅计算当前需要的分支结果。
    // 按 QQ 条目类别读取原始标识，不混用 mid 与目录 ID。
    const selectItemIdentifier = () => {
        if (kind === 'song') {
            return d.mid ?? d.songmid;
        } else if (kind === 'album') {
            return d.mid ?? d.album_mid ?? d.albumMID ?? d.albumMid ?? d.albummid;
        } else if (kind === 'artist') {
            return d.mid ?? d.singermid ?? d.singerMID;
        } else {
            return d.tid ?? d.dissid ?? d.disstid ?? d.topId ?? d.id;
        }
    };
    const id = identifier(selectItemIdentifier());
    let title;
    if (kind === 'song') {
        title = d.name ?? d.title ?? d.songname;
    } else if (kind === 'album') {
        title = d.name ?? d.album_name ?? d.albumname ?? d.albumName;
    } else if (kind === 'artist') {
        title = d.name ?? d.singername ?? d.singerName;
    } else {
        title = d.dirName ?? d.name ?? d.dissname ?? d.topTitle ?? d.title;
    }
    if (!id || typeof title !== 'string') {
        return null;
    }
    const albumID = identifier(album.mid ?? d.albummid ?? d.album_mid);
    const creator = d.creator || {};
    return {
        provider: 'qq',
        kind,
        id,
        key: 'qq:' + kind + ':' + id,
        title,
        artist:
            kind === 'playlist'
                ? String(creator.name ?? creator.nick ?? d.nickname ?? '')
                : singers
                      .map((v) => v.name)
                      .filter(Boolean)
                      .join(' / ') ||
                  d.singerName ||
                  (typeof d.singer === 'string' ? d.singer : '') ||
                  '',
        artists: singers
            .map((v) => ({
                id: identifier(v.mid ?? v.singermid),
                name: v.name,
            }))
            .filter((v) => v.id && v.name),
        albumID,
        album: album.name ?? d.albumname ?? '',
        mediaId: identifier(d.file?.media_mid ?? d.media_mid ?? d.strMediaMid),
        songID: Number(d.id ?? d.songid ?? 0),
        songType: d.type ?? d.songtype ?? null,
        cover:
            d.albumPicUrl ||
            d.cover ||
            d.picUrl ||
            d.picurl ||
            d.singerPic ||
            d.pic ||
            d.logo ||
            art(kind === 'album' ? id : albumID),
        creatorID: String(creator.uin ?? d.uin ?? ''),
        owned: !!d.owned,
        dirId: String(d.dirId ?? d.dirid ?? ''),
        description: d.desc ?? d.description ?? '',
        wiki: '',
        date: d.time_public ?? d.publicTime ?? d.publishDate ?? d.publish_date ?? '',
        duration: Number(d.interval ?? d.duration ?? 0) * 1000,
        trackCount: Number(d.songNum ?? d.songnum ?? d.total_song_num ?? d.totalNum ?? d.total ?? 0),
        chart: d.chart === true,
        period: d.period ?? '',
        ...(Number.isSafeInteger(d.play_cnt) && d.play_cnt >= 0 ? { playCount: d.play_cnt } : {}),
    };
}

export class QQAPI {
    constructor(base) {
        this.base = base;
        base.provider = 'qq';
        this.host = base.host;
        this.provider = 'qq';
        this.songCache = new Map();
    }

    request(route, values = {}, allow = [200], valid = () => true) {
        return this.base.request('/qq' + route, values, allow, valid);
    }

    delay(ms) {
        return this.base.delay(ms);
    }

    rows(raw, kind = 'song') {
        return array(raw)
            .map((d) => qqItem(d, kind))
            .filter(Boolean)
            .map((v) => {
                if (kind === 'song') {
                    const full = this.songCache.get(v.id);
                    if (full?.playbackReady) {
                        return full;
                    }
                    this.songCache.set(v.id, v);
                }
                return v;
            });
    }

    response(body) {
        const r = body.response ?? body;
        if (r.code !== undefined && ![0, 200].includes(r.code)) {
            throw new Error('QQ 音乐返回 ' + r.code);
        }
        return r;
    }

    module(r, key) {
        const m = r[key] || {};
        if (m.code !== undefined && ![0, 200].includes(m.code)) {
            throw new Error('QQ 音乐返回 ' + m.code);
        }
        return m.data || {};
    }

    async search(text, kind, offset = 0, valid = () => true) {
        const types = { song: 'song', album: 'album', playlist: 'playlist', artist: 'singer' };
        if (!types[kind]) {
            throw new Error('不支持的 QQ 搜索类别');
        }
        const keyword = text.trim();
        if (!keyword || [...keyword].length > 60) {
            throw new Error('QQ 搜索关键词需要 1–60 字');
        }
        const body = await this.request(
            '/search',
            {
                keyword,
                type: types[kind],
                page: Math.floor(offset / 20) + 1,
                limit: 20,
            },
            [200],
            valid,
        );
        const raw = array(body.items);
        return {
            items: this.rows(raw, kind),
            total: Number(body.total ?? 0),
            rawCount: raw.length,
            more: !!body.more,
        };
    }

    async songs(ids, valid = () => true, forPlayback = false) {
        const result = [];
        for (const id of ids) {
            if (!valid()) {
                throw new Error('Stale operation');
            }
            const cached = this.songCache.get(id);
            if (cached && (!forPlayback || cached.playbackReady)) {
                result.push(cached);
                continue;
            }
            const r = this.response(
                await this.request(
                    '/getSongInfo',
                    {
                        songmid: id,
                    },
                    [200],
                    valid,
                ),
            );
            const data = this.module(r, 'songinfo');
            const song = qqItem(data.track_info || data);
            if (song) {
                song.playbackReady = true;
                this.songCache.set(song.id, song);
                result.push(song);
            }
        }
        return result;
    }

    async detail(value, valid = () => true) {
        if (value.kind === 'song') {
            const song = (await this.songs([value.id], valid))[0];
            if (!song) {
                throw new Error('歌曲暂不可读取');
            }
            return [song, [], []];
        }
        if (value.kind === 'artist') {
            const r = this.response(
                await this.request(
                    '/getSingerHotsong',
                    {
                        singermid: value.id,
                        limit: 100,
                        page: 1,
                    },
                    [200],
                    valid,
                ),
            );
            const d = this.module(r, 'singer');
            return [value, this.rows(d.songlist), []];
        }
        if (value.chart) {
            const songs = [];
            let offset = 0;
            let total = 0;
            do {
                const body = this.response(
                    await this.request(
                        '/recommend/toplist',
                        {
                            id: value.id,
                            offset,
                            limit: 100,
                            period: value.period,
                        },
                        [200],
                        valid,
                    ),
                );
                const next = this.rows(body.songs);
                songs.push(...next);
                total = Number(body.total ?? offset + next.length);
                offset += next.length;
                if (!body.more || !next.length) {
                    break;
                }
            } while (offset < total);
            return [
                {
                    ...value,
                    trackCount: total,
                },
                songs,
                [],
            ];
        }
        if (value.kind === 'album') {
            const r = this.response(
                await this.request(
                    '/getAlbumInfo',
                    {
                        albummid: value.id,
                    },
                    [200],
                    valid,
                ),
            );
            const d = r.data || {};
            return [
                {
                    ...value,
                    description: d.desc || value.description,
                    date: d.aDate || value.date,
                },
                this.rows(d.list || d.songlist),
                [],
            ];
        }
        if (value.owned) {
            const songs = [];
            let offset = 0;
            let total = 0;
            do {
                const d = await this.request(
                    '/user/playlist-detail',
                    {
                        tid: value.id,
                        offset,
                        limit: 100,
                    },
                    [200],
                    valid,
                );
                const next = this.rows(d.songs);
                songs.push(...next);
                total = Number(d.total ?? songs.length);
                offset += next.length;
                if (!d.more || !next.length) {
                    break;
                }
            } while (offset < total);
            return [
                {
                    ...value,
                    trackCount: total,
                },
                songs,
                [],
            ];
        }
        const r = this.response(
            await this.request(
                '/getSongListDetail',
                {
                    disstid: value.id,
                },
                [200],
                valid,
            ),
        );
        const d = array(r.cdlist)[0] || {};
        return [
            {
                ...value,
                description: d.desc || value.description,
                trackCount: Number(d.total_song_num ?? value.trackCount),
            },
            this.rows(d.songlist),
            [],
        ];
    }

    async artistAlbums(id, offset = 0, valid = () => true) {
        const r = this.response(
            await this.request(
                '/getSingerAlbum',
                {
                    singermid: id,
                    limit: 30,
                    page: offset,
                },
                [200],
                valid,
            ),
        );
        const d = this.module(r, 'singer');
        const raw = array(d.albumList);
        return {
            items: this.rows(raw, 'album'),
            rawCount: raw.length,
            more: offset + raw.length < Number(d.total ?? raw.length),
        };
    }

    async wiki() {
        return 'QQ 音乐 / 歌曲资料';
    }

    async capabilities(valid = () => true) {
        const body = await this.request('/login/channels', {}, [200], valid);
        return body.data?.features || {};
    }

    async vip(valid = () => true) {
        const body = await this.request('/user/vip', {}, [200], valid);
        return { isVip: body.isVip, vipLevel: body.vipLevel || 'unknown' };
    }

    async subscriptionStatus(kind, id, valid = () => true) {
        const body = await this.request('/user/subscription-status', { type: kind, ids: id }, [200], valid);
        return array(body.items).find((entry) => String(entry.id) === String(id))?.status || 'unknown';
    }

    /**
     * 把共同编辑操作映射为 3.3.5 文档的 POST JSON 契约。
     */
    async mutate(route, values, valid = () => true) {
        const request = (path, body) => this.request(path, body, [200], valid);
        if (route === '/like' || route === '/playlist/subscribe' || route === '/album/sub') {
            const kind = route === '/like' ? 'song' : route.split('/')[1];
            const state = await this.subscriptionStatus(kind, values.id, valid);
            if (!['subscribed', 'not-subscribed'].includes(state)) {
                throw new Error('QQ 收藏状态尚未确认，请刷新后重试');
            }
            const enabled = state !== 'subscribed';
            if (kind === 'song') {
                const song = await this.writableSong(values.id, valid);
                const body = await request('/user/song/like', { song, liked: enabled });
                if (body.liked !== enabled) {
                    throw unconfirmedWrite('QQ 红心写入未确认，请刷新核实，不要重复提交');
                }
                return body;
            }
            const body = await request('/user/' + kind + '/subscribe', {
                [kind === 'album' ? 'id' : 'tid']: values.id,
                subscribed: enabled,
            });
            if (body.subscribed !== enabled) {
                throw unconfirmedWrite('QQ 收藏写入未确认，请刷新核实，不要重复提交');
            }
            return body;
        }
        if (route === '/playlist/create' || route === '/playlist/name/update') {
            const name = String(values.name || '').trim();
            if (!name || [...name].length > 20) {
                throw new Error('QQ 歌单名称需要 1–20 字');
            }
            const create = route === '/playlist/create';
            const body = await request(
                '/user/playlist/' + (create ? 'create' : 'rename'),
                create ? { name } : { tid: values.id, name },
            );
            if (!body.verified) {
                throw unconfirmedWrite('QQ 歌单写入未确认，请刷新核实，不要重复提交');
            }
            return {
                ...body,
                playlist: create
                    ? {
                          provider: 'qq',
                          kind: 'playlist',
                          id: String(body.tid),
                          key: 'qq:playlist:' + body.tid,
                          title: body.name,
                          owned: true,
                          dirId: String(body.dirId),
                          trackCount: 0,
                      }
                    : undefined,
            };
        }
        if (route === '/playlist/delete') {
            const body = await request('/user/playlist/delete', { tid: values.id });
            if (!body.deleted || !body.verified) {
                throw unconfirmedWrite('QQ 删除结果未确认，请刷新核实，不要重复提交');
            }
            return body;
        }
        if (route === '/playlist/tracks') {
            const song = await this.writableSong(values.tracks, valid);
            const body = await request('/user/playlist/tracks', {
                tid: values.pid,
                op: values.op,
                songs: [{ id: song.id, type: song.type }],
            });
            if (body.changed === false) {
                const expected = values.op === 'add' ? 'present' : 'absent';
                if (body.verification?.status !== expected) {
                    throw unconfirmedWrite('QQ 歌单内容未确认，请刷新核实，不要重复提交');
                }
            } else if (body.changed !== true) {
                throw unconfirmedWrite('QQ 未确认歌单修改，请刷新核实');
            }
            return body;
        }
        throw new Error('QQ 暂不支持此编辑操作');
    }

    async writableSong(id, valid) {
        const song = (await this.songs([String(id)], valid, true))[0];
        if (!song || !Number.isSafeInteger(song.songID) || song.songID <= 0 || song.songType !== 0) {
            throw new Error('QQ 未确认这首歌是可编辑的普通曲库歌曲');
        }
        return { id: song.songID, mid: song.id, type: 0 };
    }

    async account(valid = () => true) {
        const d = await this.request('/user/detail', {}, [200], valid);
        const p = d.profile || {};
        const info = p.info || p;
        const id = identifier(p.str_musicid ?? p.musicid ?? p.uin ?? info.uin);
        if (!id) {
            const failure = new Error('请登录 QQ 音乐');
            failure.authExpired = true;
            throw failure;
        }
        return [id, String(info.nick ?? info.nickname ?? p.nickname ?? p.nick ?? 'QQ 音乐用户')];
    }

    async userPlaylists(uid, valid = () => true) {
        const rows = [];
        const seenOffsets = new Set();
        let favoriteOffset;
        let total = 0;
        let incomplete = false;
        do {
            const body = await this.request(
                '/user/playlist',
                {
                    playCount: 1,
                    ...(favoriteOffset === undefined ? {} : { favoriteOffset }),
                },
                [200],
                valid,
            );
            rows.push(...array(body.playlist));
            total = Math.max(total, Number(body.total || 0));
            incomplete = !!body.more;
            const next = body.nextFavoriteOffset;
            if (
                !body.more ||
                !Number.isSafeInteger(next) ||
                next <= (favoriteOffset ?? -1) ||
                seenOffsets.has(next)
            ) {
                break;
            }
            seenOffsets.add(next);
            favoriteOffset = next;
        } while (true);
        const items = this.rows(
            rows.map((value) => ({
                ...value,
                owned: typeof value.dirName === 'string' && String(value.uin) === uid,
            })),
            'playlist',
        ).filter((value) => value.dirId !== '201');
        for (const value of items) {
            if (value.owned) {
                value.creatorID = uid;
            } else if (value.creatorID === uid) {
                value.creatorID = '';
            }
        }
        return {
            items,
            total: Math.max(total, items.length),
            rawCount: rows.length,
            more: false,
            incomplete,
        };
    }

    async likedSongs(offset = 0, valid = () => true) {
        const d = await this.request(
            '/user/liked-songs',
            {
                offset,
                limit: 100,
            },
            [200],
            valid,
        );
        const raw = array(d.songs);
        return {
            items: this.rows(raw),
            total: Number(d.total ?? raw.length),
            rawCount: raw.length,
            more: !!d.more,
        };
    }

    async likedAlbums(offset = 0, valid = () => true) {
        const d = await this.request(
            '/user/albums',
            {
                offset,
                limit: 30,
            },
            [200],
            valid,
        );
        const raw = array(d.albums);
        return {
            items: this.rows(raw, 'album'),
            total: Number(d.total ?? raw.length),
            rawCount: raw.length,
            more: !!d.more,
        };
    }

    async preview(value, quality, alternative) {
        return this.playback(value, quality, alternative, () => true, true);
    }

    async playback(value, quality, alternative, valid = () => true, preview = false) {
        const q =
            {
                standard: '128',
                higher: '128',
                exhigh: '320',
                lossless: 'flac',
                hires: 'flac',
                jymaster: 'flac',
                best: 'best',
                ape: 'ape',
            }[quality] || '320';
        // 列表缓存并不保证含有媒体文件标识；播放前按文档读取完整歌曲详情。
        const song = (await this.songs([value.id], valid, true))[0];
        if (!song) {
            throw new Error('QQ 歌曲资料暂不可读取');
        }
        const request = async (level) =>
            (
                await this.request(
                    '/getMusicPlay',
                    {
                        songmid: song.id,
                        mediaId: song.mediaId || '',
                        quality: level,
                        ...(preview ? { preview: 1 } : {}),
                    },
                    [200],
                    valid,
                )
            ).data?.playUrl?.[song.id];
        let track = await request(q);
        if (!track?.url && q !== '128' && q !== 'best' && !preview) {
            track = await request('128');
            if (track?.url) {
                return {
                    ...track,
                    qualityFallback: '标准',
                };
            }
        }
        if (!track?.url) {
            const hints = {
                'playback.maybe-membership': 'QQ 提示可能缺少会员权益，可尝试试听或在官方客户端核实',
                'playback.maybe-region-restricted': 'QQ 提示歌曲可能受地区限制，请在官方客户端核实',
                'playback.preview-missing': 'QQ 确认这首歌没有试听文件',
                'playback.preview-unavailable': 'QQ 暂未提供可用试听片段',
                'playback.quality-file-unavailable': 'QQ 未提供所选音质的文件',
                'playback.quality-detail-unavailable': 'QQ 无法确认所选音质的文件资料',
            };
            throw new Error(
                hints[track?.restriction?.hint?.key] ||
                    (this.host.authenticated?.()
                        ? 'QQ 已登录，但平台未返回标准音质音源；请确认该歌曲在 QQ 官方客户端能否播放'
                        : 'QQ 当前未登录，请用 QQ 或微信扫码登录后重试'),
            );
        }
        return track;
    }

    async discover(tab, offset = 0, category = '全部', valid = () => true) {
        if (tab === 'playlists' || tab === 'categories') {
            const categorized = tab === 'categories';
            let categoryID = category;
            if (categorized && category === '全部') {
                categoryID = (await this.categories(valid))[0]?.id;
                if (!categoryID) {
                    throw new Error('QQ 暂未提供可用的歌单分类');
                }
            }
            const body = await this.request(
                categorized ? '/recommend/category-playlists' : '/recommend/playlists',
                categorized
                    ? {
                          id: categoryID,
                          page: Math.floor(offset / 30) + 1,
                          limit: 30,
                      }
                    : { limit: 30 },
                [200],
                valid,
            );
            const raw = array(body.playlists);
            // 推荐流没有续页参数；仅分类接口按照文档提供分页。
            return {
                items: this.rows(raw, 'playlist'),
                rawCount: raw.length,
                more: categorized && !!body.more,
                ...(categorized ? { category: String(categoryID) } : {}),
            };
        }
        if (['daily', 'guess', 'new-songs'].includes(tab)) {
            const routes = {
                daily: '/user/daily-songs',
                guess: '/user/guess-you-like',
                'new-songs': '/recommend/new-songs',
            };
            const params = tab === 'new-songs' ? { area: category === '全部' ? '5' : category } : {};
            const body = await this.request(routes[tab], params, [200], valid);
            const raw = array(body.songs);
            const names = { 5: '最新', 1: '内地', 6: '港台', 2: '欧美', 4: '韩国', 3: '日本' };
            return {
                items: this.rows(raw),
                rawCount: raw.length,
                more: false,
                ...(tab === 'new-songs'
                    ? {
                          areas: array(body.areas).map((area) => ({
                              id: area.id,
                              name: names[area.id] || area.name,
                          })),
                          area: body.area,
                      }
                    : {}),
            };
        }
        if (tab === 'charts') {
            const body = this.response(await this.request('/recommend/toplists', {}, [200], valid));
            const raw = array(body.groups).flatMap((group) => array(group.toplists));
            return {
                items: this.rows(
                    raw.map((value) => ({
                        ...value,
                        chart: true,
                    })),
                    'playlist',
                ),
                rawCount: raw.length,
                more: false,
            };
        }
        if (tab === 'albums') {
            const body = this.response(
                await this.request('/recommend/new-albums', { limit: 10 }, [200], valid),
            );
            const raw = array(body.albums);
            return { items: this.rows(raw, 'album'), rawCount: raw.length, more: false };
        }
        throw new Error('QQ 暂不支持此类别');
    }

    async categories(valid = () => true) {
        const body = await this.request('/recommend/categories', {}, [200], valid);
        return array(body.groups)
            .flatMap((group) => array(group.categories))
            .map((value) => ({ id: String(value.id), name: value.name }));
    }
}
