const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const root = path.resolve('MusicBridge');
const source = require(path.join(root, 'upstream/source.json'));
for (const [name, hash] of Object.entries(source.files)) {
    assert.equal(
        crypto
            .createHash('sha256')
            .update(fs.readFileSync(path.join(root, 'upstream', name)))
            .digest('hex'),
        hash,
        `${name} must remain upstream-identical`,
    );
}
const lock = require(path.join(root, 'package-lock.json'));
const pkg = lock.packages['node_modules/@neteasecloudmusicapienhanced/api'];
assert.equal(pkg.version, '4.41.1');
assert.equal(pkg.integrity, source.apiIntegrity);
const qq = lock.packages['node_modules/@yakult-green-tea/qq-music-api'];
assert.equal(qq.version, '3.3.5');
assert.equal(qq.integrity, source.qqIntegrity);
const kugou = lock.packages['node_modules/kugoumusicapi'];
assert.equal(kugou.version, source.kugouVersion);
assert.equal(kugou.integrity, source.kugouIntegrity);
assert.equal(kugou.resolved, 'https://codeload.github.com/MakcRe/KuGouMusicApi/tar.gz/' + source.kugouCommit);
// 状态编排和拆分后的请求层都不得复制原生协议实现。
const api = ['Qt/src/MusicApi.cpp', 'MusicBridge/client/netease.mjs']
    .map((file) => fs.readFileSync(file, 'utf8'))
    .join('\n');
assert(!/CommonCrypto|function\s+(?:aes|weapi|eapi)|RhineMusicNative/.test(api));
console.log(
    'Upstream auth/user source hashes, Enhanced and QQ locked API integrity and removal of native protocol copy passed',
);
