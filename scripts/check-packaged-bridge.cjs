// 发布包内验证通用插件契约：manifest、入口哈希、worker 路由与操作白名单。
// 不访问实际音乐 API；协议级回归由各插件仓库自己的测试负责。
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { bridgeRuntime } = require('../Qt/tests/fixtures/bridge-runtime.cjs');
const { bridge, runtime } = bridgeRuntime();
const temp = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'rhine-package-check-'));

function installedPlugins() {
    const directory = path.join(bridge, 'local-plugins');
    if (!fs.existsSync(directory)) {
        return [];
    }
    return fs
        .readdirSync(directory, { withFileTypes: true })
        .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'))
        .map((entry) => {
            const root = path.join(directory, entry.name);
            const manifestFile = path.join(root, 'manifest.json');
            if (!fs.existsSync(manifestFile)) {
                return null;
            }
            return { root, manifest: JSON.parse(fs.readFileSync(manifestFile, 'utf8')) };
        })
        .filter(Boolean);
}

function verifyManifest({ root, manifest }) {
    assert.equal(manifest.schemaVersion, 2, manifest.id + ': schemaVersion');
    assert.match(manifest.apiVersion, /^2\.\d+$/, manifest.id + ': apiVersion');
    const entry = path.join(root, manifest.entry.file);
    assert(fs.existsSync(entry), manifest.id + ': entry missing');
    if (manifest.entry.sha256) {
        const data = fs.readFileSync(entry);
        assert.equal(
            crypto.createHash('sha256').update(data).digest('hex'),
            manifest.entry.sha256,
            manifest.id + ': entry hash',
        );
        assert.equal(data.length, manifest.entry.size, manifest.id + ': entry size');
    }
    const badges = manifest.quality?.badges || {};
    for (const [badge, relative] of Object.entries(badges)) {
        assert(
            fs.existsSync(path.join(root, relative)),
            manifest.id + ': badge asset missing: ' + badge,
        );
    }
}

async function main() {
    const plugins = installedPlugins();
    assert(plugins.length > 0, 'packaged bridge has no plugins');
    for (const plugin of plugins) {
        verifyManifest(plugin);
    }
    let child;
    try {
        child = spawn(runtime, [path.join(bridge, 'worker.cjs')], {
            cwd: bridge,
            env: {
                ...process.env,
                TMPDIR: temp,
                TEMP: temp,
                LANG: 'en_US.UTF-8',
            },
            stdio: ['pipe', 'pipe', 'pipe'],
        });
        let errors = '';
        let buffer = '';
        const pending = new Map();
        child.stderr.on('data', (data) => (errors += data));
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
                    for (const entry of pending.values()) {
                        entry.reject(error);
                    }
                    return;
                }
                const entry = pending.get(result.id);
                if (entry) {
                    clearTimeout(entry.timer);
                    pending.delete(result.id);
                    entry.resolve(result);
                }
            }
        });
        function request(id, route, params = {}, cookies = {}, env = {}) {
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    pending.delete(id);
                    reject(new Error('IPC timeout (' + id + '): ' + errors));
                }, 15000);
                pending.set(id, { resolve, reject, timer });
                child.stdin.write(JSON.stringify({ id, route, params, cookies, env }) + '\n');
            });
        }
        for (const { manifest } of plugins) {
            const unsupported = await request(
                'unsupported-' + manifest.id,
                '/native/' + manifest.id + '/__contract_probe',
                { args: [] },
            );
            assert.equal(unsupported.body.errorKey, 'provider.unsupported', manifest.id);
            const invalid = await request('invalid-' + manifest.id, '/plugin/' + manifest.id);
            assert.equal(invalid.body.errorKey, 'route.invalid', manifest.id);
        }
        const missingPlugin = await request('missing-plugin', '/plugin/nope/search', { args: [] });
        assert.equal(missingPlugin.body.code, 404);
        assert.equal(missingPlugin.body.errorKey, 'plugin.missing');
        const missingNative = await request('missing-native', '/native/nope/search', { args: [] });
        assert.equal(missingNative.body.code, 404);
        assert.equal(missingNative.body.errorKey, 'plugin.missing');
        const lyrics = await request('local-lyrics', '/local/lyrics', {
            content: '[00:01.00]本地歌词\n[00:03.00]第二行\n',
        });
        assert.equal(lyrics.body.code, 200, JSON.stringify(lyrics.body));
        assert.deepEqual(
            lyrics.body.document.lines.map((line) => line.startMs),
            [1000, 3000],
        );
        child.stdin.end();
        const exit = await new Promise((resolve) => {
            child.once('exit', (code, signal) => resolve({ code, signal }));
        });
        assert.equal(exit.code, 0, 'packaged bridge must finish cleanly after stdin closes');
        assert.equal(exit.signal, null);
        assert.equal(errors, '');
        console.log(
            'Packaged plugin manifests, entry hashes, worker route allowlists and local lyrics passed',
        );
    } finally {
        if (child && child.exitCode === null) {
            child.kill();
        }
        fs.rmSync(temp, { recursive: true, force: true });
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
