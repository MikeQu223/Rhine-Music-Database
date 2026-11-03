// 将上游条目整理为资料库模型，保留标识、时长和封面来源。
export function item(kind, id, title = '正在读取…', artist = '') {
    return {
        kind,
        id: String(id),
        title,
        artist,
        artists: [],
        creatorID: '',
        albumID: '',
        album: '',
        cover: '',
        description: '',
        wiki: '',
        date: '',
        duration: 0,
        trackCount: 0,
        provider: 'netease',
        key: 'netease:' + kind + ':' + id,
    };
}
/**
 * 将网易云原始条目转换为统一资料库模型。
 * 无效标识或名称返回空值，其余字段保留上游语义和原有回退。
 */
export function parse(rawItem, kind) {
    const id = String(rawItem.id ?? '');
    if (!/^[0-9]{1,20}$/.test(id) || typeof rawItem.name !== 'string') {
        return null;
    }
    const artists = rawItem.ar ?? rawItem.artists ?? (rawItem.artist ? [rawItem.artist] : []);
    const creator = rawItem.creator || {};
    const album = rawItem.al ?? rawItem.album ?? {};
    const value = item(
        kind,
        id,
        rawItem.name,
        kind === 'playlist'
            ? (creator.nickname ?? '暂无创建者')
            : artists
                  .map((artist) => artist.name)
                  .filter((v) => typeof v === 'string')
                  .join(' / '),
    );
    Object.assign(value, {
        artists: artists
            .filter((artist) => typeof artist.name === 'string')
            .map((artist) => ({
                id: String(artist.id ?? ''),
                name: artist.name,
            })),
        creatorID: String(creator.userId ?? ''),
        albumID: String(album.id ?? ''),
        album: album.name ?? '',
        cover: rawItem.picUrl ?? rawItem.coverImgUrl ?? album.picUrl ?? '',
        duration: rawItem.dt ?? rawItem.duration ?? 0,
        trackCount: rawItem.trackCount ?? rawItem.size ?? 0,
        description: rawItem.description ?? rawItem.briefDesc ?? '',
    });
    if (kind === 'song' && (rawItem.mv !== undefined || rawItem.mvid !== undefined)) {
        const mv = String(rawItem.mv ?? rawItem.mvid ?? '');
        value.mvID = /^[1-9][0-9]{0,19}$/.test(mv) ? mv : '';
    }
    // 5 是网易云“我喜欢的音乐”歌单标记；该歌单由账号维护，不能改名、删除或取消收藏。
    if (kind === 'playlist' && rawItem.specialType === 5) {
        value.special = true;
    }
    if (rawItem.publishTime > 0) {
        const date = new Date(rawItem.publishTime);
        value.date = date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate());
    }
    return value;
}

function pad(number, width = 2) {
    return ('000000' + number).slice(-width);
}
