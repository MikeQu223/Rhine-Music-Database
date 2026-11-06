const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const plugin = require('./ios-bridge-plugin.cjs');

test('iOS MV 标题正则不依赖 ICU，并保留全部 Unicode 标点与符号类别', () => {
    const source = path.resolve('MusicBridge/client/netease.mjs');
    let transformed;
    plugin.setup({
        onLoad(options, load) {
            if (options.filter.test(source)) {
                transformed = load({ path: source }).contents;
            }
        },
    });
    assert.equal(typeof transformed, 'string');
    assert.equal(transformed.includes('\\p{'), false);
    const pattern = transformed.match(/\.replace\((\/\[.*\]\/gu), ''\)/);
    assert(pattern, '必须保留标题分隔符替换');
    const expanded = new RegExp(pattern[1].slice(1, -3), 'u');
    const original = /[\s\p{P}\p{S}]/u;
    for (let codePoint = 0; codePoint < 0x110000; ++codePoint) {
        const character = String.fromCodePoint(codePoint);
        assert.equal(expanded.test(character), original.test(character), `U+${codePoint.toString(16)}`);
    }
});
