'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { checkCompatibility, checkManifest, createHostContext } = require('./plugins/sdk/compatibility.cjs');
const {
    MAX_ARCHIVE,
    MAX_FILE,
    MAX_FILES,
    MAX_MANIFEST,
    MAX_TOTAL,
    assertFileUnchanged,
    checkArchiveLayout,
    decodeUtf8,
    extractArchiveEntry,
    openRegularFile,
    packageError,
    pathKey,
    readArchive,
    readAt,
    readRange,
    safePackagePath,
    writeZip,
} = require('./core/plugin-archive.cjs');

const MANIFEST_FILE = 'manifest.json';
const SHA256 = /^[a-f0-9]{64}$/;
const DEVELOPMENT_FILES =
    /^(?:\.env(?:\.|$)|\.git(?:\/|$)|\.npmrc$|\.netrc$|\.DS_Store$|(?:cookie|credentials|secrets?)s?\.(?:txt|json)$)|\.(?:p12|pfx|pem|key)$/i;
const CREDENTIAL_MARKERS =
    /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{82}\b/;

function isMissing(error) {
    return error.code === 'ENOENT';
}

async function requireDirectory(directory) {
    const stat = await fsp.lstat(directory);
    if (!stat.isDirectory()) {
        throw packageError('插件目录无效或指向链接', 'package.path');
    }
    return fsp.realpath(directory);
}

function ignoreDirectoryNoise(name) {
    return name === '.git' || name === '.DS_Store';
}

/** 限制遍历开销，并验证所有源目录项均位于规范化的源路径之下。 */
async function listDirectory(directory, { skipNoise = false } = {}) {
    const root = await requireDirectory(directory);
    const entries = [];
    let total = 0;
    async function walk(current, prefix) {
        const children = await fsp.opendir(current);
        for await (const child of children) {
            if (skipNoise && ignoreDirectoryNoise(child.name)) {
                continue;
            }
            const name = prefix + child.name;
            if (!safePackagePath(name) || (!child.isDirectory() && !child.isFile())) {
                throw packageError('插件目录包含不安全的路径、链接或特殊文件', 'package.path');
            }
            const filename = path.join(root, name);
            const stat = await fsp.lstat(filename);
            if (
                stat.isDirectory() !== child.isDirectory() ||
                stat.isFile() !== child.isFile() ||
                path.relative(filename, await fsp.realpath(filename)) !== ''
            ) {
                throw packageError('插件目录中的文件在读取时被替换', 'package.changed');
            }
            const size = stat.isFile() ? stat.size : 0;
            entries.push({ name, size, isDirectory: stat.isDirectory() });
            total += size;
            if (size > MAX_FILE || total > MAX_TOTAL || entries.length > MAX_FILES) {
                throw packageError('插件目录体积或文件数超出限制', 'package.limit');
            }
            if (stat.isDirectory()) {
                await walk(filename, name + '/');
            }
        }
    }
    await walk(root, '');
    checkArchiveLayout(entries);
    return { root, entries };
}

async function readManifest(root) {
    let opened;
    try {
        opened = await openRegularFile(path.join(root, MANIFEST_FILE));
    } catch (error) {
        if (isMissing(error)) {
            throw packageError('插件缺少 manifest.json', 'manifest.missing');
        }
        throw error;
    }
    try {
        const { file, stat } = opened;
        if (stat.size > MAX_MANIFEST) {
            throw packageError('插件 manifest 体积超出限制', 'package.limit');
        }
        const bytes = await readAt(file, 0, stat.size);
        await assertFileUnchanged(file, stat);
        return JSON.parse(decodeUtf8(bytes));
    } catch (error) {
        if (error instanceof SyntaxError) {
            throw packageError('插件 manifest.json 无法解析', 'manifest.invalid');
        }
        throw error;
    } finally {
        await opened.file.close();
    }
}

/** 检查市场索引元数据是否与真正的插件包一致。 */
function checkExpectedManifest(manifest, expected) {
    if (!expected) {
        return;
    }
    const { id, version, entry } = expected;
    const expectedFile = typeof entry === 'string' ? entry : entry?.file;
    if (
        (id !== undefined && id !== manifest.id) ||
        (version !== undefined && version !== manifest.version) ||
        (expectedFile !== undefined && expectedFile !== manifest.entry.file) ||
        (entry?.sha256 !== undefined && entry.sha256 !== manifest.entry.sha256) ||
        (entry?.size !== undefined && entry.size !== manifest.entry.size)
    ) {
        throw packageError('插件 ID、版本或入口与市场索引不一致', 'package.integrity');
    }
}

function checkFileMetadata(file, strict) {
    if (!safePackagePath(file.name) || pathKey(file.name) === MANIFEST_FILE) {
        throw packageError('插件清单含不安全或重复的文件路径', 'package.path');
    }
    if (
        (strict || file.sha256 !== undefined) &&
        (typeof file.sha256 !== 'string' || !SHA256.test(file.sha256))
    ) {
        throw packageError('插件文件缺少有效的 SHA-256', 'manifest.invalid');
    }
    if (
        (strict || file.size !== undefined) &&
        (!Number.isSafeInteger(file.size) || file.size < 0 || file.size > MAX_FILE)
    ) {
        throw packageError('插件文件缺少有效的大小', 'manifest.invalid');
    }
}

function manifestFiles(manifest, strict) {
    const entryName = manifest.entry.file;
    const files = new Map();
    for (const entry of manifest.files || []) {
        const file = { name: entry.path, size: entry.size, sha256: entry.sha256 };
        checkFileMetadata(file, strict);
        if (files.has(file.name)) {
            throw packageError('插件清单含重复的文件', 'manifest.invalid');
        }
        files.set(file.name, file);
    }
    const listedEntry = files.get(entryName);
    if (
        listedEntry &&
        ((manifest.entry.size !== undefined && listedEntry.size !== manifest.entry.size) ||
            (manifest.entry.sha256 !== undefined && listedEntry.sha256 !== manifest.entry.sha256))
    ) {
        throw packageError('插件入口与文件清单的摘要不一致', 'manifest.invalid');
    }
    const entry = {
        name: entryName,
        size: manifest.entry.size ?? listedEntry?.size,
        sha256: manifest.entry.sha256 ?? listedEntry?.sha256,
    };
    checkFileMetadata(entry, strict);
    files.set(entryName, entry);
    if (strict) {
        const image = manifest.display?.icon;
        const assetFiles = [image, manifest.sbom, ...Object.values(manifest.quality?.badges || {})];
        for (const name of assetFiles) {
            if (name !== undefined && (typeof name !== 'string' || !files.has(name))) {
                throw packageError('插件清单缺少声明的资源文件', 'manifest.invalid');
            }
        }
        if (typeof image === 'string' && !/\.(?:png|jpe?g|webp)$/i.test(image)) {
            throw packageError('插件图标必须使用 PNG、JPEG 或 WebP 格式', 'manifest.invalid');
        }
    }
    checkArchiveLayout(
        [...files.values()].map((file) => ({ ...file, size: file.size ?? 0, isDirectory: false })),
    );
    return files;
}

async function computeDigest(file, size, checkSecrets = false) {
    const hash = crypto.createHash('sha256');
    let tail = '';
    for await (const bytes of readRange(file, 0, size)) {
        hash.update(bytes);
        if (checkSecrets) {
            const text = tail + bytes.toString('latin1');
            if (CREDENTIAL_MARKERS.test(text)) {
                throw packageError('插件源文件包含私钥或访问令牌', 'package.secrets');
            }
            tail = text.slice(-128);
        }
    }
    return hash.digest('hex');
}

async function checkDeclaredFile(root, file, actual, checkSecrets) {
    if (!actual) {
        throw packageError('缺少插件文件 ' + file.name, 'package.missing-file');
    }
    if (file.size !== undefined && file.size !== actual.size) {
        throw packageError('插件文件大小校验失败 ' + file.name, 'package.integrity');
    }
    if (file.sha256 === undefined && !checkSecrets) {
        return;
    }
    const opened = await openRegularFile(path.join(root, file.name));
    try {
        if (opened.stat.size !== actual.size) {
            throw packageError('插件文件在读取时发生变化', 'package.changed');
        }
        const sha256 = await computeDigest(opened.file, opened.stat.size, checkSecrets);
        await assertFileUnchanged(opened.file, opened.stat);
        if (file.sha256 !== undefined && file.sha256 !== sha256) {
            throw packageError('插件文件 SHA-256 校验失败 ' + file.name, 'package.integrity');
        }
    } finally {
        await opened.file.close();
    }
}

async function inspectDirectory(directory, options) {
    const strict = options.requireDeclarations;
    const { root, entries } = await listDirectory(directory, { skipNoise: options.skipNoise });
    const manifest = await readManifest(root);
    const validationOptions = { legacy: !strict };
    const result = options.host
        ? checkCompatibility(manifest, options.host, validationOptions)
        : checkManifest(manifest, validationOptions);
    if (!result.compatible) {
        throw packageError(result.message, result.code);
    }
    checkExpectedManifest(manifest, options.expected);

    const declared = manifestFiles(manifest, strict);
    const files = new Map(entries.filter((entry) => !entry.isDirectory).map((entry) => [entry.name, entry]));
    for (const [name, file] of declared) {
        if (strict && name.split('/').some((part) => DEVELOPMENT_FILES.test(part))) {
            throw packageError('插件文件清单包含开发配置或凭据文件', 'package.secrets');
        }
        await checkDeclaredFile(root, file, files.get(name), options.checkSecrets);
    }
    if (strict && files.size !== declared.size + 1) {
        throw packageError('插件含有未在 manifest 中声明的文件', 'manifest.invalid');
    }
    if (options.checkSecrets) {
        const manifestEntry = files.get(MANIFEST_FILE);
        await checkDeclaredFile(root, { name: MANIFEST_FILE }, manifestEntry, true);
    }
    return { manifest, root, names: [MANIFEST_FILE, ...declared.keys()] };
}

async function validatePluginDirectory(directory, options = {}) {
    const { manifest } = await inspectDirectory(directory, options);
    return manifest;
}

async function copyDirectory(source, destination) {
    const { root, entries } = await listDirectory(source, { skipNoise: true });
    const relative = path.relative(root, await fsp.realpath(destination));
    if (
        relative === '' ||
        (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))
    ) {
        throw packageError('不能将插件导入到源目录中', 'package.path');
    }
    for (const entry of entries) {
        const target = path.join(destination, entry.name);
        if (entry.isDirectory) {
            await fsp.mkdir(target, { mode: 0o700 });
            continue;
        }
        const filename = path.join(root, entry.name);
        if (path.relative(filename, await fsp.realpath(filename)) !== '') {
            throw packageError('插件文件在读取时被替换', 'package.changed');
        }
        const { file, stat } = await openRegularFile(filename);
        try {
            if (stat.size !== entry.size) {
                throw packageError('插件文件在读取时发生变化', 'package.changed');
            }
            const contents = Readable.from(readRange(file, 0, stat.size), { objectMode: false });
            await pipeline(contents, fs.createWriteStream(target, { flags: 'wx', mode: 0o600 }));
            await assertFileUnchanged(file, stat);
        } finally {
            await file.close();
        }
    }
}

async function extractPackage(source, destination, expected, allowLegacy) {
    const { file, stat } = await openRegularFile(source);
    try {
        if (stat.size > MAX_ARCHIVE || (expected?.size !== undefined && expected.size !== stat.size)) {
            throw packageError('插件包大小超出限制或与市场索引不一致', 'package.integrity');
        }
        if (
            expected?.sha256 !== undefined &&
            (!SHA256.test(expected.sha256) || (await computeDigest(file, stat.size)) !== expected.sha256)
        ) {
            throw packageError('插件包 SHA-256 与市场索引不一致', 'package.integrity');
        }
        const { format, entries } = await readArchive(file, stat.size, allowLegacy);
        for (const entry of entries) {
            await extractArchiveEntry(file, entry, destination);
        }
        await assertFileUnchanged(file, stat);
        return format;
    } finally {
        await file.close();
    }
}

/** 把来源准备到私有空目录并静态校验；失败时只清理本次创建的目录。 */
async function preparePackage(source, destination, { kind, expected, host, allowLegacy = true } = {}) {
    if (kind !== 'package' && kind !== 'directory') {
        throw packageError('插件导入来源无效');
    }
    const staging = path.resolve(destination);
    await fsp.mkdir(staging, { mode: 0o700 });
    try {
        let format = 'directory';
        if (kind === 'directory') {
            await copyDirectory(source, staging);
        } else {
            format = await extractPackage(source, staging, expected, allowLegacy);
        }
        const manifest = await validatePluginDirectory(staging, {
            expected,
            host,
            requireDeclarations: format === 'zip',
        });
        return { manifest, format };
    } catch (error) {
        await fsp.rm(staging, { recursive: true, force: true });
        throw error;
    }
}

async function packPlugin(directory, output = directory + '.rhineplugin', { validateDependencies } = {}) {
    const result = await inspectDirectory(directory, {
        requireDeclarations: true,
        skipNoise: true,
        checkSecrets: true,
    });
    await validateDependencies?.(result.root, result.manifest, result.names);
    const staging = path.resolve(output) + '.partial-' + crypto.randomUUID();
    const file = await fsp.open(staging, 'wx', 0o600);
    try {
        try {
            await writeZip(file, result.root, result.names);
            await file.sync();
        } finally {
            await file.close();
        }
        // 用客户端读取路径回读产物，检测构建过程中源文件发生的变更。
        await verifyPackage(staging);
        await fsp.rename(staging, output);
    } catch (error) {
        await fsp.rm(staging, { force: true });
        throw error;
    }
    return output;
}

async function verifyPackage(source, options = {}) {
    const directory = await fsp.mkdtemp(path.join(os.tmpdir(), 'rhine-plugin-verify-'));
    try {
        return await preparePackage(source, path.join(directory, 'content'), { ...options, kind: 'package' });
    } finally {
        await fsp.rm(directory, { recursive: true, force: true });
    }
}

async function isDirectoryIfPresent(directory) {
    try {
        return (await requireDirectory(directory)) !== '';
    } catch (error) {
        if (isMissing(error)) {
            return false;
        }
        throw error;
    }
}

/** 外部 CLI 保留既有安装和回滚入口，也使用同一目录校验规则。 */
async function activateCliDirectory(staging, target, backup) {
    const rollback = path.join(
        path.dirname(target),
        '.rollback-' + path.basename(target) + '-' + crypto.randomUUID(),
    );
    const hasTarget = await isDirectoryIfPresent(target);
    const hasBackup = hasTarget && backup && (await isDirectoryIfPresent(backup));
    if (hasTarget) {
        await fsp.rename(target, rollback);
    }
    let movedBackup;
    try {
        if (hasBackup) {
            movedBackup = backup + '.previous-' + crypto.randomUUID();
            await fsp.rename(backup, movedBackup);
        }
        await fsp.rename(staging, target);
        if (hasTarget && backup) {
            try {
                await fsp.rename(rollback, backup);
            } catch (error) {
                await fsp.rename(target, staging);
                throw error;
            }
        }
    } catch (error) {
        if (hasTarget) {
            await fsp.rename(rollback, target);
        }
        if (movedBackup && (await isDirectoryIfPresent(movedBackup))) {
            await fsp.rename(movedBackup, backup);
        }
        throw error;
    }
    if (movedBackup) {
        await fsp.rm(movedBackup, { recursive: true, force: true });
    }
    if (hasTarget && !backup) {
        await fsp.rm(rollback, { recursive: true, force: true });
    }
}

async function installPackage(source, { plugins, host = createHostContext() }) {
    const root = path.resolve(plugins);
    await fsp.mkdir(root, { recursive: true });
    await requireDirectory(root);
    const staging = path.join(root, '.staging-package-' + crypto.randomUUID());
    try {
        const { manifest } = await preparePackage(source, staging, { kind: 'package', host });
        const id = manifest.id;
        const backup = path.join(root, '.backup-' + id);
        await activateCliDirectory(staging, path.join(root, id), backup);
        return {
            id,
            version: manifest.version,
            backup: (await isDirectoryIfPresent(backup)) ? backup : null,
        };
    } finally {
        await fsp.rm(staging, { recursive: true, force: true });
    }
}

async function rollbackPackage(id, { plugins, host = createHostContext() }) {
    if (typeof id !== 'string' || !/^[a-z0-9-]{1,40}$/.test(id) || id === 'local' || id === 'siren') {
        throw packageError('插件 ID 无效', 'manifest.invalid');
    }
    const root = await requireDirectory(plugins);
    const target = path.join(root, id);
    const backup = path.join(root, '.backup-' + id);
    if (!(await isDirectoryIfPresent(backup))) {
        throw packageError('没有可回滚的插件版本');
    }
    await validatePluginDirectory(backup, { host, expected: { id } });
    await activateCliDirectory(backup, target);
    return target;
}

module.exports = {
    installPackage,
    packPlugin,
    preparePackage,
    rollbackPackage,
    validatePluginDirectory,
    verifyPackage,
};
