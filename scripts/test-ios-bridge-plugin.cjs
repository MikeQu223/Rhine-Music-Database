const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const plugin = require('./mobile-bridge-plugin.cjs')();

test('iOS MV 标题正则不依赖 ICU，并正确处理常见分隔符', () => {
    const source = path.resolve('MusicBridge/client/netease.mjs');
    let transformed;
    plugin.setup({
        onLoad(options, load) {
            if (options.filter.test(source)) {
                transformed = load({ path: source }).contents;
            }
        },
        onEnd() {},
    });
    assert.equal(typeof transformed, 'string');
    assert.equal(transformed.includes('\\p{'), false);
    const pattern = transformed.match(/\.replace\((\/\[.*\]\/gu), ''\)/);
    assert(pattern, '必须保留标题分隔符替换');
    const expanded = new RegExp(pattern[1].slice(1, -3), 'u');
    const original = /[\s\p{P}\p{S}]/u;
    // 只覆盖实际标题中的常见字符，避免穷举全部 Unicode 码点。
    for (const character of [' ', '\t', '-', '（', '）', '。', '·', '＋', '🎵', 'A', '中', 'é']) {
        assert.equal(expanded.test(character), original.test(character), character);
    }
});

test('iOS 插件在 Windows 和 POSIX 路径下都能匹配目标模块', () => {
    const filters = [];
    plugin.setup({
        onLoad(options) {
            filters.push(options.filter);
        },
        onEnd() {},
    });
    for (const relativePath of [
        'MusicBridge/client/netease.mjs',
        'MusicBridge/worker.cjs',
        'node_modules/@neteasecloudmusicapienhanced/api/util/crypto.js',
    ]) {
        for (const source of [`/repo/${relativePath}`, `C:\\repo\\${relativePath.replaceAll('/', '\\')}`]) {
            assert.equal(filters.filter((filter) => filter.test(source)).length, 1, source);
        }
    }
    assert.equal(
        filters.some((filter) => filter.test('/repo/MusicBridge/client/qq.mjs')),
        false,
    );
});
