// 最简插件包工具：确定性 tar、manifest 格式校验与原子安装。
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const BLOCK = 512;
const MAX_FILE = 64 * 1024 * 1024;
const MAX_TOTAL = 256 * 1024 * 1024;
const MAX_FILES = 512;

function walk(directory, prefix = '') {
    const files = [];
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (entry.name === 'node_modules' || entry.name === '.git') {
            continue;
        }
        const name = prefix ? prefix + '/' + entry.name : entry.name;
        const full = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            files.push(...walk(full, name));
        } else if (entry.isFile()) {
            files.push({ name, data: fs.readFileSync(full) });
        }
    }
    return files;
}

function safeRelative(file) {
    if (typeof file !== 'string' || !file || path.isAbsolute(file) || file.includes('\\')) {
        throw new Error('Unsafe package path: ' + file);
    }
    const normalized = path.posix.normalize(file);
    if (normalized.startsWith('../') || normalized === '..' || normalized.startsWith('/')) {
        throw new Error('Unsafe package path: ' + file);
    }
    return normalized;
}

function tarHeader(name, size) {
    let prefix = '';
    let entry = name;
    if (Buffer.byteLength(name) > 100) {
        const split = name.lastIndexOf('/', 155);
        if (split <= 0) {
            throw new Error('Tar path is too long: ' + name);
        }
        prefix = name.slice(0, split);
        entry = name.slice(split + 1);
    }
    const header = Buffer.alloc(BLOCK, 0);
    header.write(entry, 0, 100, 'utf8');
    header.write('0000644\0', 100, 8, 'ascii');
    header.write('0000000\0', 108, 8, 'ascii');
    header.write('0000000\0', 116, 8, 'ascii');
    header.write(size.toString(8).padStart(11, '0') + '\0', 124, 12, 'ascii');
    header.write('00000000000\0', 136, 12, 'ascii');
    header.write('        ', 148, 8, 'ascii');
    header.write('0', 156, 1, 'ascii');
    header.write('ustar\0', 257, 6, 'ascii');
    header.write('00', 263, 2, 'ascii');
    header.write(prefix, 345, 155, 'utf8');
    let sum = 0;
    for (const byte of header) {
        sum += byte;
    }
    header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
    return header;
}

function deterministicTar(entries) {
    const blocks = [];
    for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
        const name = safeRelative(entry.name);
        const data = entry.data;
        blocks.push(tarHeader(name, data.length), data);
        const padding = (BLOCK - (data.length % BLOCK)) % BLOCK;
        if (padding) {
            blocks.push(Buffer.alloc(padding, 0));
        }
    }
    blocks.push(Buffer.alloc(BLOCK * 2, 0));
    return Buffer.concat(blocks);
}

function parseTar(buffer) {
    if (!Buffer.isBuffer(buffer) || buffer.length < BLOCK * 2 || buffer.length % BLOCK !== 0) {
        throw new Error('Invalid package archive');
    }
    const entries = [];
    const seen = new Set();
    let offset = 0;
    let total = 0;
    while (offset + BLOCK <= buffer.length) {
        const header = buffer.subarray(offset, offset + BLOCK);
        if (header.every((byte) => byte === 0)) {
            break;
        }
        const stored = parseInt(header.toString('ascii', 148, 154).trim(), 8);
        let sum = 0;
        for (let index = 0; index < BLOCK; index++) {
            sum += index >= 148 && index < 156 ? 0x20 : header[index];
        }
        if (!Number.isFinite(stored) || stored !== sum) {
            throw new Error('Invalid tar header checksum');
        }
        const type = header.toString('ascii', 156, 157);
        if (type !== '0' && type !== '\0') {
            throw new Error('Unsupported package entry type: ' + type);
        }
        const entryName = header.toString('utf8', 0, 100).replace(/\0.*$/, '');
        const prefix = header.toString('utf8', 345, 500).replace(/\0.*$/, '');
        const name = safeRelative(prefix ? prefix + '/' + entryName : entryName);
        if (seen.has(name)) {
            throw new Error('Duplicate package entry: ' + name);
        }
        seen.add(name);
        const size = parseInt(header.toString('ascii', 124, 136).trim(), 8);
        if (!Number.isFinite(size) || size < 0 || size > MAX_FILE) {
            throw new Error('Package entry is too large: ' + name);
        }
        const start = offset + BLOCK;
        if (start + size > buffer.length) {
            throw new Error('Truncated package entry: ' + name);
        }
        total += size;
        if (total > MAX_TOTAL || entries.length >= MAX_FILES) {
            throw new Error('Package exceeds size limits');
        }
        entries.push({ name, data: buffer.subarray(start, start + size) });
        offset = start + Math.ceil(size / BLOCK) * BLOCK;
    }
    if (!entries.length) {
        throw new Error('Empty package');
    }
    return entries;
}

function validateManifest(manifest) {
    if (!manifest || typeof manifest !== 'object') {
        throw new Error('manifest.json is missing');
    }
    if (!/^[a-z0-9-]{1,40}$/.test(String(manifest.id || ''))) {
        throw new Error('Invalid plugin id');
    }
    if (manifest.id === 'local' || manifest.id === 'siren') {
        throw new Error('Reserved plugin id');
    }
    if (typeof manifest.version !== 'string' || !manifest.version) {
        throw new Error('Plugin version is missing');
    }
    if (typeof manifest.apiVersion !== 'string' || !/^[0-9]+\.[0-9]+$/.test(manifest.apiVersion)) {
        throw new Error('apiVersion is invalid');
    }
    if (!manifest.entry || typeof manifest.entry.file !== 'string' || !manifest.entry.file) {
        throw new Error('Plugin entry is missing');
    }
    if (!manifest.display?.name || !manifest.capabilities) {
        throw new Error('Plugin display or capabilities are missing');
    }
}

function verifyPackage(buffer) {
    const entries = parseTar(buffer);
    const byName = new Map(entries.map((entry) => [entry.name, entry.data]));
    const manifestData = byName.get('manifest.json');
    if (!manifestData) {
        throw new Error('manifest.json is missing');
    }
    const manifest = JSON.parse(manifestData.toString('utf8'));
    validateManifest(manifest);
    const entry = safeRelative(manifest.entry.file);
    if (!byName.has(entry)) {
        throw new Error('Plugin entry file is missing: ' + entry);
    }
    return { manifest, entries };
}

function packPlugin(directory) {
    const files = walk(path.resolve(directory));
    if (!files.some((entry) => entry.name === 'manifest.json')) {
        throw new Error('Plugin directory is missing manifest.json');
    }
    return deterministicTar(files);
}

function extractEntries(entries, destination) {
    fs.mkdirSync(destination, { recursive: true });
    for (const { name, data } of entries) {
        const target = path.resolve(destination, safeRelative(name));
        if (!target.startsWith(path.resolve(destination) + path.sep)) {
            throw new Error('Package path escapes destination: ' + name);
        }
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, data, { mode: 0o644 });
    }
}

function installPackage(buffer, options) {
    const { manifest, entries } = verifyPackage(buffer);
    const id = manifest.id;
    const root = path.resolve(options.plugins);
    const target = path.join(root, id);
    fs.mkdirSync(root, { recursive: true });
    const staging = path.join(root, '.staging-' + id + '-' + crypto.randomUUID());
    const backup = path.join(root, '.backup-' + id);
    extractEntries(entries, staging);
    fs.rmSync(backup, { recursive: true, force: true });
    let moved = false;
    try {
        if (fs.existsSync(target)) {
            fs.renameSync(target, backup);
            moved = true;
        }
        fs.renameSync(staging, target);
    } catch (error) {
        fs.rmSync(staging, { recursive: true, force: true });
        if (moved) {
            fs.renameSync(backup, target);
        }
        throw error;
    }
    return { id, version: manifest.version, backup: moved ? backup : null };
}

function rollbackPackage(id, plugins) {
    if (!/^[a-z0-9-]{1,40}$/.test(String(id || ''))) {
        throw new Error('Invalid plugin id');
    }
    const root = path.resolve(plugins);
    const target = path.join(root, id);
    const backup = path.join(root, '.backup-' + id);
    if (!fs.existsSync(backup)) {
        throw new Error('No backup available for ' + id);
    }
    const staging = path.join(root, '.rollback-' + id + '-' + crypto.randomUUID());
    let moved = false;
    if (fs.existsSync(target)) {
        fs.renameSync(target, staging);
        moved = true;
    }
    try {
        fs.renameSync(backup, target);
        fs.rmSync(staging, { recursive: true, force: true });
    } catch (error) {
        if (moved) {
            fs.renameSync(staging, target);
        }
        throw error;
    }
    return target;
}

function runCli(argv) {
    const [command, ...args] = argv;
    const options = {};
    const positional = [];
    for (let index = 0; index < args.length; index++) {
        const value = args[index];
        if (value === '--plugins') {
            options.plugins = args[++index];
        } else if (value === '--out') {
            options.out = args[++index];
        } else {
            positional.push(value);
        }
    }
    try {
        if (command === 'pack') {
            const output = options.out || positional[0] + '.rhineplugin';
            fs.writeFileSync(output, packPlugin(path.resolve(positional[0])));
            console.log('Plugin package written: ' + output);
        } else if (command === 'verify') {
            const { manifest } = verifyPackage(fs.readFileSync(positional[0]));
            console.log('Plugin package verified: ' + manifest.id + '@' + manifest.version);
        } else if (command === 'install') {
            const result = installPackage(fs.readFileSync(positional[0]), options);
            console.log('Installed ' + result.id + '@' + result.version);
        } else if (command === 'rollback') {
            rollbackPackage(positional[0], options.plugins);
            console.log('Rolled back ' + positional[0]);
        } else {
            throw new Error(
                'Usage: plugin-package.cjs pack <dir> [--out <file>] | verify <file> | install <file> --plugins <dir> | rollback <id> --plugins <dir>',
            );
        }
    } catch (error) {
        console.error(error.message);
        process.exit(1);
    }
}

module.exports = {
    deterministicTar,
    installPackage,
    packPlugin,
    parseTar,
    rollbackPackage,
    runCli,
    verifyPackage,
};

if (require.main === module) {
    runCli(process.argv.slice(2));
}
