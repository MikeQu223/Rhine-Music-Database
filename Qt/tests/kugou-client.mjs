import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { KugouAPI, kugouItem } from '../../MusicBridge/local-plugins/kugou/kugou.mjs';
import { create } from '../../MusicBridge/local-plugins/kugou/index.mjs';
import { createDispatch } from '../../MusicBridge/local-plugins/test-dispatch.mjs';

const dispatch = createDispatch(create, (request, message) => ({
    dispatch({ route, params, cookies }) {
        return Promise.resolve(
            request({ ...message, route, params, cookies: cookies || message.cookies || {} }),
        ).then((response) => ({ ...response, cookies: response.cookies || [] }));
    },
}));
import format from '../../MusicBridge/lyrics-format.cjs';
import { createClientHarness } from './fixtures/client-harness.mjs';

const require = createRequire(import.meta.url);
const { createBridge, ROUTES } = require('../../MusicBridge/local-plugins/kugou/kugou-transport.cjs');
const { bridgeRuntime } = require('./fixtures/bridge-runtime.cjs');
const hook = path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'fixtures/bridge-http.cjs');
const bridgeDirectory = process.argv[2];
const message = (operation, args, cookies = {}) => ({
    route: '/native/kugou/' + operation,
    params: { args },
    cookies,
});

const hash = 'A5BF5F27C007E1C1AC5914345B07CD28';
const song = { hash, name: '歌手 - 曲目', album_id: '123', mixsongid: 456, timelen: 180000 };

test('桥接层注册设备并复用已保存的凭据', async () => {
    const calls = [];
    const bridge = createBridge(
        {
            register_dev: async ({ cookie }) => {
                assert.equal(cookie.token, 'saved-token');
                calls.push('register');
                return { body: { status: 1 }, cookie: ['dfid=registered-device'] };
            },
            song_url: async ({ cookie, hash: selected }) => {
                calls.push('url');
                assert.equal(cookie.dfid, 'registered-device');
                assert.equal(selected, hash);
                return { body: { status: 1, url: ['https://fs.kugou.com/test.mp3'] }, cookie: [] };
            },
        },
        { KUGOU_API_GUID: 'fixed-device' },
    );

    let response = await bridge.dispatch({
        route: '/kugou/song/url',
        params: { hash, token: 'malicious-token' },
        cookies: { __kugou: { token: 'saved-token' } },
    });
    assert.deepEqual(calls, ['register', 'url']);
    assert.equal(response.kugouCredentials.dfid, 'registered-device');

    // 第二次请求直接复用新设备标识，不再重复注册。
    response = await bridge.dispatch({
        route: '/kugou/song/url',
        params: { hash },
        cookies: { __kugou: response.kugouCredentials },
    });
    assert.deepEqual(calls, ['register', 'url', 'url']);
});

test('二维码状态映射到平台码且不回传登录凭据', async () => {
    const bridge = createBridge(
        {
            login_qr_check: async () => ({
                body: { data: { status: 4, token: 'new-token', userid: 42 } },
                cookie: ['token=new-token', 'userid=42'],
            }),
        },
        {},
    );
    const response = await bridge.dispatch({ route: '/kugou/login/qr/check' });
    assert.equal(response.body.code, 803);
    assert.equal(response.kugouCredentials.token, 'new-token');
    assert.equal(JSON.stringify(response.body).includes('new-token'), false);

    for (const [status, code] of [
        [0, 800],
        [1, 801],
        [2, 802],
        [3, 503],
    ]) {
        const api = createBridge(
            { login_qr_check: async () => ({ body: { data: { status } }, cookie: [] }) },
            {},
        );
        assert.equal((await api.dispatch({ route: '/kugou/login/qr/check' })).body.code, code);
    }
});

test('未支持路由被拒绝，失败详情不泄露私有配置', async () => {
    const failure = createBridge(
        {
            search: async () => {
                throw { body: { msg: { config: { token: 'private-secret' } } } };
            },
        },
        {},
    );
    await assert.rejects(
        failure.dispatch({ route: '/kugou/search', cookies: { __kugou: { dfid: 'registered' } } }),
        (error) => !JSON.stringify(error.body).includes('private-secret'),
    );

    assert(ROUTES.includes('/lyric') && ROUTES.includes('/search/lyric'));
    const bridge = createBridge({}, {});
    for (const route of ['/mv/detail', '/comment/music', '/user/cloud', '/song/url/new']) {
        assert.equal(ROUTES.includes(route), false);
        await assert.rejects(bridge.dispatch({ route: '/kugou' + route }));
    }
});

test('歌曲条目归一化并拒绝无效标识', () => {
    const parsed = kugouItem(song);
    assert.equal(parsed.id, hash);
    assert.equal(parsed.albumAudioID, '456');
    assert.equal(parsed.duration, 180000);

    const albumTrack = kugouItem({
        base: { audio_name: '曲目', album_id: 123, album_audio_id: 456 },
        audio_info: { hash, duration: 180000 },
    });
    assert.equal(albumTrack.albumID, '123');
    assert.equal(albumTrack.id, hash);
    assert.equal(kugouItem({ hash: '456', name: '无效 ID' }), null);
});

test('搜索、歌单与喜欢列表按平台分页读取', async () => {
    const harness = createClientHarness({
        responses: {
            '/kugou/search': { data: { total: 61, lists: [song] } },
            '/kugou/user/playlist': {
                data: {
                    total: 2,
                    info: [
                        { global_collection_id: 'own-list', listid: 1, type: '0', name: '我喜欢', is_def: 0 },
                        { global_collection_id: 'saved-list', listid: 2, type: 1, name: '收藏' },
                    ],
                },
            },
            '/kugou/playlist/track/all/new': { data: { count: 1, songs: [song] } },
        },
    });
    const client = new KugouAPI(harness.api);

    const search = await client.search('曲目', 'song', 30);
    assert.equal(search.more, true);
    assert.deepEqual(harness.lastCall('/kugou/search').params, {
        keywords: '曲目',
        type: 'song',
        page: 2,
        pagesize: 30,
    });

    const playlists = await client.userPlaylists('42');
    assert.equal(playlists.items[0].creatorID, '42');
    assert.equal(playlists.items[1].creatorID, '');

    const favorites = await client.likedSongs();
    assert.equal(favorites.items[0].id, hash);
    assert.equal(harness.lastCall('/kugou/playlist/track/all/new').params.listid, '1');
    assert.equal(harness.lastCall('/kugou/playlist/track/all/new').params.type, 0);

    // 资料库入口排在列表首位也不能替代真正的“我喜欢”歌单。
    client.playlists.unshift({
        title: '音乐资料库',
        owned: true,
        isDefault: true,
        id: 'library',
        listid: '99',
    });
    await client.likedSongs();
    assert.equal(harness.lastCall('/kugou/playlist/track/all/new').params.listid, '1');
});

test('音源不可用时回退标准音质并保留实际码率', async () => {
    const harness = createClientHarness({
        responses: {
            '/kugou/song/url': (params) => ({
                url: params.quality === '128' ? ['https://fs.kugou.com/test.mp3'] : [],
                bitRate: 128000,
                extName: 'mp3',
                sampleRate: 44100,
                bitDepth: 16,
            }),
        },
    });
    const client = new KugouAPI(harness.api);

    const track = await client.playback(kugouItem(song), 'lossless', false, () => true);
    assert.equal(track.qualityFallback, '标准');
    assert.equal(track.br, 128000);
    assert.equal(track.extName, 'mp3');
    assert.equal(track.sampleRate, 44100);
    assert.equal(track.bitDepth, 16);
    assert.equal(harness.lastCall('/kugou/song/url').params.album_audio_id, '456');
});

test('歌单详情按 100 条分页读取全部曲目', async () => {
    const pages = [];
    const harness = createClientHarness({
        responses: {
            '/kugou/playlist/track/all': (params) => {
                pages.push(params.page);
                const first = Array.from({ length: 100 }, () => ({}));
                first[99] = song;
                return {
                    data: {
                        total: 101,
                        songs: params.page === 1 ? first : [{ ...song, hash: 'B'.repeat(32) }],
                    },
                };
            },
        },
    });
    const client = new KugouAPI(harness.api);

    const [, tracks] = await client.detail({ kind: 'playlist', id: 'example-list' });
    assert.deepEqual(pages, [1, 2]);
    assert.equal(tracks.length, 2);
});

test('歌手与专辑详情补齐封面、简介与全部曲目', async () => {
    const detailCalls = [];
    const harness = createClientHarness({
        responses: {
            '/kugou/artist/detail': {
                data: {
                    author_id: 789658,
                    author_name: 'HOYO-MiX',
                    intro: '音乐团队',
                    sizable_avatar: 'http://singerimg.kugou.com/{size}/artist.jpg',
                },
            },
            '/kugou/artist/audios': (params) => {
                assert.equal(params.sort, 'hot');
                return {
                    total: 1,
                    data: [
                        {
                            hash,
                            audio_name: '曲目',
                            author_name: 'HOYO-MiX',
                            album_id: 123,
                            album_name: '专辑',
                            timelength: 180000,
                        },
                    ],
                };
            },
            '/kugou/artist/albums': { total: 1, data: [{ album_id: 123, album_name: '专辑' }] },
            '/kugou/album/detail': {
                data: [
                    {
                        album_id: 123,
                        album_name: '专辑',
                        intro: '专辑简介',
                        cover: 'album.jpg',
                        sizable_cover: 'http://imge.kugou.com/{size}/album.jpg',
                    },
                ],
            },
            '/kugou/album/songs': (params) => {
                assert.equal(params.pagesize, 30);
                detailCalls.push(['/kugou/album/songs', params]);
                return {
                    data: {
                        total: 31,
                        songs: params.page === 1 ? Array.from({ length: 30 }, () => song) : [song],
                    },
                };
            },
            '/kugou/privilege/lite': {
                data: [
                    {
                        hash,
                        name: '曲目',
                        album_id: '0',
                        recommend_album_id: '123',
                        albumname: '专辑',
                        info: { duration: 242000 },
                    },
                ],
            },
        },
    });
    const client = new KugouAPI(harness.api);

    const [artist, artistSongs] = await client.detail({ kind: 'artist', id: '789658' });
    assert.equal(artist.description, '音乐团队');
    assert.match(artist.cover, /480\/artist.jpg$/);
    assert.equal(artistSongs[0].title, '曲目');
    assert.equal(artistSongs[0].album, '专辑');
    assert.equal(artistSongs[0].duration, 180000);
    assert.equal((await client.artistAlbums('789658')).items[0].id, '123');

    const [album, albumSongs] = await client.detail({ kind: 'album', id: '123' });
    assert.equal(album.description, '专辑简介');
    assert.match(album.cover, /^https:\/\//);
    assert.equal(albumSongs.length, 31);
    assert.deepEqual(
        detailCalls.filter(([route]) => route.endsWith('/album/songs')).map(([, params]) => params.page),
        [1, 2],
    );

    // 搜索结果缺时长和专辑信息时，读取权益资料补齐。
    const [hydrated] = await client.detail({
        ...kugouItem(song),
        duration: 0,
        artists: [{ id: '789658', name: 'HOYO-MiX' }],
    });
    assert.equal(hydrated.albumID, '123');
    assert.equal(hydrated.duration, 242000);
    assert.equal(hydrated.artists[0].id, '789658');
});

test('歌词逐词时标与网易云逐词结构一致', () => {
    const krc = format.normalizeLyrics('kugou', {
        decodeContent: '[1000,2000]<0,500,0>第一<500,1500,0>句\n[4000,1000]<0,1000,0>第二句',
    }).document;
    const yrc = format.normalizeLyrics('netease', {
        yrc: { lyric: '[1000,2000](1000,500,0)第一(1500,1500,0)句\n[4000,1000](4000,1000,0)第二句' },
    }).document;
    assert.deepEqual(
        krc.lines.map((line) => line.words),
        yrc.lines.map((line) => line.words),
    );
});

test('标准版与概念版使用独立版本配置且重启复用设备', async () => {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-kugou-edition-'));
    const request = (edition) => {
        const { bridge, runtime } = bridgeRuntime(bridgeDirectory);
        const child = spawn(runtime, ['--require', hook, path.join(bridge, 'worker.cjs')], {
            cwd: bridge,
            env: {
                ...process.env,
                TMPDIR: temporary,
                RHINE_TEST_BRIDGE: bridge,
                RHINE_KUGOU_EDITION: edition,
                RHINE_KUGOU_DEVICE_STATE_PATH: path.join(temporary, 'device.json'),
            },
            stdio: ['pipe', 'pipe', 'pipe'],
        });
        return new Promise((resolve, reject) => {
            let buffer = '';
            const timer = setTimeout(() => reject(new Error('酷狗打包进程超时：' + edition)), 30000);
            child.on('error', reject);
            child.stdout.on('data', (chunk) => {
                buffer += chunk;
                if (buffer.includes('\n')) {
                    clearTimeout(timer);
                    resolve(JSON.parse(buffer.split('\n')[0]));
                }
            });
            child.stdin.write(JSON.stringify({ id: 'edition', route: '/kugou/login/qr/key' }) + '\n');
        }).finally(async () => {
            child.stdin.end();
            await new Promise((resolve) => child.once('exit', resolve));
        });
    };
    try {
        const standard = await request('standard');
        const lite = await request('lite');
        const restart = await request('lite');
        assert.equal(standard.body.code, 200);
        assert.equal(standard.kugouCredentials.KUGOU_API_PLATFORM, 'standard');
        assert.equal(lite.kugouCredentials.KUGOU_API_PLATFORM, 'lite');
        assert.equal(standard.kugouCredentials.KUGOU_API_GUID, lite.kugouCredentials.KUGOU_API_GUID);
        assert.equal(lite.kugouCredentials.KUGOU_API_GUID, restart.kugouCredentials.KUGOU_API_GUID);
        assert.equal(lite.kugouCredentials.KUGOU_API_DEV, restart.kugouCredentials.KUGOU_API_DEV);
        assert.equal(lite.kugouCredentials.KUGOU_API_WEBGL, restart.kugouCredentials.KUGOU_API_WEBGL);
        assert.equal(JSON.parse(fs.readFileSync(path.join(temporary, 'device.json'))).token, undefined);
    } finally {
        fs.rmSync(temporary, { recursive: true, force: true });
    }
});

test('原生调度拦截未登录搜索并透传已登录 Cookie', async () => {
    let kugouRequests = 0;
    const anonymous = await dispatch(message('search', ['本地', 'song', 0]), async () => {
        kugouRequests++;
        return {};
    });
    assert.equal(anonymous.body.code, 503);
    assert.match(anonymous.body.message, /需要登录/);
    assert.equal(kugouRequests, 0);

    const authenticated = await dispatch(
        message('search', ['本地', 'song', 0], { __kugou: { token: 'fixture-token' } }),
        async (request) => {
            assert.equal(request.route, '/kugou/search');
            assert.equal(request.cookies.__kugou.token, 'fixture-token');
            return { body: { code: 200, data: { lists: [], total: 0 } } };
        },
    );
    assert.equal(authenticated.body.code, 200);
    assert.equal(authenticated.body.value.total, 0);
});
