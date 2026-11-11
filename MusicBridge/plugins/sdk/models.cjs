'use strict';

/**
 * 统一模型轻量校验器（v2）。
 *
 * 不引入 JSON Schema 运行时依赖；只校验 core 需要的形状、长度和枚举。
 * 插件返回的原始平台字段不在校验范围内；平台差异应放在 extensions。
 */

class ContractError extends Error {
    constructor(path, message) {
        super(path ? path + ': ' + message : message);
        this.name = 'ContractError';
        this.path = path || '';
    }
}

const PROVIDER = /^[a-z0-9-]{1,40}$/;
const KEY = /^[a-z0-9-]{1,40}:(song|album|artist|playlist|mv):[^\s]{1,200}$/;
const TIERS = new Set(['auto', 'standard', 'hq', 'lossless', 'hires', 'master', 'original']);
const TIMINGS = new Set(['none', 'line', 'word']);
const SUBSCRIPTION = new Set(['subscribed', 'not-subscribed', 'unknown']);

function fail(path, message) {
    throw new ContractError(path, message);
}

function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isString(value, max = Infinity) {
    return typeof value === 'string' && value.length <= max;
}

function isNumber(value) {
    return typeof value === 'number' && Number.isFinite(value);
}

function isInteger(value) {
    return Number.isInteger(value);
}

function isBoolean(value) {
    return typeof value === 'boolean';
}

function check(condition, path, message) {
    if (!condition) {
        fail(path, message);
    }
}

function checkObject(value, path) {
    check(isObject(value), path, 'expected object');
}

function checkString(value, path, { min = 0, max = Infinity, pattern } = {}) {
    check(typeof value === 'string', path, 'expected string');
    check(value.length >= min, path, 'too short');
    check(value.length <= max, path, 'too long');
    if (pattern) {
        check(pattern.test(value), path, 'invalid format');
    }
}

function optionalString(value, path, options) {
    if (value !== undefined && value !== null) {
        checkString(value, path, options);
    }
}

function optionalBoolean(value, path) {
    if (value !== undefined) {
        check(isBoolean(value), path, 'expected boolean');
    }
}

function optionalNumber(value, path, { min = -Infinity, max = Infinity } = {}) {
    if (value !== undefined && value !== null) {
        check(isNumber(value), path, 'expected number');
        check(value >= min && value <= max, path, 'out of range');
    }
}

function checkArtistRef(value, path) {
    checkObject(value, path);
    checkString(value.id, path + '.id', { max: 120 });
    checkString(value.name, path + '.name', { min: 1, max: 240 });
}

function checkEntityBase(value, path, kind) {
    checkObject(value, path);
    checkString(value.provider, path + '.provider', { pattern: PROVIDER });
    check(value.kind === kind, path + '.kind', 'expected ' + kind);
    checkString(value.id, path + '.id', { min: 1, max: 200 });
    checkString(value.key, path + '.key', { pattern: KEY });
    checkString(value.title, path + '.title', { min: 1, max: 500 });
    checkString(value.artist, path + '.artist', { max: 500 });
    check(Array.isArray(value.artists), path + '.artists', 'expected array');
    check(value.artists.length <= 64, path + '.artists', 'too many artists');
    value.artists.forEach((artist, index) => checkArtistRef(artist, path + '.artists[' + index + ']'));
    optionalString(value.creatorID, path + '.creatorID', { max: 200 });
    optionalString(value.albumID, path + '.albumID', { max: 200 });
    optionalString(value.album, path + '.album', { max: 500 });
    optionalString(value.albumAudioID, path + '.albumAudioID', { max: 200 });
    optionalString(value.mediaId, path + '.mediaId', { max: 200 });
    if (value.songID !== undefined) {
        check(
            isInteger(value.songID) && value.songID >= 0,
            path + '.songID',
            'expected non-negative integer',
        );
    }
    optionalString(value.cover, path + '.cover', { max: 2000 });
    optionalString(value.description, path + '.description', { max: 20000 });
    optionalString(value.wiki, path + '.wiki', { max: 20000 });
    optionalString(value.date, path + '.date', { max: 40 });
    optionalNumber(value.duration, path + '.duration', { min: 0 });
    optionalNumber(value.trackCount, path + '.trackCount', { min: 0 });
    optionalString(value.mvID, path + '.mvID', { max: 40 });
    optionalBoolean(value.special, path + '.special');
    optionalBoolean(value.owned, path + '.owned');
    optionalString(value.dirId, path + '.dirId', { max: 40 });
    optionalString(value.listid, path + '.listid', { max: 200 });
    if (value.listType !== undefined) {
        check(isInteger(value.listType), path + '.listType', 'expected integer');
    }
    optionalBoolean(value.chart, path + '.chart');
    optionalString(value.period, path + '.period', { max: 40 });
    optionalString(value.rankCid, path + '.rankCid', { max: 200 });
    optionalBoolean(value.isDefault, path + '.isDefault');
    optionalBoolean(value.isFavorite, path + '.isFavorite');
    if (value.playCount !== undefined) {
        check(
            isInteger(value.playCount) && value.playCount >= 0,
            path + '.playCount',
            'expected non-negative integer',
        );
    }
    optionalBoolean(value.virtual, path + '.virtual');
    if (value.extensions !== undefined) {
        checkObject(value.extensions, path + '.extensions');
    }
}

function checkEntity(value, path) {
    checkObject(value, path);
    check(['song', 'album', 'artist', 'playlist'].includes(value.kind), path + '.kind', 'invalid kind');
    checkEntityBase(value, path, value.kind);
}

function checkTrack(value, path) {
    checkEntityBase(value, path, 'song');
}

function checkAlbum(value, path) {
    checkEntityBase(value, path, 'album');
}

function checkPlaylist(value, path) {
    checkEntityBase(value, path, 'playlist');
}

function checkPage(value, path, itemCheck) {
    checkObject(value, path);
    check(Array.isArray(value.items), path + '.items', 'expected array');
    value.items.forEach((item, index) => itemCheck(item, path + '.items[' + index + ']'));
    check(
        isInteger(value.rawCount) && value.rawCount >= 0,
        path + '.rawCount',
        'expected non-negative integer',
    );
    check(isBoolean(value.more), path + '.more', 'expected boolean');
    if (value.total !== undefined) {
        check(isInteger(value.total) && value.total >= 0, path + '.total', 'expected non-negative integer');
    }
    optionalString(value.notice, path + '.notice', { max: 500 });
    optionalBoolean(value.incomplete, path + '.incomplete');
    optionalString(value.category, path + '.category', { max: 120 });
    if (value.areas !== undefined) {
        check(Array.isArray(value.areas), path + '.areas', 'expected array');
        value.areas.forEach((area, index) => {
            const areaPath = path + '.areas[' + index + ']';
            checkObject(area, areaPath);
            checkString(area.id, areaPath + '.id', { max: 120 });
            checkString(area.name, areaPath + '.name', { max: 120 });
        });
    }
    optionalNumber(value.area, path + '.area');
}

function checkDetail(value, path) {
    check(Array.isArray(value), path, 'expected tuple');
    check(value.length === 3, path, 'expected 3 elements');
    checkEntity(value[0], path + '[0]');
    checkPage({ items: value[1], rawCount: value[1].length, more: false }, path + '[1]', checkTrack);
    check(Array.isArray(value[2]), path + '[2]', 'expected array');
    value[2].forEach((id, index) => checkString(id, path + '[2][' + index + ']', { max: 200 }));
}

function checkPlayback(value, path) {
    checkObject(value, path);
    checkString(value.url, path + '.url', { min: 1, max: 4000 });
    check(TIERS.has(value.tier), path + '.tier', 'invalid tier');
    optionalString(value.format, path + '.format', { max: 40 });
    optionalNumber(value.bitrate, path + '.bitrate', { min: 0 });
    optionalNumber(value.sampleRate, path + '.sampleRate', { min: 0 });
    optionalNumber(value.bitDepth, path + '.bitDepth', { min: 0 });
    optionalString(value.providerTier, path + '.providerTier', { max: 40 });
    optionalString(value.qualityId, path + '.qualityId', { max: 40 });
    optionalBoolean(value.trial, path + '.trial');
    optionalString(value.restriction, path + '.restriction', { max: 500 });
    optionalString(value.qualityFallback, path + '.qualityFallback', { max: 40 });
}

function checkLyricLine(value, path) {
    checkObject(value, path);
    check(isNumber(value.startMs) && value.startMs >= 0, path + '.startMs', 'expected non-negative number');
    if (value.endMs !== undefined && value.endMs !== null) {
        check(isNumber(value.endMs) && value.endMs >= 0, path + '.endMs', 'expected non-negative number');
    }
    checkString(value.text, path + '.text', { max: 2000 });
    optionalString(value.translation, path + '.translation', { max: 2000 });
    if (value.words !== undefined) {
        check(Array.isArray(value.words), path + '.words', 'expected array');
        value.words.forEach((word, index) => {
            const wordPath = path + '.words[' + index + ']';
            checkObject(word, wordPath);
            check(
                isNumber(word.startMs) && word.startMs >= 0,
                wordPath + '.startMs',
                'expected non-negative number',
            );
            checkString(word.text, wordPath + '.text', { max: 500 });
            optionalNumber(word.endMs, wordPath + '.endMs', { min: 0 });
        });
    }
}

function checkLyrics(value, path) {
    checkObject(value, path);
    check(value.version === 1, path + '.version', 'expected 1');
    checkString(value.source, path + '.source', { min: 1, max: 80 });
    check(TIMINGS.has(value.timing), path + '.timing', 'invalid timing');
    check(
        isNumber(value.offsetMs) && value.offsetMs >= -10000 && value.offsetMs <= 10000,
        path + '.offsetMs',
        'out of range',
    );
    check(Array.isArray(value.lines), path + '.lines', 'expected array');
    value.lines.forEach((line, index) => checkLyricLine(line, path + '.lines[' + index + ']'));
    optionalString(value.plainText, path + '.plainText', { max: 200000 });
}

function checkAccount(value, path) {
    checkObject(value, path);
    checkString(value.uid, path + '.uid', { min: 1, max: 200 });
    checkString(value.nickname, path + '.nickname', { min: 1, max: 200 });
}

function checkCapabilities(value, path) {
    checkObject(value, path);
    for (const key of [
        'search',
        'suggest',
        'resolveLink',
        'detail',
        'playback',
        'preview',
        'lyrics',
        'account',
        'login',
        'vip',
        'discover',
        'categories',
        'userPlaylists',
        'likedSongs',
        'likedAlbums',
        'mv',
        'officialPlayback',
        'alternativeSource',
    ]) {
        optionalBoolean(value[key], path + '.' + key);
    }
    for (const key of ['mutations', 'playlistManagement']) {
        if (value[key] !== undefined) {
            checkObject(value[key], path + '.' + key);
            for (const [name, enabled] of Object.entries(value[key])) {
                check(isBoolean(enabled), path + '.' + key + '.' + name, 'expected boolean');
            }
        }
    }
}

function checkVip(value, path) {
    checkObject(value, path);
    if (value.isVip !== undefined) {
        check(
            isBoolean(value.isVip) || typeof value.isVip === 'string' || isNumber(value.isVip),
            path + '.isVip',
            'expected boolean, string or number',
        );
    }
    optionalString(value.vipLevel, path + '.vipLevel', { max: 40 });
}

function checkComment(value, path) {
    checkObject(value, path);
    checkString(value.id, path + '.id', { min: 1, max: 200 });
    checkString(value.content, path + '.content', { min: 1, max: 4000 });
    checkString(value.nickname, path + '.nickname', { min: 1, max: 240 });
    optionalString(value.userId, path + '.userId', { max: 200 });
    optionalString(value.avatarUrl, path + '.avatarUrl', { max: 2000 });
    optionalNumber(value.time, path + '.time', { min: 0 });
    optionalNumber(value.likedCount, path + '.likedCount', { min: 0 });
    optionalNumber(value.replyCount, path + '.replyCount', { min: 0 });
    optionalString(value.replyTo, path + '.replyTo', { max: 240 });
    optionalString(value.location, path + '.location', { max: 120 });
    if (value.inlineReplies !== undefined) {
        check(Array.isArray(value.inlineReplies), path + '.inlineReplies', 'expected array');
        value.inlineReplies.forEach((reply, index) => checkComment(reply, path + '.inlineReplies[' + index + ']'));
    }
}

function checkCommentsPage(value, path) {
    checkObject(value, path);
    check(Array.isArray(value.comments), path + '.comments', 'expected array');
    value.comments.forEach((comment, index) => checkComment(comment, path + '.comments[' + index + ']'));
    check(isInteger(value.totalCount) && value.totalCount >= 0, path + '.totalCount', 'expected non-negative integer');
    check(isBoolean(value.hasMore), path + '.hasMore', 'expected boolean');
    optionalString(value.cursor, path + '.cursor', { max: 500 });
}

function checkCommentReplies(value, path) {
    checkObject(value, path);
    check(Array.isArray(value.comments), path + '.comments', 'expected array');
    value.comments.forEach((comment, index) => checkComment(comment, path + '.comments[' + index + ']'));
    check(isBoolean(value.hasMore), path + '.hasMore', 'expected boolean');
    optionalString(value.time, path + '.time', { max: 500 });
}

function checkMutation(value, path) {
    checkObject(value, path);
    check(isBoolean(value.applied), path + '.applied', 'expected boolean');
    optionalString(value.state, path + '.state', { max: 40 });
    optionalString(value.message, path + '.message', { max: 500 });
    if (value.item !== undefined) {
        checkEntity(value.item, path + '.item');
    }
    if (value.countDelta !== undefined) {
        check(isInteger(value.countDelta), path + '.countDelta', 'expected integer');
    }
}

function checkError(value, path) {
    checkObject(value, path);
    check(isInteger(value.code) && value.code >= 100 && value.code <= 599, path + '.code', 'invalid code');
    checkString(value.message, path + '.message', { min: 1, max: 500 });
    optionalBoolean(value.authExpired, path + '.authExpired');
    optionalNumber(value.retryAfterMs, path + '.retryAfterMs', { min: 0 });
    for (const key of ['failureStage', 'failureReason', 'errorKey', 'upstreamErrorKey']) {
        optionalString(value[key], path + '.' + key, { max: 80, pattern: /^[a-z.-]{1,80}$/ });
    }
    for (const key of ['upstreamHttpStatus', 'upstreamCode', 'upstreamGlobalCode', 'upstreamSubCode']) {
        if (value[key] !== undefined) {
            check(isInteger(value[key]), path + '.' + key, 'expected integer');
        }
    }
    optionalBoolean(value.retryable, path + '.retryable');
    optionalBoolean(value.writeAttempted, path + '.writeAttempted');
    if (value.verification !== undefined) {
        check(value.verification === 'unconfirmed', path + '.verification', 'invalid verification');
    }
}

function checkStringArray(value, path) {
    check(Array.isArray(value), path, 'expected array');
    value.forEach((item, index) => checkString(item, path + '[' + index + ']', { max: 200 }));
}

/**
 * 按 operation 校验返回值。返回 true 或抛 ContractError。
 */
function validate(operation, value) {
    const path = operation;
    switch (operation) {
        case 'search':
            checkPage(value, path, checkEntity);
            break;
        case 'trackPage':
        case 'likedSongs':
            checkPage(value, path, checkTrack);
            break;
        case 'artistAlbums':
        case 'likedAlbums':
            checkPage(value, path, checkAlbum);
            break;
        case 'catalog':
        case 'discover':
            checkPage(value, path, checkEntity);
            break;
        case 'songs':
            check(Array.isArray(value), path, 'expected array');
            value.forEach((item, index) => checkTrack(item, path + '[' + index + ']'));
            break;
        case 'userPlaylists':
            checkPage(value, path, checkPlaylist);
            break;
        case 'likedIDs':
        case 'suggest':
            checkStringArray(value, path);
            break;
        case 'categories':
            check(Array.isArray(value), path, 'expected array');
            value.forEach((item, index) => {
                const itemPath = path + '[' + index + ']';
                checkObject(item, itemPath);
                checkString(item.id, itemPath + '.id', { min: 1, max: 200 });
                checkString(item.name, itemPath + '.name', { min: 1, max: 200 });
            });
            break;
        case 'likedState':
            checkObject(value, path);
            for (const [key, state] of Object.entries(value)) {
                check(SUBSCRIPTION.has(state), path + '.' + key, 'invalid subscription status');
            }
            break;
        case 'detail':
            checkDetail(value, path);
            break;
        case 'playback':
        case 'preview':
            checkPlayback(value, path);
            break;
        case 'lyrics':
            if (value !== null) {
                checkLyrics(value, path);
            }
            break;
        case 'account':
            if (value !== null) {
                checkAccount(value, path);
            }
            break;
        case 'capabilities':
            checkCapabilities(value, path);
            break;
        case 'vip':
            checkVip(value, path);
            break;
        case 'subscriptionStatus':
            check(SUBSCRIPTION.has(value), path, 'invalid subscription status');
            break;
        case 'mutate':
            checkMutation(value, path);
            break;
        case 'comments':
            checkCommentsPage(value, path);
            break;
        case 'commentReplies':
            checkCommentReplies(value, path);
            break;
        case 'resolveLink':
            if (value !== null) {
                checkObject(value, path);
                checkString(value.provider, path + '.provider', { pattern: PROVIDER });
                check(
                    ['song', 'album', 'artist', 'playlist', 'mv'].includes(value.kind),
                    path + '.kind',
                    'invalid kind',
                );
                checkString(value.id, path + '.id', { min: 1, max: 200 });
            }
            break;
        case 'wiki':
            checkString(value, path, { max: 20000 });
            break;
        case 'mv':
            if (value !== null) {
                checkObject(value, path);
            }
            break;
        case 'mvVersions':
            checkObject(value, path);
            break;
        case 'request':
            break;
        default:
            break;
    }
    return true;
}

function assertValid(operation, value) {
    validate(operation, value);
    return value;
}

/** 只保留可安全交付给 UI 的错误摘要。 */
function sanitizeError(error) {
    const source = error && typeof error === 'object' ? error : {};
    const result = {
        code: Number.isInteger(source.code) ? source.code : 503,
        message: typeof source.message === 'string' ? source.message.slice(0, 500) : '音乐请求失败',
    };
    for (const key of ['failureStage', 'failureReason', 'errorKey', 'upstreamErrorKey']) {
        if (typeof source[key] === 'string' && /^[a-z.-]{1,80}$/.test(source[key])) {
            result[key] = source[key];
        }
    }
    for (const key of [
        'retryAfterMs',
        'upstreamHttpStatus',
        'upstreamCode',
        'upstreamGlobalCode',
        'upstreamSubCode',
    ]) {
        if (typeof source[key] === 'number' && Number.isFinite(source[key])) {
            result[key] = source[key];
        }
    }
    for (const key of ['authExpired', 'retryable', 'writeAttempted']) {
        if (typeof source[key] === 'boolean') {
            result[key] = source[key];
        }
    }
    if (source.verification === 'unconfirmed') {
        result.verification = 'unconfirmed';
    }
    return result;
}

module.exports = {
    ContractError,
    validate,
    assertValid,
    sanitizeError,
    checks: {
        entity: checkEntity,
        track: checkTrack,
        album: checkAlbum,
        playlist: checkPlaylist,
        page: checkPage,
        detail: checkDetail,
        playback: checkPlayback,
        lyrics: checkLyrics,
        account: checkAccount,
        capabilities: checkCapabilities,
        vip: checkVip,
        mutation: checkMutation,
        error: checkError,
    },
};
