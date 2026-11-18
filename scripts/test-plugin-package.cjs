const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
    deterministicTar,
    installPackage,
    packPlugin,
    parseTar,
    rollbackPackage,
    verifyPackage,
} = require('../MusicBridge/plugin-package.cjs');

function makePlugin(root, { id = 'fixture', version = '1.0.0' } = {}) {
    const directory = path.join(root, id + '-' + version);
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(path.join(directory, 'plugin.cjs'), 'module.exports = { create() { return {}; } };\n');
    fs.writeFileSync(path.join(directory, 'LICENSE'), 'fixture license\n');
    const manifest = {
        schemaVersion: 1,
        apiVersion: '1.0',
        id,
        version,
        entry: { file: 'plugin.cjs' },
        display: { name: 'Fixture plugin' },
        capabilities: { search: true },
    };
    fs.writeFileSync(path.join(directory, 'manifest.json'), JSON.stringify(manifest, null, 4) + '\n');
    return directory;
}

test('packs, verifies and installs a plugin directory', (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-plugin-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const directory = makePlugin(root);
    const packageData = packPlugin(directory);
    assert.deepEqual(packPlugin(directory), packageData);
    const verified = verifyPackage(packageData);
    assert.equal(verified.manifest.id, 'fixture');
    const plugins = path.join(root, 'installed');
    const installed = installPackage(packageData, { plugins });
    assert.equal(installed.id, 'fixture');
    assert.equal(
        fs.readFileSync(path.join(plugins, 'fixture', 'plugin.cjs'), 'utf8'),
        'module.exports = { create() { return {}; } };\n',
    );
});

test('rejects malformed manifests and unsafe archives', (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-plugin-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const directory = makePlugin(root);
    const entries = parseTar(packPlugin(directory));
    const manifestEntry = entries.find((entry) => entry.name === 'manifest.json');
    const manifest = JSON.parse(manifestEntry.data.toString('utf8'));
    const invalid = deterministicTar(
        entries.map((entry) =>
            entry.name === 'manifest.json'
                ? { name: entry.name, data: Buffer.from(JSON.stringify({ ...manifest, id: '../bad' })) }
                : entry,
        ),
    );
    assert.throws(() => verifyPackage(invalid), /plugin id/i);
    const missingEntry = deterministicTar(entries.filter((entry) => entry.name !== 'plugin.cjs'));
    assert.throws(() => verifyPackage(missingEntry), /entry file is missing/i);
    assert.throws(
        () => deterministicTar([{ name: '../escape', data: Buffer.from('x') }]),
        /Unsafe package path/,
    );
    const duplicate = deterministicTar([
        { name: 'same', data: Buffer.from('a') },
        { name: 'same', data: Buffer.from('b') },
    ]);
    assert.throws(() => parseTar(duplicate), /Duplicate package entry/);
});

test('replaces an existing plugin and supports rollback', (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-plugin-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const first = makePlugin(root, { version: '1.0.0' });
    const second = makePlugin(root, { version: '1.1.0' });
    const plugins = path.join(root, 'installed');
    installPackage(packPlugin(first), { plugins });
    installPackage(packPlugin(second), { plugins });
    assert.equal(
        JSON.parse(fs.readFileSync(path.join(plugins, 'fixture', 'manifest.json'), 'utf8')).version,
        '1.1.0',
    );
    rollbackPackage('fixture', plugins);
    assert.equal(
        JSON.parse(fs.readFileSync(path.join(plugins, 'fixture', 'manifest.json'), 'utf8')).version,
        '1.0.0',
    );
});
