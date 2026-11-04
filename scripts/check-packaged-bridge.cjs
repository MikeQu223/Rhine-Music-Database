// 发布包内执行真实协议模块，只替换上游 HTTP 响应；不访问实际音乐 API。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { bridgeRuntime, bridgeSourceDirectory } = require('../Qt/tests/fixtures/bridge-runtime.cjs');
const { bridge, runtime } = bridgeRuntime();
const temp = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'rhine-package-check-'));
const hook = path.resolve(__dirname, '../Qt/tests/fixtures/bridge-http.cjs');

const deviceContext = require(
    path.join(
        bridgeSourceDirectory(),
        'node_modules/@yakult-green-tea/qq-music-api/dist/src/services/auth/deviceContext.js',
    ),
);
async function main() {
    let child;
    try {
        child = spawn(runtime, ['--require', hook, path.join(bridge, 'worker.cjs')], {
            cwd: bridge,
            env: {
                ...process.env,
                TMPDIR: temp,
                TEMP: temp,
                LANG: 'en_US.UTF-8',
                RHINE_TEST_BRIDGE: bridge,
                RHINE_QQ_DEVICE_STATE_PATH: path.join(temp, 'qq-device.json'),
                RHINE_KUGOU_DEVICE_STATE_PATH: path.join(temp, 'kugou-device.json'),
            },
            stdio: ['pipe', 'pipe', 'pipe'],
        });
        let errors = '';
        let buffer = '';
        const pending = new Map();
        child.stderr.on('data', (d) => (errors += d));
        child.stdout.on('data', (data) => {
            buffer += data;
            let end;
            while ((end = buffer.indexOf('\n')) >= 0) {
                const line = buffer.slice(0, end);
                buffer = buffer.slice(end + 1);
                let result;
                try {
                    result = JSON.parse(line);
                } catch (error) {
                    for (const p of pending.values()) {
                        p.reject(error);
                    }
                    return;
                }
                const p = pending.get(result.id);
                if (p) {
                    clearTimeout(p.timer);
                    pending.delete(result.id);
                    p.resolve(result);
                }
            }
        });
        function request(id, route, params = {}, cookies = {}) {
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    pending.delete(id);
                    reject(new Error('IPC timeout (' + id + '): ' + errors));
                }, 15000);
                pending.set(id, {
                    resolve,
                    reject,
                    timer,
                });
                child.stdin.write(
                    JSON.stringify({
                        id,
                        route,
                        params,
                        cookies,
                    }) + '\n',
                );
            });
        }
        const search = await request('search', '/search', {
            keywords: 'fixture',
            type: 1,
        });
        assert.equal(search.body.code, 200);
        const nativeSearch = await request('native-search', '/native/netease/search', {
            args: ['fixture', 'song', 0],
        });
        assert.equal(nativeSearch.body.code, 200);
        assert.deepEqual(nativeSearch.body.value.items, []);
        assert.equal(nativeSearch.body.value.total, 0);
        const nativeMv = await request('native-mv', '/native/netease/mv', { args: [{ id: '1' }] });
        assert.equal(nativeMv.body.code, 200);
        assert.equal(nativeMv.body.value.id, '99');
        assert.equal(nativeMv.body.value.resolution, 1080);
        assert.equal(nativeMv.body.value.url, 'https://video.example.test/fixture.mp4');
        const versions = await request('native-mv-versions', '/native/netease/mvVersions', {
            args: [{ id: '1' }],
        });
        assert.equal(versions.body.code, 200);
        assert.equal(versions.body.value.versions[0].id, '99');
        assert.equal(versions.body.value.versions[0].associated, true);
        const selectedMv = await request('native-mv-selected', '/native/netease/mv', {
            args: [{ id: '1', videoID: '100' }],
        });
        assert.equal(selectedMv.body.code, 200);
        assert.equal(selectedMv.body.value.id, '100');
        // 塞壬唱片使用独立 fetch 目录
        const sirenSearch = await request('native-siren', '/native/siren/search', {
            args: ['', 'album', 0],
        });
        assert.equal(sirenSearch.body.code, 200, JSON.stringify(sirenSearch.body));
        assert.equal(sirenSearch.body.value.items[0].title, '本地专辑');
        const audio = await request('audio', '/song/url/v1', {
            id: '1',
            level: 'lossless',
            unblock: false,
        });
        assert.equal(audio.body.code, 200);
        assert(audio.body.data[0].url);
        const standard = await request('standard', '/song/url/v1', {
            id: '1',
            level: 'standard',
            unblock: false,
        });
        assert.equal(standard.body.code, 200);
        assert(standard.body.data[0].url);
        assert.equal(audio.body.data[0].level, 'lossless');
        assert.equal(audio.body.data[0].keyRegistrations, 1);
        assert.equal(standard.body.data[0].level, 'standard');
        const authenticated = await request(
            'authenticated',
            '/song/url/v1',
            {
                id: '1',
                level: 'exhigh',
                unblock: false,
            },
            {
                MUSIC_U: 'fixture-account',
            },
        );
        assert.equal(authenticated.body.data[0].authenticated, true);
        assert.equal(authenticated.body.data[0].level, 'exhigh');
        const master = await request('master', '/song/url/v1', { id: '1', level: 'jymaster' });
        assert.equal(master.body.data[0].level, 'jymaster');
        assert.equal(master.body.data[0].keyRegistrations, 1);
        const denied = await request('denied', '/song/url/v1', {
            id: '2',
            level: 'standard',
            unblock: false,
        });
        assert.equal(denied.body.code, 403);
        // 替代音源模块按目录动态加载，验证单文件包仍能走到真实模块。
        const unblocked = await request('unblock', '/song/url/v1', {
            id: '1',
            level: 'standard',
            unblock: true,
        });
        assert.equal(unblocked.body.code, 200, JSON.stringify(unblocked.body));
        assert.equal(unblocked.body.data[0].url, 'https://example.test/unblock.flac');
        const savedDevice = deviceContext.createAndroidDevice();
        const qq = await request(
            'qq',
            '/qq/search',
            { keyword: 'fixture', type: 'song', page: 1, limit: 20 },
            {
                qqmusic_session: 'fixture-session',
                __qqSessions: [
                    null,
                    {
                        token: 'fixture-session',
                        credential: { musicid: '42', musickey: 'fixture-key', loginType: 6 },
                        device: savedDevice,
                        expiresAt: Date.now() + 72 * 3600000,
                    },
                ],
            },
        );
        assert.equal(qq.body.code, 200, JSON.stringify(qq.body));
        assert.equal(qq.body.items[0].mid, 'fixtureMID');
        for (const [type, field, id] of [
            ['album', 'albummid', 'albumMID'],
            ['playlist', 'dissid', '70001'],
            ['singer', 'singerMID', 'singerMID'],
        ]) {
            const result = await request('qq-search-' + type, '/qq/search', { keyword: 'fixture', type });
            assert.equal(result.body.items[0][field], id);
        }
        const features = await request('qq-capabilities', '/qq/login/channels');
        assert.equal(features.body.data.features.mutations.likeSong, true);
        assert.equal(features.body.data.features.mutations.subscribeAlbum, true);
        // 缺少必填正文应由 POST 的 schema 拒绝，而不是被错误地作为 GET 返回 405。
        const invalidWrite = await request(
            'qq-post',
            '/qq/user/song/like',
            { song: {} },
            { qqmusic_session: 'fixture-session' },
        );
        assert.equal(invalidWrite.body.code, 400);
        const deviceRecord = JSON.parse(fs.readFileSync(path.join(temp, 'qq-device.json')));
        assert.deepEqual(deviceRecord.device, savedDevice);
        assert.equal(deviceRecord.device.musickey, undefined);
        const charts = await request('charts', '/qq/recommend/toplists');
        assert.equal(charts.body.groups[0].toplists[0].id, 4);
        const chart = await request('chart', '/qq/recommend/toplist', {
            id: 4,
            period: charts.body.groups[0].toplists[0].period,
            limit: 100,
            offset: 0,
        });
        assert.equal(chart.body.songs[0].mid, 'fixtureMID');
        const kugouKey = await request('kugou-key', '/kugou/login/qr/key');
        assert.equal(kugouKey.body.data.unikey, 'fixture-kugou-qr');
        const kugouImage = await request('kugou-image', '/kugou/login/qr/create', {
            key: kugouKey.body.data.unikey,
            qrimg: true,
            timestamp: Date.now(),
        });
        assert.match(kugouImage.body.data.qrimg, /^data:image\/png;base64,/);
        const kugouLogin = await request('kugou-login', '/kugou/login/qr/check', {
            key: kugouKey.body.data.unikey,
        });
        assert.equal(kugouLogin.body.code, 803);
        assert.equal(kugouLogin.kugouCredentials.token, 'fixture-kugou-token');
        assert.equal(JSON.stringify(kugouLogin.body).includes('fixture-kugou-token'), false);
        const kugouSearch = await request(
            'kugou-search',
            '/kugou/search',
            { keywords: '本地歌曲', type: 'song' },
            {
                __kugou: { ...kugouLogin.kugouCredentials, dfid: 'fixture-dfid' },
            },
        );
        assert.equal(kugouSearch.body.data.lists[0].SongName, '本地歌曲');
        const kugouDevice = JSON.parse(fs.readFileSync(path.join(temp, 'kugou-device.json')));
        assert.equal(kugouDevice.KUGOU_API_GUID, kugouLogin.kugouCredentials.KUGOU_API_GUID);
        assert.equal(kugouDevice.token, undefined);
        // 发布包通过真实锁定协议和解码器读取三种形态，再交付相同毫秒模型。
        const neteaseLyrics = await request('lyrics-netease', '/lyric/new', { id: '1' });
        const qqLyrics = await request('lyrics-qq', '/qq/getLyric', { songmid: 'fixtureMID' });
        const lyricSearch = await request('lyrics-kugou-search', '/kugou/search/lyric', {
            hash: 'A'.repeat(32),
        });
        assert.equal(lyricSearch.body.candidates[0].id, '42');
        const kugouLyrics = await request('lyrics-kugou', '/kugou/lyric', {
            id: '42',
            accesskey: 'fixture-key',
            fmt: 'krc',
            decode: true,
        });
        for (const response of [neteaseLyrics, qqLyrics, kugouLyrics]) {
            assert.equal(response.body.code, 200);
            assert.deepEqual(
                response.body.document.lines.map((line) => line.startMs),
                [1000, 3000],
            );
            assert.equal(response.body.document.lines[0].text, '本地歌词');
        }
        assert.equal(kugouLyrics.body.document.timing, 'word');
        assert.equal(kugouLyrics.body.document.lines[0].words[1].startMs, 1500);
        assert(fs.existsSync(path.join(bridge, 'LyricsKit-LICENSE')));
        // 验证原服务失败诊断
        const failedLogin = await request('failed-login', '/qq/login/qr/key', { channel: 'qq' });
        assert.equal(failedLogin.body.code, 502);
        assert.equal(failedLogin.body.failureStage, 'device-bootstrap');
        assert(failedLogin.body.retryAfterMs > 0);
        const backedOff = await request('backed-off-login', '/qq/login/qr/key', { channel: 'qq' });
        assert.equal(backedOff.body.code, 429);
        assert.equal(backedOff.body.failureReason, 'local-backoff');
        assert.equal(backedOff.body.lastFailure.failureStage, 'device-bootstrap');
        for (const route of [
            '/cloud',
            '/mv/download',
            '/personal_fm',
            '/qq/getComments',
            '/kugou/user/cloud',
            '/kugou/song/url/new',
        ]) {
            const rejected = await request(route, route);
            assert.equal(rejected.body.code, 503);
        }
        child.stdin.end();
        const exit = await new Promise((resolve) => {
            child.once('exit', (code, signal) => resolve({ code, signal }));
        });
        assert.equal(exit.code, 0, 'packaged bridge must finish cleanly after stdin closes');
        assert.equal(exit.signal, null);
        assert.equal(errors, '');
        console.log(
            'Packaged NetEase Enhanced and QQ IPC, real dependency loading, local responses and core route allowlists passed',
        );
    } finally {
        if (child && child.exitCode === null) {
            child.kill();
        }
        fs.rmSync(temp, {
            recursive: true,
            force: true,
        });
    }
}
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
