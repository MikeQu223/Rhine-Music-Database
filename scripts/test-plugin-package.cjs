'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { promisify } = require('node:util');
const {
    installPackage,
    packPlugin,
    preparePackage,
    rollbackPackage,
    verifyPackage,
} = require('../MusicBridge/plugin-package.cjs');
const { createHostContext } = require('../MusicBridge/plugins/sdk/compatibility.cjs');

const HOST = createHostContext({ clientVersion: '1.3.25+local' });
const ENTRY = Buffer.from("throw new Error('入口在静态预检时不得执行');\n");
const LICENSE = Buffer.from('Fixture license\n');
const execFileAsync = promisify(execFile);

function fileMetadata(bytes) {
    return { size: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
}

function makeManifest(overrides = {}) {
    return {
        schemaVersion: 2,
        apiVersion: '2.0',
        id: 'fixture',
        version: '1.0.0',
        requiresHost: '>=2.0 <3.0',
        requiresClient: '>=1.3.25 <2.0.0',
        entry: { file: 'plugin.cjs', ...fileMetadata(ENTRY) },
        files: [{ path: 'LICENSE', ...fileMetadata(LICENSE) }],
        display: { name: 'Fixture plugin', label: 'FIXTURE', detail: 'Fixture for package tests' },
        capabilities: { search: true },
        ...overrides,
    };
}

function fixtureFiles(manifest) {
    return [
        { name: 'manifest.json', data: Buffer.from(JSON.stringify(manifest)) },
        { name: manifest.entry.file, data: ENTRY },
        { name: 'LICENSE', data: LICENSE },
    ];
}

async function setup(t) {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'rhine-plugin-'));
    t.after(() => fs.rm(root, { recursive: true, force: true }));
    return root;
}

async function createPlugin(root, overrides) {
    const manifest = makeManifest(overrides);
    const directory = path.join(root, manifest.id + '-' + manifest.version);
    await fs.mkdir(directory);
    for (const file of fixtureFiles(manifest)) {
        await fs.writeFile(path.join(directory, file.name), file.data);
    }
    return directory;
}

/** 生成一个最小标准 ZIP，用于覆盖外部常见 Store 与不合法元数据。 */
function testZip(entries) {
    const localRecords = [];
    const centralRecords = [];
    let offset = 0;
    for (const entry of entries) {
        const name = Buffer.from(entry.name, 'utf8');
        const payload = entry.compress ? zlib.deflateRawSync(entry.data) : entry.data;
        const local = Buffer.alloc(30 + name.length);
        local.writeUInt32LE(0x04034b50);
        local.writeUInt16LE(20, 4);
        local.writeUInt16LE(0x800, 6);
        local.writeUInt16LE(entry.compress ? 8 : 0, 8);
        local.writeUInt32LE(entry.checksum ?? zlib.crc32(entry.data), 14);
        local.writeUInt32LE(payload.length, 18);
        local.writeUInt32LE(entry.size ?? entry.data.length, 22);
        local.writeUInt16LE(name.length, 26);
        Buffer.from(entry.localName || entry.name, 'utf8').copy(local, 30);
        localRecords.push(local, payload);

        const central = Buffer.alloc(46 + name.length);
        central.writeUInt32LE(0x02014b50);
        central.writeUInt16LE(0x0314, 4);
        local.copy(central, 6, 4, 28);
        central.writeUInt32LE(((entry.permissions ?? 0o100644) << 16) >>> 0, 38);
        central.writeUInt32LE(offset, 42);
        name.copy(central, 46);
        centralRecords.push(central);
        offset += local.length + payload.length;
    }
    const central = Buffer.concat(centralRecords);
    const footer = Buffer.alloc(22);
    footer.writeUInt32LE(0x06054b50);
    footer.writeUInt16LE(entries.length, 8);
    footer.writeUInt16LE(entries.length, 10);
    footer.writeUInt32LE(central.length, 12);
    footer.writeUInt32LE(offset, 16);
    return Buffer.concat([...localRecords, central, footer]);
}

/** 按旧 CLI 的 USTAR 字段与结束块生成兼容回归样本。 */
function legacyTar(entries) {
    const blocks = [];
    for (const { name, data, type = '0' } of entries) {
        const header = Buffer.alloc(512);
        header.write(name, 0, 100, 'utf8');
        header.write('0000644\0', 100, 8, 'ascii');
        header.write(data.length.toString(8).padStart(11, '0') + '\0', 124, 12, 'ascii');
        header.write('        ', 148, 8, 'ascii');
        header.write(type, 156, 1, 'ascii');
        header.write('ustar\0' + '00', 257, 8, 'ascii');
        const sum = header.reduce((previous, next) => previous + next, 0);
        header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
        blocks.push(header, data, Buffer.alloc((512 - (data.length % 512)) % 512));
    }
    return Buffer.concat([...blocks, Buffer.alloc(1024)]);
}

test('ZIP 本地打包、离线预检和目录暂存使用相同的 manifest 与文件', async (t) => {
    const root = await setup(t);
    const plugin = await createPlugin(root);
    const archive = await packPlugin(plugin);
    const bytes = await fs.readFile(archive);
    assert.equal(bytes.readUInt32LE(0), 0x04034b50);
    const second = await packPlugin(plugin, path.join(root, 'repeat.rhineplugin'));
    assert.deepEqual(await fs.readFile(second), bytes);

    const verify = await verifyPackage(archive, { host: HOST });
    assert.equal(verify.format, 'zip');
    assert.equal(verify.manifest.id, 'fixture');
    const zipDestination = path.join(root, 'zip');
    const folderDestination = path.join(root, 'folder');
    const expectations = {
        id: 'fixture',
        version: '1.0.0',
        entry: makeManifest().entry,
        ...fileMetadata(bytes),
    };
    const zip = await preparePackage(archive, zipDestination, {
        kind: 'package',
        host: HOST,
        expected: expectations,
    });
    const folder = await preparePackage(plugin, folderDestination, { kind: 'directory', host: HOST });
    assert.deepEqual(zip.manifest, folder.manifest);
    for (const file of fixtureFiles(verify.manifest)) {
        assert.deepEqual(await fs.readFile(path.join(zipDestination, file.name)), file.data);
        assert.deepEqual(await fs.readFile(path.join(folderDestination, file.name)), file.data);
    }
});

test('ZIP 预检拒绝版本不兼容、市场身份不一致或损坏并清理暂存', async (t) => {
    const root = await setup(t);
    const plugin = await createPlugin(root);
    const archive = await packPlugin(plugin);
    const staged = path.join(root, 'staging');
    const prepare = (options) => preparePackage(archive, staged, { kind: 'package', host: HOST, ...options });
    await assert.rejects(prepare({ host: createHostContext({ clientVersion: '1.3.25-rc.1' }) }), {
        code: 'plugin.incompatible',
    });
    await assert.rejects(fs.stat(staged), { code: 'ENOENT' });
    await assert.rejects(prepare({ expected: { version: '1.0.1' } }), { code: 'package.integrity' });
    await assert.rejects(fs.stat(staged), { code: 'ENOENT' });
    await assert.rejects(prepare({ expected: { sha256: 'a'.repeat(64) } }), { code: 'package.integrity' });
    await assert.rejects(fs.stat(staged), { code: 'ENOENT' });
    await fs.mkdir(staged);
    await fs.writeFile(path.join(staged, 'keep'), 'Existing directory');
    await assert.rejects(prepare({}), { code: 'EEXIST' });
    assert.equal(await fs.readFile(path.join(staged, 'keep'), 'utf8'), 'Existing directory');
});

test('ZIP 支持 Store，拒绝路径穿越、冲突、链接与重复本地头', async (t) => {
    const root = await setup(t);
    const archive = path.join(root, 'external.rhineplugin');
    const files = fixtureFiles(makeManifest());
    await fs.writeFile(archive, testZip(files));
    assert.equal((await verifyPackage(archive)).format, 'zip');
    const extras = [
        { name: '../escape' },
        { name: '/absolute' },
        { name: 'C:/drive' },
        { name: 'folder/../file' },
        { name: 'folder\\file' },
        { name: 'Folder/AUX.txt' },
        { name: 'LICENSE/child' },
        { name: 'license' },
        { name: 'manifest.json' },
        { name: 'outside', permissions: 0o120777 },
    ];
    for (const extra of extras) {
        await fs.writeFile(archive, testZip([...files, { ...extra, data: Buffer.alloc(0) }]));
        await assert.rejects(verifyPackage(archive), { code: 'package.path' }, extra.name);
    }
    const brokenHeader = [...files];
    brokenHeader[1] = { ...files[1], localName: 'replac.cjs' };
    await fs.writeFile(archive, testZip(brokenHeader));
    await assert.rejects(verifyPackage(archive), /本地文件名/);
});

test('ZIP 预检验证 CRC、实际解压大小、异常压缩包及文件数', async (t) => {
    const root = await setup(t);
    const archive = path.join(root, 'corrupt.rhineplugin');
    const files = fixtureFiles(makeManifest());
    await fs.writeFile(archive, testZip([{ ...files[0], checksum: 0 }, ...files.slice(1)]));
    await assert.rejects(verifyPackage(archive), { code: 'package.integrity' });
    await fs.writeFile(archive, testZip([{ ...files[0], compress: true, size: 4 }, ...files.slice(1)]));
    await assert.rejects(verifyPackage(archive), { code: 'package.limit' });
    await fs.writeFile(
        archive,
        testZip([{ ...files[0], compress: true, size: 64 * 1024 * 1024 + 1 }, ...files.slice(1)]),
    );
    await assert.rejects(verifyPackage(archive), { code: 'package.limit' });
    const tooMany = Array.from({ length: 510 }, (_, index) => ({ name: 'f' + index, data: Buffer.alloc(0) }));
    await fs.writeFile(archive, testZip([...files, ...tooMany]));
    await assert.rejects(verifyPackage(archive), /中央目录/);
    await fs.writeFile(archive, testZip(files).subarray(0, -4));
    await assert.rejects(verifyPackage(archive), /中央目录/);
});

test('ZIP 打包验证 manifest 清单和摘要并排除开发文件', async (t) => {
    const root = await setup(t);
    const plugin = await createPlugin(root);
    const manifest = makeManifest();
    await fs.writeFile(path.join(plugin, 'manifest.json'), JSON.stringify({ ...manifest, files: [] }));
    await assert.rejects(packPlugin(plugin), /未在 manifest 中声明/);
    await fs.writeFile(
        path.join(plugin, 'manifest.json'),
        JSON.stringify({ ...manifest, requiresClient: undefined }),
    );
    await assert.rejects(packPlugin(plugin), /requiresClient/);
    await fs.writeFile(path.join(plugin, 'manifest.json'), JSON.stringify(manifest));
    await fs.writeFile(path.join(plugin, 'LICENSE'), Buffer.alloc(LICENSE.length, 'x'));
    await assert.rejects(packPlugin(plugin), /SHA-256/);
    const developerFile = { path: '.env.local', ...fileMetadata(Buffer.alloc(0)) };
    await fs.writeFile(path.join(plugin, 'LICENSE'), LICENSE);
    await fs.writeFile(path.join(plugin, developerFile.path), Buffer.alloc(0));
    await fs.writeFile(
        path.join(plugin, 'manifest.json'),
        JSON.stringify({ ...manifest, files: [...manifest.files, developerFile] }),
    );
    await assert.rejects(packPlugin(plugin), { code: 'package.secrets' });
});

test('打包 CLI 静态校验入口依赖，无需运行插件代码', async (t) => {
    const root = await setup(t);
    const plugin = await createPlugin(root);
    const manifest = makeManifest();
    const script = path.join(__dirname, 'plugin-package.cjs');
    const pack = () => execFileAsync(process.execPath, [script, 'pack', plugin]);
    const entry = path.join(plugin, manifest.entry.file);
    const manifestPath = path.join(plugin, 'manifest.json');
    const writeEntry = async (contents) => {
        const bytes = Buffer.from(contents);
        const updated = { ...manifest, entry: { file: manifest.entry.file, ...fileMetadata(bytes) } };
        await fs.writeFile(entry, bytes);
        await fs.writeFile(manifestPath, JSON.stringify(updated));
    };
    await writeEntry('module.exports = require("./required-runtime");');
    await assert.rejects(pack(), /入口依赖校验失败/);
    await fs.mkdir(path.join(root, 'node_modules', 'fixture-runtime'), { recursive: true });
    await fs.writeFile(
        path.join(root, 'node_modules', 'fixture-runtime', 'index.js'),
        'module.exports = {};',
    );
    await writeEntry('module.exports = require("fixture-runtime");');
    await assert.rejects(pack(), /未包含在文件清单中/);
    await writeEntry('try { require("fixture-optional"); } catch {}\nthrow new Error("do not execute");');
    await pack();
    const packed = await verifyPackage(plugin + '.rhineplugin');
    assert.equal(packed.manifest.version, '1.0.0');
});

test('旧 TAR 识别格式，保留已知旧 SDK 声明并拒绝旧 schema 或链接', async (t) => {
    const root = await setup(t);
    const archive = path.join(root, 'legacy.rhineplugin');
    const manifest = makeManifest({ requiresClient: undefined });
    await fs.writeFile(archive, legacyTar(fixtureFiles(manifest)));
    assert.equal((await verifyPackage(archive, { host: HOST })).format, 'legacy-tar');
    await assert.rejects(verifyPackage(archive, { host: HOST, allowLegacy: false }), {
        code: 'package.format',
    });
    await fs.writeFile(
        archive,
        legacyTar(fixtureFiles({ ...manifest, schemaVersion: 1, apiVersion: '1.0' })),
    );
    await assert.rejects(verifyPackage(archive), { code: 'plugin.incompatible' });
    await fs.writeFile(
        archive,
        legacyTar([...fixtureFiles(manifest), { name: 'link', type: '2', data: ENTRY }]),
    );
    await assert.rejects(verifyPackage(archive), /不支持的条目/);
});

test('目录导入拒绝符号链接', { skip: process.platform === 'win32' }, async (t) => {
    const root = await setup(t);
    const plugin = await createPlugin(root);
    const external = path.join(root, 'outside.txt');
    await fs.writeFile(external, 'Outside');
    await fs.symlink(external, path.join(plugin, 'link'));
    const staged = path.join(root, 'staged');
    await assert.rejects(preparePackage(plugin, staged, { kind: 'directory', host: HOST }), {
        code: 'package.path',
    });
    await assert.rejects(fs.stat(staged), { code: 'ENOENT' });
});

test('CLI 安装兼容更新，坏包保持现有版本，回滚仍验证兼容性', async (t) => {
    const root = await setup(t);
    const first = await packPlugin(await createPlugin(root));
    const improved = await packPlugin(await createPlugin(root, { version: '1.1.0' }));
    const broken = path.join(root, 'broken.rhineplugin');
    await fs.writeFile(broken, Buffer.alloc(30));
    const plugins = path.join(root, 'installed');
    const options = { plugins, host: HOST };
    await installPackage(first, options);
    await installPackage(improved, options);
    await assert.rejects(installPackage(broken, options));
    const installedManifest = path.join(plugins, 'fixture', 'manifest.json');
    assert.equal(JSON.parse(await fs.readFile(installedManifest, 'utf8')).version, '1.1.0');
    await assert.rejects(
        rollbackPackage('fixture', { plugins, host: createHostContext({ clientVersion: '1.0.0' }) }),
        { code: 'plugin.incompatible' },
    );
    await rollbackPackage('fixture', options);
    assert.equal(JSON.parse(await fs.readFile(installedManifest, 'utf8')).version, '1.0.0');
});
