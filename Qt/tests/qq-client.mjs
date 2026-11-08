import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { QQAPI, qqItem } from '../../MusicBridge/local-plugins/qq/qq.mjs';
import { safeLoginDetails } from '../../MusicBridge/plugins/sdk/failure.mjs';
import { create } from '../../MusicBridge/local-plugins/qq/index.mjs';
import { createDispatch } from '../../MusicBridge/local-plugins/test-dispatch.mjs';

const dispatch = createDispatch(create, (request, message) => ({
    dispatch({ route, params, cookies }) {
        return Promise.resolve(
            request({ ...message, route, params, cookies: cookies || message.cookies || {} }),
        ).then((response) => ({ ...response, cookies: response.cookies || [] }));
    },
}));
import { createClientHarness } from './fixtures/client-harness.mjs';

const require = createRequire(import.meta.url);
const { bridgeRuntime, bridgeSourceDirectory } = require('./fixtures/bridge-runtime.cjs');
// 读取构建暂存区的归一化器及锁定依赖，与打包桥接使用同一套解码模块。
const format = require(path.join(bridgeSourceDirectory(), 'lyrics-format.cjs'));
const bridgeDirectory = process.argv[2];
const message = (operation, args, cookies = {}) => ({
    route: '/native/qq/' + operation,
    params: { args },
    cookies,
});

const song = {
    id: 42,
    mid: 'songMID',
    type: 0,
    name: 'QQ 曲目',
    singer: [{ mid: 'singerMID', name: '歌手' }],
    album: { mid: 'albumMID', name: '专辑' },
    file: { media_mid: 'mediaMID' },
    interval: 123,
};
// 新专辑接口
const album = {
    id: 105084474,
    mid: 'newAlbumMID',
    name: '解答',
    singers: [{ mid: 'singerMID', name: '文夫' }],
    release_time: '2026-10-22',
    data: { int0: 0, str0: '' },
};

// 平台客户端的读取默认响应；测试按需覆盖，未覆盖的路由会直接失败。
const readRoutes = {
    '/qq/search': { code: 200, total: 31, more: true, items: [song] },
    '/qq/getSongInfo': { response: { code: 0, songinfo: { code: 0, data: { track_info: song } } } },
    '/qq/user/detail': { code: 200, profile: { str_musicid: '42', info: { nick: '微信用户' } } },
    '/qq/user/playlist': {
        code: 200,
        playlist: [
            { tid: 1, dirName: '自己的私密歌单', uin: 42, dirId: 1 },
            { tid: 2, name: '收藏他人歌单', uin: 9, dirId: 1 },
            { tid: 3, dirName: '我喜欢', uin: 42, dirId: 201 },
        ],
    },
    '/qq/user/albums': {
        code: 200,
        albums: [{ albumMID: 'albumMID', albumName: '专辑' }],
        total: 1,
        more: false,
    },
    '/qq/user/daily-songs': { code: 200, songs: [song] },
    '/qq/user/liked-songs': { code: 200, songs: [song], total: 1, more: false },
    '/qq/getMusicPlay': {
        data: { playUrl: { songMID: { url: 'https://sjy6.stream.qqmusic.qq.com/fixture.mp3' } } },
    },
    '/qq/recommend/toplists': {
        code: 200,
        groups: [
            {
                id: 1,
                name: '总榜',
                toplists: [{ id: 4, title: '榜单', cover: 'cover', period: '2026-10-12' }],
            },
        ],
    },
    '/qq/recommend/categories': { groups: [{ categories: [{ id: 8, name: '国风' }] }] },
    '/qq/recommend/playlists': {
        playlists: [{ tid: '70001', title: '推荐', creator: { nick: '作者' } }],
        more: true,
    },
    '/qq/recommend/category-playlists': {
        playlists: [{ tid: '70001', title: '推荐', creator: { nick: '作者' } }],
        more: true,
    },
    '/qq/user/guess-you-like': { songs: [song] },
    '/qq/recommend/new-songs': { songs: [song] },
    '/qq/recommend/new-albums': { code: 200, area: 1, albums: [album] },
};

function createQQClient(overrides = {}) {
    const harness = createClientHarness({ responses: { ...readRoutes, ...overrides } });
    return { ...harness, client: new QQAPI(harness.api) };
}

test('歌曲与专辑条目归一化', () => {
    const parsed = qqItem(song);
    assert.equal(parsed.duration, 123000);
    assert.equal(parsed.mediaId, 'mediaMID');
    assert.equal(parsed.key, 'qq:song:songMID');
    assert.equal(qqItem({ albumMid: 'artistAlbumMID', albumName: '歌手专辑' }, 'album').id, 'artistAlbumMID');
    assert.equal(
        qqItem({ songmid: 'legacySongMID', songname: '专辑曲目', strMediaMid: 'legacyMediaMID' }).mediaId,
        'legacyMediaMID',
    );
    assert.equal(qqItem({ singerMID: 'artistMID', singerName: '歌手' }, 'artist').id, 'artistMID');
    assert.equal(qqItem({ albummid: 'albumMID', name: '专辑', singer: '歌手' }, 'album').artist, '歌手');
});

test('搜索按页请求并保存最新结果', async () => {
    const { client, callsTo, lastCall } = createQQClient({
        '/qq/search': (params) =>
            params.keyword === '无结果'
                ? { code: 200, items: [], total: 0, more: false }
                : { code: 200, total: 31, more: true, items: [song] },
    });

    const page = await client.search('曲目', 'song', 0);
    assert.equal(page.more, true);
    assert.equal(page.items[0].albumID, 'albumMID');
    assert.deepEqual(lastCall('/qq/search').params, { keyword: '曲目', type: 'song', page: 1, limit: 20 });

    const beforeEmpty = callsTo('/qq/search').length;
    assert.equal((await client.search('无结果', 'song')).items.length, 0);
    assert.equal(callsTo('/qq/search').length, beforeEmpty + 1);

    await client.search('专辑', 'album', 20);
    assert.equal(lastCall('/qq/search').params.page, 2);
    assert.equal(lastCall('/qq/search').params.type, 'album');
});

test('账号、歌单、喜欢列表与发现结果归一化', async () => {
    const { client, calls, lastCall } = createQQClient();

    assert.equal((await client.account())[0], '42');
    const personal = await client.userPlaylists('42');
    assert.equal(personal.items.length, 2);
    assert(personal.items[0].owned);
    assert.equal(personal.items[1].creatorID, '9');
    assert.equal((await client.likedAlbums()).items[0].title, '专辑');
    assert.equal((await client.likedSongs()).items[0].provider, 'qq');
    assert.equal((await client.categories())[0].id, '8');

    const charts = await client.discover('charts');
    assert(charts.items[0].chart);
    assert.equal(calls.at(-1).route, '/qq/recommend/toplists');
    await client.discover('daily');
    assert.equal(calls.at(-1).route, '/qq/user/daily-songs');
    for (const tab of ['daily', 'guess', 'new-songs']) {
        assert.equal((await client.discover(tab)).items[0].id, 'songMID');
    }
    const albums = await client.discover('albums');
    assert.equal(albums.items.length, 1);
    assert.equal(albums.items[0].title, '解答');
    assert.equal((await client.discover('categories', 30, '8')).more, true);
    assert.deepEqual(lastCall('/qq/recommend/category-playlists').params, { id: '8', page: 2, limit: 30 });
    assert.equal((await client.discover('playlists')).more, false);
});

test('个人歌单按收藏偏移续读并标记不完整', async () => {
    let incomplete = false;
    const { client } = createQQClient({
        '/qq/user/playlist': (params) => {
            assert.equal(params.uid, undefined);
            assert.equal(params.playCount, 1);
            return {
                more: params.favoriteOffset === undefined || incomplete,
                nextFavoriteOffset: params.favoriteOffset === undefined ? 1000 : undefined,
                playlist: [
                    {
                        tid: String(params.favoriteOffset || 1),
                        name: '收藏歌单',
                        play_cnt: params.favoriteOffset === undefined ? 0 : undefined,
                    },
                ],
                total: 1001,
            };
        },
    });

    const lists = await client.userPlaylists('1152921504716954983');
    assert.equal(lists.items.length, 2);
    assert.equal(lists.items[0].playCount, 0);
    assert.equal(lists.items[1].playCount, undefined);
    assert.equal(lists.incomplete, false);

    incomplete = true;
    assert.equal((await client.userPlaylists('42')).incomplete, true);
});

test('歌单与榜单详情按偏移续读全部曲目', async () => {
    const offsets = [];
    const chartPages = [];
    const { client } = createQQClient({
        '/qq/user/playlist-detail': (params) => {
            offsets.push(params.offset);
            return {
                body: {
                    code: 200,
                    songs: [{ ...song, mid: 'page' + params.offset }],
                    total: 2,
                    more: params.offset === 0,
                },
            };
        },
        '/qq/recommend/toplist': (params) => {
            chartPages.push(params.offset);
            assert.equal(params.period, '2026-10-12');
            return {
                body: {
                    code: 200,
                    songs: [{ ...song, mid: 'chart' + params.offset }],
                    total: 2,
                    more: params.offset === 0,
                },
            };
        },
    });

    const personal = await client.userPlaylists('42');
    const owned = await client.detail(personal.items[0]);
    assert.deepEqual(offsets, [0, 1]);
    assert.equal(owned[1].length, 2);

    const charts = await client.discover('charts');
    assert.equal((await client.detail(charts.items[0]))[1].length, 2);
    assert.deepEqual(chartPages, [0, 1]);
});

test('播放沿用缓存媒体标识并按档位回退', async () => {
    const { client, callsTo, lastCall } = createQQClient();
    const parsed = qqItem(song);

    await client.playback(parsed, 'lossless', false, () => true);
    assert.equal(lastCall('/qq/getMusicPlay').params.mediaId, 'mediaMID');
    assert.equal(lastCall('/qq/getMusicPlay').params.quality, 'flac');

    // 列表缺媒体标识时，播放必须复用已缓存的完整歌曲资料。
    const completeCalls = callsTo('/qq/getSongInfo').length;
    client.rows([{ ...song, file: undefined }]);
    assert.equal(client.songCache.get('songMID').mediaId, 'mediaMID');
    await client.playback({ ...parsed, mediaId: '' }, 'standard', false, () => true);
    assert.equal(callsTo('/qq/getSongInfo').length, completeCalls);
    assert.equal(lastCall('/qq/getMusicPlay').params.mediaId, 'mediaMID');
});

test('缓存不含播放资料时先补全再请求音源', async () => {
    const { client, calls, lastCall } = createQQClient();
    client.rows([{ ...song, file: undefined }]);
    const before = calls.length;

    await client.playback({ ...qqItem(song), mediaId: 'wrongMID' }, 'standard', false, () => true);
    assert.deepEqual(
        calls.slice(before).map((call) => call.route),
        ['/qq/getSongInfo', '/qq/getMusicPlay'],
    );
    assert.equal(lastCall('/qq/getMusicPlay').params.mediaId, 'mediaMID');
});

test('高音质不可用时回退标准音质', async () => {
    const { client, callsTo } = createQQClient({
        '/qq/getMusicPlay': (params) => ({
            data: {
                playUrl: {
                    songMID: {
                        url: params.quality === '128' ? 'https://sjy6.stream.qqmusic.qq.com/fixture.mp3' : '',
                    },
                },
            },
        }),
    });

    const downgraded = await client.playback(qqItem(song), 'lossless', false, () => true);
    assert.equal(downgraded.qualityFallback, '标准');
    assert.deepEqual(
        callsTo('/qq/getMusicPlay')
            .slice(-2)
            .map((call) => call.params.quality),
        ['flac', '128'],
    );
});

test('未登录、无音源和登录失效给出明确错误', async () => {
    const { client, host, callsTo, respond } = createQQClient();
    const parsed = qqItem(song);
    respond('/qq/getMusicPlay', { data: { playUrl: { songMID: { url: '' } } } });

    host.authenticated = () => true;
    const beforeExhigh = callsTo('/qq/getMusicPlay').length;
    await assert.rejects(
        client.playback(parsed, 'exhigh', false, () => true),
        /平台未返回标准音质音源/,
    );
    assert.equal(callsTo('/qq/getMusicPlay').length, beforeExhigh + 2);

    const beforeStandard = callsTo('/qq/getMusicPlay').length;
    await assert.rejects(
        client.playback(parsed, 'standard', false, () => true),
        /平台未返回标准音质音源/,
    );
    assert.equal(callsTo('/qq/getMusicPlay').length, beforeStandard + 1);

    host.authenticated = () => false;
    respond('/qq/getMusicPlay', { code: 401, message: '登录已失效' });
    await assert.rejects(
        client.playback(parsed, 'lossless', false, () => true),
        /401/,
    );
});

test('试听请求与受限提示遵循平台返回', async () => {
    let source = { url: 'https://sjy6.stream.qqmusic.qq.com/fixture.mp3', quality: 'flac' };
    const { client, lastCall } = createQQClient({
        '/qq/getMusicPlay': () => ({ data: { playUrl: { songMID: source } } }),
    });
    const parsed = qqItem(song);

    const played = await client.playback(parsed, 'best', false);
    assert.equal(played.quality, 'flac');
    assert.equal(lastCall('/qq/getMusicPlay').params.quality, 'best');

    source = { ...source, preview: true };
    assert.equal((await client.preview(parsed, 'best', false)).preview, true);
    assert.equal(lastCall('/qq/getMusicPlay').params.preview, 1);

    source = { url: '', restriction: { hint: { key: 'playback.preview-missing' } } };
    await assert.rejects(client.preview(parsed, 'best', false), /没有试听文件/);

    source = { url: '', restriction: { hint: { key: 'playback.maybe-region-restricted' } } };
    await assert.rejects(client.playback(parsed, 'best', false), /可能受地区限制/);
});

test('写入契约先核实状态，未确认时只写入一次', async () => {
    const mutationSong = { ...song, file: { ...song.file } };
    let state = 'not-subscribed';
    let writeCalls = 0;
    let verification = 'present';
    const { client, api, respond } = createQQClient({
        '/qq/getSongInfo': () => ({
            response: { code: 0, songinfo: { code: 0, data: { track_info: mutationSong } } },
        }),
        '/qq/user/subscription-status': (params) => ({ items: [{ id: params.ids, status: state }] }),
        '/qq/user/song/like': (params) => {
            ++writeCalls;
            assert.deepEqual(params.song, { id: 42, mid: 'songMID', type: 0 });
            return { code: 200, liked: params.liked };
        },
        '/qq/user/album/subscribe': (params) => {
            ++writeCalls;
            return { code: 200, subscribed: params.subscribed };
        },
        '/qq/user/playlist/subscribe': (params) => {
            ++writeCalls;
            return { code: 200, subscribed: params.subscribed };
        },
        '/qq/user/playlist/tracks': (params) => {
            ++writeCalls;
            assert.deepEqual(params.songs, [{ id: 42, type: 0 }]);
            return { changed: false, verification: { status: verification } };
        },
        '/qq/user/playlist/create': () => {
            ++writeCalls;
            return { code: 200, tid: '70001', dirId: 1, name: '服务器确认的名称', verified: true };
        },
        '/qq/user/playlist/rename': (params) => {
            ++writeCalls;
            assert.deepEqual(params, { tid: '70001', name: '新名称' });
            return { verified: true, name: '新名称' };
        },
        '/qq/user/playlist/delete': (params) => {
            ++writeCalls;
            assert.deepEqual(params, { tid: '70001' });
            return { verified: true, deleted: true };
        },
    });

    assert.equal((await client.mutate('/like', { id: 'songMID' })).liked, true);
    state = 'subscribed';
    assert.equal((await client.mutate('/like', { id: 'songMID' })).liked, false);
    assert.equal((await client.mutate('/album/sub', { id: 'albumMID' })).subscribed, false);
    assert.equal((await client.mutate('/playlist/subscribe', { id: '70001' })).subscribed, false);

    // 状态未知时禁止写入，避免重复提交。
    state = 'unknown';
    const beforeUnknown = writeCalls;
    await assert.rejects(client.mutate('/album/sub', { id: 'albumMID' }), /状态尚未确认/);
    assert.equal(writeCalls, beforeUnknown);

    const created = await client.mutate('/playlist/create', { name: '新歌单' });
    assert.equal(created.playlist.title, '服务器确认的名称');
    assert.equal(created.playlist.provider, 'qq');
    await assert.rejects(client.mutate('/playlist/create', { name: '长'.repeat(21) }), /1–20/);
    await client.mutate('/playlist/name/update', { id: '70001', name: '新名称' });
    await client.mutate('/playlist/delete', { id: '70001' });

    await client.mutate('/playlist/tracks', { pid: '70001', tracks: 'songMID', op: 'add' });
    verification = 'unknown';
    const beforeUnconfirmed = writeCalls;
    await assert.rejects(
        client.mutate('/playlist/tracks', { pid: '70001', tracks: 'songMID', op: 'add' }),
        /核实/,
    );
    assert.equal(writeCalls, beforeUnconfirmed + 1);

    // 非普通曲库歌曲不可加入歌单。
    mutationSong.type = 1;
    const blocked = new QQAPI(api);
    respond('/qq/getSongInfo', () => ({
        response: { code: 0, songinfo: { code: 0, data: { track_info: mutationSong } } },
    }));
    await assert.rejects(
        blocked.mutate('/playlist/tracks', { pid: '70001', tracks: 'songMID', op: 'add' }),
        /普通曲库/,
    );
});

test('登录失败详情保留错误码并隐去凭据', () => {
    const failure = safeLoginDetails({
        errorKey: 'auth.login-rejected',
        primaryFailure: { upstreamCode: 20279, token: 'private' },
        writeAttempted: true,
        verification: 'unconfirmed',
    });
    assert.equal(failure.primaryFailure.upstreamCode, 20279);
    assert.equal(JSON.stringify(failure).includes('private'), false);
    assert.equal(failure.writeAttempted, true);
});

test('歌词解析翻译、无时标判定与词作者行过滤', () => {
    const qq = format.normalizeLyrics('qq', {
        response: {
            lyric: '[00:01.0]原文\n[00:02.00]第二句',
            trans: Buffer.from('[00:01.0]翻译').toString('base64'),
        },
    }).document;
    assert.equal(qq.lines[0].translation, '翻译');
    assert.equal(format.normalizeLyrics('qq', { lyric: '只有文字\n没有时间' }).document.timing, 'none');
    assert.equal(
        format.normalizeLyrics('qq', { lyric: '[00:00.00]一\n[00:00.00]二' }).document.timing,
        'none',
    );

    const credits = format.normalizeLyrics('qq', {
        lyric:
            '[ti:回家的路]\n[ar:HOYO-MiX]\n[00:00.07]回家的路 - HOYO-MiX\n' +
            '[00:00.29]作词 Lyricist：木木\n[00:00.67]当你走上回家的路\n[00:04.03]星星发着光',
    }).document;
    assert.deepEqual(
        credits.lines.map((line) => line.startMs),
        [670, 4030],
    );
});

test('多语言在线歌词保留 Unicode 原文并识别翻译字节编码', () => {
    const sample = JSON.parse(
        fs.readFileSync(new URL('./fixtures/lyrics-encodings.json', import.meta.url), 'utf8'),
    ).find((item) => item.name === 'shift-jis');
    const original = '[00:01.00]별빛을 따라 걷는 밤\n[00:04.00]君の声が聞こえる';
    const document = format.normalizeLyrics('qq', { lyric: original, trans: sample.base64 }).document;
    assert.equal(document.lines[0].text, '별빛을 따라 걷는 밤');
    assert.equal(document.lines[1].text, '君の声が聞こえる');
    assert.equal(document.lines[0].translation, '君の声が聞こえる 夜空に輝く星を見上げて');
    const broken = format.normalizeLyrics('qq', { lyric: original, trans: '//4AAAE=' }).document;
    assert.deepEqual(
        broken.lines.map((line) => line.text),
        document.lines.map((line) => line.text),
    );
    assert.ok(broken.lines.every((line) => !line.translation));
});

test('设备身份跨进程复用且不写入登录凭据', () => {
    const { bridge, runtime } = bridgeRuntime(bridgeDirectory);
    const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-device-state-'));
    const devicePath = path.join(temporaryDirectory, 'qq-device.json');
    const modulePath = path.join(
        bridgeSourceDirectory(),
        'node_modules/@yakult-green-tea/qq-music-api/dist/src/services/auth/deviceContext.js',
    );
    const source = `
const context = require(process.env.RHINE_TEST_DEVICE_MODULE);
const store = context.createDeviceContextStore(context.createDefaultDeviceContextRepository());
const device = store.get();
store.persist();
const digest = require('node:crypto').createHash('sha256').update(JSON.stringify(device)).digest('hex');
process.stdout.write(digest);
`;
    const readDeviceDigest = () => {
        const result = spawnSync(runtime, ['-e', source], {
            encoding: 'utf8',
            env: {
                ...process.env,
                LOG_LEVEL: 'silent',
                QQ_AUTH_STATE_PATH: devicePath,
                RHINE_TEST_DEVICE_MODULE: modulePath,
            },
        });
        assert.equal(result.status, 0, result.stderr);
        return result.stdout;
    };
    try {
        const firstDigest = readDeviceDigest();
        const secondDigest = readDeviceDigest();
        assert.match(firstDigest, /^[a-f0-9]{64}$/);
        assert.equal(firstDigest, secondDigest);
        const record = JSON.parse(fs.readFileSync(devicePath));
        assert.equal(record.version, 1);
        assert.equal(record.device.musickey, undefined);
        assert.equal(record.device.qqmusic_session, undefined);
    } finally {
        fs.rmSync(temporaryDirectory, { recursive: true, force: true });
    }
});

test('原生调度保留 QQ 会话且不暴露私有凭据', async () => {
    const sessions = [{ token: 'private-fixture', credential: { musickey: 'private-key' } }];
    const qq = await dispatch(message('request', ['/user/detail', {}]), async (request) => {
        assert.equal(request.route, '/qq/user/detail');
        return {
            body: { code: 200, profile: { musicid: '42', nick: '测试账号' } },
            qqSessions: sessions,
            cookies: [],
        };
    });
    assert.equal(qq.body.value.profile.musicid, '42');
    assert.deepEqual(qq.qqSessions, sessions);
    assert.equal(JSON.stringify(qq.body).includes('private-fixture'), false);

    // 失败请求期间续期的会话仍须交还私有 Host。
    const renewed = [{ token: 'opaque-fixture', credential: { musickey: 'renewed-private' } }];
    const rejected = await dispatch(message('search', ['本地', 'song', 0]), async () => ({
        body: { code: 502, errorKey: 'search.rejected', message: '搜索被拒绝' },
        qqSessions: renewed,
    }));
    assert.deepEqual(rejected.qqSessions, renewed);
    assert.equal(rejected.body.errorKey, 'search.rejected');
    assert.equal(JSON.stringify(rejected.body).includes('renewed-private'), false);
});

test('原生调度失败保留重试信息并隐去原始凭据', async () => {
    const failure = await dispatch(message('request', ['/login/qr/check', {}]), async () => {
        throw {
            body: { code: 429, failureReason: 'local-backoff', retryAfterMs: 120000, rawToken: 'secret' },
        };
    });
    assert.equal(failure.body.code, 429);
    assert.equal(failure.body.retryAfterMs, 120000);
    assert.equal(JSON.stringify(failure).includes('secret'), false);
});
