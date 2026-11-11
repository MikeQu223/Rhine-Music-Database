const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const plugin = require('./mobile-bridge-plugin.cjs')();

function handlers() {
    const loads = [];
    plugin.setup({
        onLoad(options, load) {
            loads.push({ options, load });
        },
        onEnd() {},
    });
    return loads;
}

test('移动端构建只匹配 worker 与插件 transport', () => {
    const loads = handlers();
    for (const relativePath of [
        'MusicBridge/worker.cjs',
        'MusicBridge/local-plugins/alpha/alpha-transport.cjs',
    ]) {
        for (const source of [`/repo/${relativePath}`, `C:\\repo\\${relativePath.replaceAll('/', '\\')}`]) {
            assert.equal(
                loads.filter((entry) => entry.options.filter.test(source)).length,
                1,
                source,
            );
        }
    }
    for (const source of ['/repo/MusicBridge/client/siren.mjs', '/repo/MusicBridge/worker.mjs']) {
        assert.equal(
            loads.filter((entry) => entry.options.filter.test(source)).length,
            0,
            source,
        );
    }
});

test('worker 与 transport 的临时目录调用被改写', () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-mobile-'));
    try {
        const worker = path.join(directory, 'MusicBridge/worker.cjs');
        const transport = path.join(directory, 'MusicBridge/local-plugins/alpha/alpha-transport.cjs');
        fs.mkdirSync(path.dirname(worker), { recursive: true });
        fs.mkdirSync(path.dirname(transport), { recursive: true });
        const source = "const dir = require('node:os').tmpdir();\n";
        fs.writeFileSync(worker, source);
        fs.writeFileSync(transport, source);
        for (const file of [worker, transport]) {
            const entry = handlers().find((candidate) => candidate.options.filter.test(file));
            assert(entry, file);
            const contents = entry.load({ path: file }).contents;
            assert.match(contents, /__rhineTmpdir/);
            assert.doesNotMatch(contents, /require\((?:"|')node:os(?:"|')\)\.tmpdir\(\)/);
        }
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
});
