// 发布包测试使用本地 HTTP 响应，保持真实上游协议模块参与执行。
const originalFetch = global.fetch;
// 新的共用 QQ 接口使用 Fetch；本地桥接 HTTP 仍走真实回环服务。
global.fetch = async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (url.hostname === 'monster-siren.hypergryph.com') {
        const songs = [{ cid: '048755', name: '本地歌曲', albumCid: '6648', artists: ['塞壬唱片-MSR'] }];
        const albums = [
            {
                cid: '6648',
                name: '本地专辑',
                coverUrl: 'https://web.hycdn.cn/siren/pic/20260101/cover.jpg',
                artistes: ['塞壬唱片-MSR'],
            },
        ];
        const song = {
            cid: '048755',
            name: '本地歌曲',
            albumCid: '6648',
            sourceUrl: 'https://res01.hycdn.cn/test.wav',
            lyricUrl: null,
            mvUrl: null,
            mvCoverUrl: null,
            artists: ['塞壬唱片-MSR'],
        };
        let data;
        if (url.pathname === '/api/songs') {
            data = { list: songs };
        } else if (url.pathname === '/api/albums') {
            data = albums;
        } else if (url.pathname.startsWith('/api/song/')) {
            data = song;
        } else if (url.pathname.startsWith('/api/album/')) {
            data = {
                ...albums[0],
                songs: [{ cid: '048755', name: '本地歌曲', artistes: ['塞壬唱片-MSR'] }],
            };
        } else {
            throw new Error('Unexpected Monster Siren fixture path: ' + url.pathname);
        }
        return Response.json({ code: 0, msg: '', data });
    }
    if (url.hostname !== 'u.y.qq.com') {
        return originalFetch(input, init);
    }
    const raw =
        request.method === 'POST' ? await request.text() : new URL(request.url).searchParams.get('data');
    const payload = JSON.parse(raw || '{}');
    const response = { code: 0 };
    for (const [key, rpc] of Object.entries(payload)) {
        if (!rpc?.method) {
            continue;
        }
        if (rpc.method === 'DoSearchForQQMusicLite') {
            const keys = { 0: 'item_song', 1: 'singer', 2: 'item_album', 3: 'item_songlist' };
            const type = rpc.param.search_type;
            const entries = {
                0: {
                    mid: 'fixtureMID',
                    id: 42,
                    type: 0,
                    name: 'QQ fixture',
                    singer: [],
                    album: { mid: 'albumMID' },
                },
                1: { singerMID: 'singerMID', singerName: 'QQ fixture artist' },
                2: { albummid: 'albumMID', name: 'QQ fixture album' },
                3: { dissid: '70001', dissname: 'QQ fixture playlist' },
            };
            response[key] = {
                code: 0,
                data: {
                    meta: { sum: 1, curpage: 1, nextpage: -1, ret: 0 },
                    body: { [keys[type]]: [entries[type]] },
                },
            };
        } else if (rpc.module === 'musicToplist.ToplistInfoServer' && rpc.method === 'GetAll') {
            response[key] = {
                code: 0,
                data: {
                    group: [
                        {
                            groupId: 1,
                            groupName: '总榜',
                            toplist: [
                                {
                                    topId: 4,
                                    title: 'Fixture chart',
                                    period: '2026-10-12',
                                    totalNum: 1,
                                },
                            ],
                        },
                    ],
                },
            };
        } else if (rpc.module === 'musicToplist.ToplistInfoServer' && rpc.method === 'GetDetail') {
            if (rpc.param.period !== '2026-10-12') {
                throw new Error('Chart period changed');
            }
            response[key] = {
                code: 0,
                data: {
                    data: { topId: 4, title: 'Fixture chart', period: '2026-10-12', totalNum: 1 },
                    songInfoList: [{ mid: 'fixtureMID', name: 'QQ fixture' }],
                },
            };
        } else if (rpc.module === 'newalbum.NewAlbumServer' && rpc.method === 'get_new_album_area') {
            response[key] = { code: 0, data: { area: [{ id: 1, name: '内地' }] } };
        } else if (rpc.module === 'newalbum.NewAlbumServer' && rpc.method === 'get_new_album_info') {
            response[key] = {
                code: 0,
                data: {
                    albums: [
                        {
                            mid: 'albumMID',
                            name: 'QQ fixture album',
                            singers: [{ mid: 'singerMID', name: 'QQ fixture artist' }],
                        },
                    ],
                    total: 1,
                },
            };
        } else {
            throw new Error('Unexpected QQ Fetch operation: ' + rpc.method);
        }
    }
    return Response.json(response);
};
// 发布包不再携带 node_modules，由打包后的 worker 把上游模块实例交进来。
let axios;
let upstreamCrypto;
let kugouConfig;
globalThis.__rhineBridgeTestSetup = (internals) => {
    axios = internals.axios;
    upstreamCrypto = internals.upstreamCrypto;
    kugouConfig = internals.kugouConfig;
    const originalXeapi = upstreamCrypto.xeapi;
    upstreamCrypto.xeapi = (uri, payload, options) => {
        const encrypted = originalXeapi(uri, payload, options);
        xeapiRequests.set(encrypted.C, { payload, version: options.publicKeyState.version });
        return encrypted;
    };
    axios.defaults.adapter = fixtureAdapter;
};
// 本地响应使用测试密钥加密；请求仍经过上游注册校验、加密和响应解密。
const crypto = require('node:crypto');
const keyPair = crypto.generateKeyPairSync('x25519');
const publicKey = keyPair.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
let keyRegistrations = 0;
const xeapiRequests = new Map();
function encryptFixture(value, key) {
    const cipher = crypto.createCipheriv(`aes-${key.length * 8}-ecb`, key, null);
    return Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
}
async function fixtureAdapter(settings) {
    const destination = (settings.baseURL || '') + settings.url;
    // 替代音源模块在打包后从 require 缓存加载，这里验证它仍能完成真实请求。
    if (/api\.byfuns\.top/.test(destination)) {
        return {
            status: 302,
            data: '',
            headers: { location: 'https://example.test/unblock.flac' },
            config: settings,
        };
    }
    if (/\.kugou\.com/.test(destination)) {
        if (destination.endsWith('/v1/search')) {
            return {
                status: 200,
                data: { status: 200, candidates: [{ id: '42', accesskey: 'fixture-key' }] },
                headers: {},
                config: settings,
            };
        }
        if (destination.endsWith('/download')) {
            const content = '[1000,1000]<0,500,0>本地<500,500,0>歌词\n[3000,1000]<0,1000,0>第二句';
            const bytes = require('node:zlib').deflateSync(Buffer.from(content));
            const key = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105];
            for (let i = 0; i < bytes.length; i++) {
                bytes[i] ^= key[i % key.length];
            }
            return {
                status: 200,
                data: {
                    status: 200,
                    contenttype: 0,
                    content: Buffer.concat([Buffer.from('krc1'), bytes]).toString('base64'),
                },
                headers: {},
                config: settings,
            };
        }
        // 保留酷狗原包的签名和 Cookie 注入，只提供本地 HTTP 响应。
        if (!settings.params?.mid || !settings.params?.signature) {
            throw new Error('Kugou upstream device or signature missing');
        }
        let data = { status: 1, data: { info: [{ rankid: 1, rankname: '本地榜单' }] } };
        if (destination.endsWith('/v2/qrcode')) {
            const appid =
                process.env.RHINE_KUGOU_EDITION === 'lite' ? kugouConfig.liteAppid : kugouConfig.appid;
            if (!settings.params.qrcode_txt.includes('appid=' + appid + '&')) {
                throw new Error('Kugou QR used the wrong edition appid');
            }
            data = { status: 1, data: { qrcode: 'fixture-kugou-qr' } };
        } else if (destination.endsWith('/v2/get_userinfo_qrcode')) {
            data = { status: 1, data: { status: 4, token: 'fixture-kugou-token', userid: 42 } };
        } else if (destination.endsWith('/v2/search/song')) {
            if (settings.params.token !== 'fixture-kugou-token' || settings.params.dfid !== 'fixture-dfid') {
                throw new Error('Kugou credentials or registered device missing');
            }
            data = {
                status: 1,
                data: { lists: [{ FileHash: 'A'.repeat(32), SongName: '本地歌曲' }], total: 1 },
            };
        }
        return { status: 200, data, headers: {}, config: settings };
    }
    if (!/music\.163\.com|y\.qq\.com/.test(destination)) {
        throw new Error('Unexpected upstream');
    }
    const qq = destination.includes('qq.com');
    if (qq && process.env.QQ_AUTH_STATE_PATH !== process.env.RHINE_QQ_DEVICE_STATE_PATH) {
        throw new Error('QQ bridge discarded persistent device path');
    }
    let data = qq
        ? {
              code: 0,
              data: {
                  song: {
                      list: [
                          {
                              mid: 'fixtureMID',
                              name: 'QQ fixture',
                              singer: [],
                              album: {
                                  mid: 'albumMID',
                              },
                          },
                      ],
                      totalnum: 1,
                  },
                  topList: [
                      {
                          id: 4,
                          topTitle: 'Fixture chart',
                      },
                  ],
              },
          }
        : {
              code: 200,
              result: {
                  songs: [],
                  songCount: 0,
              },
              data: [
                  {
                      id: 1,
                      url: 'https://music.126.net/fixture',
                  },
              ],
          };
    if (destination.includes('/song/lyric/v1')) {
        data = { code: 200, lrc: { lyric: '[00:01.00]本地歌词\n[00:03.00]第二句' } };
    }
    if (destination.includes('fcg_query_lyric_new.fcg')) {
        data = { code: 0, lyric: Buffer.from('[00:01.00]本地歌词\n[00:03.00]第二句').toString('base64') };
    }
    if (destination.endsWith('/api/bsr/sk/get')) {
        keyRegistrations++;
        // 留出并发窗口，验证同一桥接只发起一次注册。
        await new Promise((resolve) => setTimeout(resolve, 15));
        const payload = new URLSearchParams(settings.data);
        if (
            !payload.get('deviceId') ||
            payload.get('signature') !==
                upstreamCrypto.xeapiSign(payload.get('timestamp'), payload.get('nonce'))
        ) {
            throw new Error('XEAPI registration must retain upstream device and signature');
        }
        const timestamp = String(Date.now());
        let nextUpdateTime = Date.now() + 3600000;
        if (process.env.RHINE_TEST_XEAPI_EXPIRE_FIRST === '1' && keyRegistrations === 1) {
            nextUpdateTime = Date.now() - 1;
        }
        const encryptedData = encryptFixture(
            { publicKey, version: String(keyRegistrations), sk: 'fixture-sk', nextUpdateTime },
            Buffer.from('ab1d5a430f6bb04a3f01e81ddd72bd916d5ce591248ac128714806d7f8fb1b84', 'hex'),
        ).toString('base64');
        const shouldFail = process.env.RHINE_TEST_XEAPI_FAIL_FIRST === '1' && keyRegistrations === 1;
        data = {
            code: 200,
            data: {
                encryptedData,
                timestamp,
                signature: shouldFail ? 'invalid' : upstreamCrypto.xeapiSign(timestamp, payload.get('nonce')),
            },
        };
    } else if (destination.split('?')[0].endsWith('/xeapi/song/enhance/player/url/v1')) {
        const encrypted = new URLSearchParams(settings.data);
        const request = xeapiRequests.get(encrypted.get('C'));
        xeapiRequests.delete(encrypted.get('C'));
        if (!request || !settings.headers['x-deviceid']) {
            throw new Error('Expected genuine upstream XEAPI request');
        }
        data = {
            code: 200,
            data: [
                {
                    id: 1,
                    url: 'https://music.126.net/fixture.flac',
                    type: 'flac',
                    level: request.payload.level,
                    authenticated: settings.headers['x-music-u'] === 'fixture-account',
                    keyRegistrations,
                    keyVersion: request.version,
                },
            ],
        };
        if (String(JSON.parse(request.payload.ids)[0]) === '2') {
            data = { code: 403, message: 'fixture permission denied' };
        }
        data = encryptFixture(data, Buffer.from('e82ckenh8dichen8'));
    } else if (destination.includes('/song/enhance/player/url')) {
        throw new Error('Quality requests must not silently fall back to the legacy bitrate endpoint');
    }
    return {
        status: 200,
        data,
        headers: {},
        config: settings,
    };
}
