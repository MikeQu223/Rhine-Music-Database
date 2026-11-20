'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { Readable, Transform, Writable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { createDeflateRaw, createInflateRaw } = require('node:zlib');

const MAX_FILE = 64 * 1024 * 1024;
const MAX_TOTAL = 256 * 1024 * 1024;
const MAX_ARCHIVE = MAX_TOTAL + 8 * 1024 * 1024;
const MAX_FILES = 512;
const MAX_PATH_BYTES = 240;
const MAX_MANIFEST = 256 * 1024;
const CHUNK_SIZE = 64 * 1024;
const TAR_BLOCK = 512;
const ZIP_LOCAL = 0x04034b50;
const ZIP_CENTRAL = 0x02014b50;
const ZIP_END = 0x06054b50;
const ZIP_DESCRIPTOR = 0x08074b50;
const ZIP_UTF8 = 0x800;
const ZIP_HAS_DESCRIPTOR = 0x008;
const ZIP_COMPRESSION_OPTIONS = 0x006;
const ZIP_DEFLATE = 8;

function packageError(message, code = 'package.invalid') {
    return Object.assign(new Error(message), { code });
}

function decodeUtf8(bytes) {
    const text = bytes.toString('utf8');
    if (!Buffer.from(text, 'utf8').equals(bytes)) {
        throw packageError('插件包包含无效的 UTF-8 文本');
    }
    return text;
}

function pathKey(name) {
    return name.normalize('NFC').toUpperCase().toLowerCase();
}

function safePackagePath(name) {
    return (
        typeof name === 'string' &&
        name.length > 0 &&
        name === name.normalize('NFC') &&
        Buffer.from(name, 'utf8').toString('utf8') === name &&
        Buffer.byteLength(name, 'utf8') <= MAX_PATH_BYTES &&
        // Windows 不允许这些字符，也不能通过冒号写入 NTFS 数据流。
        !/[<>:"\\|?*]/.test(name) &&
        !Array.from(name).some(
            (character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127,
        ) &&
        name.split('/').length <= 16 &&
        name.split('/').every((part) => {
            return (
                part.length > 0 &&
                !/[. ]$/.test(part) &&
                !/^(?:con|prn|aux|nul|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?: *\.|$)/i.test(part)
            );
        })
    );
}

/** 按跨平台文件名规则登记目录项，避免大小写及文件与子目录冲突。 */
function checkArchiveLayout(entries) {
    if (entries.length > MAX_FILES) {
        throw packageError('插件文件数量超出限制', 'package.limit');
    }
    const paths = new Map();
    let total = 0;
    for (const entry of entries) {
        const { name, isDirectory, size } = entry;
        if (!safePackagePath(name)) {
            throw packageError('插件包包含不安全的文件路径', 'package.path');
        }
        total += size;
        if (size > MAX_FILE || total > MAX_TOTAL || (name === 'manifest.json' && size > MAX_MANIFEST)) {
            throw packageError('插件解压后体积超出限制', 'package.limit');
        }
        let parent = name;
        while (parent.length > 0) {
            const key = pathKey(parent);
            const current = paths.get(key);
            const explicit = parent === name;
            const directory = !explicit || isDirectory;
            if (
                current &&
                (current.name !== parent || current.directory !== directory || (explicit && current.explicit))
            ) {
                throw packageError('插件包包含重复或冲突的文件路径', 'package.path');
            }
            if (!current || explicit) {
                paths.set(key, { name: parent, directory, explicit });
            }
            if (paths.size > MAX_FILES * 2) {
                throw packageError('插件目录数量超出限制', 'package.limit');
            }
            parent = parent.slice(0, Math.max(0, parent.lastIndexOf('/')));
        }
    }
}

async function readAt(file, position, length) {
    const bytes = Buffer.allocUnsafe(length);
    let offset = 0;
    while (offset < length) {
        const result = await file.read(bytes, offset, length - offset, position + offset);
        if (!result.bytesRead) {
            throw packageError('插件包内容不完整');
        }
        offset += result.bytesRead;
    }
    return bytes;
}

async function* readRange(file, offset, size) {
    for (let consumed = 0; consumed < size;) {
        const bytes = await readAt(file, offset + consumed, Math.min(CHUNK_SIZE, size - consumed));
        consumed += bytes.length;
        yield bytes;
    }
}

/** 打开前后都核对文件类型和身份，读取时禁止跟随符号链接。 */
async function openRegularFile(filename) {
    const before = await fsp.lstat(filename);
    if (!before.isFile()) {
        throw packageError('插件包含链接或特殊文件', 'package.path');
    }
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
    const file = await fsp.open(filename, flags);
    try {
        const stat = await file.stat();
        if (!stat.isFile() || !sameFile(before, stat)) {
            throw packageError('插件文件在读取时发生变化', 'package.changed');
        }
        return { file, stat };
    } catch (error) {
        await file.close();
        throw error;
    }
}

function sameFile(before, after) {
    // Windows 的 lstat 可能把 st_dev 报为 0，打开后的 fstat 才返回卷序列号。
    // 仅忽略这种缺失值；两侧均为非零时仍要求设备号一致。
    const missingDevice = process.platform === 'win32' && (before.dev === 0 || after.dev === 0);
    return (
        (before.dev === after.dev || missingDevice) &&
        before.ino === after.ino &&
        before.size === after.size &&
        before.mtimeMs === after.mtimeMs &&
        before.ctimeMs === after.ctimeMs
    );
}

async function assertFileUnchanged(file, before) {
    if (!sameFile(before, await file.stat())) {
        throw packageError('插件文件在读取时发生变化', 'package.changed');
    }
}

// Node Mobile 18 没有 zlib.crc32。用 ZIP 规定的 CRC-32 计算每个实际解压流。
const CRC_TABLE = Uint32Array.from({ length: 256 }, (_, byte) => {
    let remainder = byte;
    for (let bit = 0; bit < 8; bit++) {
        remainder = (remainder >>> 1) ^ (remainder & 1 ? 0xedb88320 : 0);
    }
    return remainder;
});

class ArchiveFileMeter extends Transform {
    constructor(maximum) {
        super();
        this.maximum = maximum;
        this.size = 0;
        this.remainder = 0xffffffff;
    }

    get checksum() {
        return (this.remainder ^ 0xffffffff) >>> 0;
    }

    _transform(bytes, encoding, callback) {
        this.size += bytes.length;
        if (this.size > this.maximum) {
            callback(packageError('插件实际解压体积与声明不符', 'package.limit'));
            return;
        }
        let remainder = this.remainder;
        for (const byte of bytes) {
            remainder = (remainder >>> 8) ^ CRC_TABLE[(remainder ^ byte) & 0xff];
        }
        this.remainder = remainder;
        callback(null, bytes);
    }
}

async function zipEnd(file, size) {
    const tailLength = Math.min(size, 22 + 0xffff);
    const tail = await readAt(file, size - tailLength, tailLength);
    for (let offset = tail.length - 22; offset >= 0; offset--) {
        if (
            tail.readUInt32LE(offset) === ZIP_END &&
            offset + 22 + tail.readUInt16LE(offset + 20) === tail.length
        ) {
            return { record: tail.subarray(offset), endOffset: size - tailLength + offset };
        }
    }
    throw packageError('插件 ZIP 缺少中央目录');
}

function zipName(bytes, flags) {
    if (!(flags & ZIP_UTF8) && bytes.some((byte) => byte >= 0x80)) {
        throw packageError('非 ASCII 的插件 ZIP 文件名必须使用 UTF-8', 'package.path');
    }
    return decodeUtf8(bytes);
}

function checkZipExtras(bytes) {
    for (let offset = 0; offset < bytes.length;) {
        if (offset + 4 > bytes.length) {
            throw packageError('插件 ZIP 扩展字段不完整');
        }
        const field = bytes.readUInt16LE(offset);
        const length = bytes.readUInt16LE(offset + 2);
        offset += 4 + length;
        if (offset > bytes.length) {
            throw packageError('插件 ZIP 扩展字段不完整');
        }
        // ZIP64 改写偏移与大小，ASi Unix 和带目标的 Unix 字段可以表示链接。
        if (field === 0x0001 || field === 0x756e || (field === 0x000d && length > 12)) {
            throw packageError('插件 ZIP 使用不支持的大文件或链接扩展', 'package.path');
        }
    }
}

/** 先读中央目录并校验目录项类型及总量，再按物理位置复核所有本地头。 */
async function readZip(file, size) {
    const { record, endOffset } = await zipEnd(file, size);
    const count = record.readUInt16LE(10);
    const length = record.readUInt32LE(12);
    const offset = record.readUInt32LE(16);
    if (
        record.readUInt32LE(4) !== 0 ||
        record.readUInt16LE(8) !== count ||
        count < 1 ||
        count > MAX_FILES ||
        length > 8 * 1024 * 1024 ||
        offset + length !== endOffset
    ) {
        throw packageError('不支持此插件 ZIP 的中央目录结构');
    }
    const directory = await readAt(file, offset, length);
    const entries = [];
    let cursor = 0;
    while (cursor < directory.length && entries.length < count) {
        const entry = zipCentralEntry(directory, cursor);
        cursor += entry.recordSize;
        entries.push(entry);
    }
    if (entries.length !== count || cursor !== directory.length) {
        throw packageError('插件 ZIP 中央目录不完整');
    }
    checkArchiveLayout(entries);
    entries.sort((left, right) => left.offset - right.offset);
    if (entries[0].offset !== 0) {
        throw packageError('插件 ZIP 含有未登记的数据');
    }
    for (let index = 0; index < entries.length; index++) {
        await checkLocalZipHeader(file, entries[index], entries[index + 1]?.offset ?? offset);
    }
    return entries;
}

function zipCentralEntry(directory, cursor) {
    if (cursor + 46 > directory.length || directory.readUInt32LE(cursor) !== ZIP_CENTRAL) {
        throw packageError('插件 ZIP 中央目录条目无效');
    }
    const header = directory.subarray(cursor, cursor + 46);
    const flags = header.readUInt16LE(8);
    const method = header.readUInt16LE(10);
    const lengths = header.readUInt16LE(28) + header.readUInt16LE(30) + header.readUInt16LE(32);
    const recordSize = 46 + lengths;
    const allowedFlags =
        ZIP_UTF8 | ZIP_HAS_DESCRIPTOR | (method === ZIP_DEFLATE ? ZIP_COMPRESSION_OPTIONS : 0);
    if (
        cursor + recordSize > directory.length ||
        header.readUInt16LE(34) !== 0 ||
        header.readUInt16LE(6) > 20 ||
        flags & ~allowedFlags ||
        (method !== 0 && method !== ZIP_DEFLATE)
    ) {
        throw packageError('不支持加密、分卷或此压缩方式的插件 ZIP');
    }
    const nameEnd = cursor + 46 + header.readUInt16LE(28);
    const rawName = directory.subarray(cursor + 46, nameEnd);
    checkZipExtras(directory.subarray(nameEnd, nameEnd + header.readUInt16LE(30)));
    const filename = zipName(rawName, flags);
    const isDirectory = filename.endsWith('/');
    const attributes = header.readUInt32LE(38);
    const unixType = (attributes >>> 16) & 0xf000;
    const isUnixDirectory = unixType === 0x4000;
    const isUnixFile = unixType === 0x8000;
    if (
        attributes & 0x400 ||
        (unixType !== 0 && !isUnixDirectory && !isUnixFile) ||
        (isUnixDirectory && !isDirectory) ||
        (isUnixFile && isDirectory) ||
        (attributes & 0x10 && !isDirectory)
    ) {
        throw packageError('插件 ZIP 包含链接、特殊文件或不一致的目录类型', 'package.path');
    }
    const unpackedSize = header.readUInt32LE(24);
    const packedSize = header.readUInt32LE(20);
    if (
        (isDirectory && unpackedSize !== 0) ||
        (method === 0 && packedSize !== unpackedSize) ||
        (method === ZIP_DEFLATE && packedSize === 0)
    ) {
        throw packageError('插件 ZIP 条目大小无效');
    }
    return {
        name: isDirectory ? filename.slice(0, -1) : filename,
        rawName,
        isDirectory,
        flags,
        method,
        size: unpackedSize,
        packedSize,
        checksum: header.readUInt32LE(16),
        offset: header.readUInt32LE(42),
        recordSize,
    };
}

async function checkLocalZipHeader(file, entry, boundary) {
    if (entry.offset + 30 > boundary) {
        throw packageError('插件 ZIP 条目位置重叠或不完整');
    }
    const header = await readAt(file, entry.offset, 30);
    const nameLength = header.readUInt16LE(26);
    const start = entry.offset + 30 + nameLength + header.readUInt16LE(28);
    const end = start + entry.packedSize;
    const hasDescriptor = Boolean(entry.flags & ZIP_HAS_DESCRIPTOR);
    const checksum = header.readUInt32LE(14);
    const packed = header.readUInt32LE(18);
    const unpacked = header.readUInt32LE(22);
    if (
        header.readUInt32LE(0) !== ZIP_LOCAL ||
        header.readUInt16LE(4) > 20 ||
        header.readUInt16LE(6) !== entry.flags ||
        header.readUInt16LE(8) !== entry.method ||
        nameLength !== entry.rawName.length ||
        end > boundary ||
        ((!hasDescriptor || checksum) && checksum !== entry.checksum) ||
        ((!hasDescriptor || packed) && packed !== entry.packedSize) ||
        ((!hasDescriptor || unpacked) && unpacked !== entry.size)
    ) {
        throw packageError('插件 ZIP 本地头与中央目录不一致');
    }
    const nameAndExtras = await readAt(file, entry.offset + 30, start - (entry.offset + 30));
    if (!nameAndExtras.subarray(0, nameLength).equals(entry.rawName)) {
        throw packageError('插件 ZIP 本地文件名与中央目录不一致');
    }
    checkZipExtras(nameAndExtras.subarray(nameLength));
    const remaining = boundary - end;
    if (hasDescriptor) {
        await checkZipDescriptor(file, entry, end, remaining);
    } else if (remaining !== 0) {
        throw packageError('插件 ZIP 含有未登记的数据');
    }
    entry.start = start;
}

async function checkZipDescriptor(file, entry, offset, length) {
    if (length !== 12 && length !== 16) {
        throw packageError('插件 ZIP 数据描述符大小无效');
    }
    let descriptor = await readAt(file, offset, length);
    if (length === 16) {
        if (descriptor.readUInt32LE(0) !== ZIP_DESCRIPTOR) {
            throw packageError('插件 ZIP 数据描述符无效');
        }
        descriptor = descriptor.subarray(4);
    }
    if (
        descriptor.readUInt32LE(0) !== entry.checksum ||
        descriptor.readUInt32LE(4) !== entry.packedSize ||
        descriptor.readUInt32LE(8) !== entry.size
    ) {
        throw packageError('插件 ZIP 数据描述符与中央目录不一致');
    }
}

function tarText(bytes) {
    const terminator = bytes.indexOf(0);
    return decodeUtf8(terminator === -1 ? bytes : bytes.subarray(0, terminator));
}

/** 只接收旧打包工具的无压缩 USTAR 普通文件和结束块。 */
async function readTar(file, size) {
    if (size < TAR_BLOCK * 3 || size % TAR_BLOCK !== 0) {
        throw packageError('旧插件 TAR 内容不完整');
    }
    let offset = 0;
    const entries = [];
    while (offset + TAR_BLOCK <= size) {
        const header = await readAt(file, offset, TAR_BLOCK);
        if (header.every((byte) => byte === 0)) {
            break;
        }
        if (
            entries.length >= MAX_FILES ||
            header.toString('ascii', 257, 265) !== 'ustar\0' + '00' ||
            (header[156] !== 48 && header[156] !== 0) ||
            header.subarray(157, 257).some(Boolean)
        ) {
            throw packageError('旧插件 TAR 含有不支持的条目');
        }
        const checksum = header.toString('latin1', 148, 156);
        const fileSize = header.toString('latin1', 124, 136);
        if (!/^[0-7]{6}\0 $/.test(checksum) || !/^[0-7]{11}\0$/.test(fileSize)) {
            throw packageError('旧插件 TAR 条目头无效');
        }
        const computed = header.reduce(
            (sum, byte, index) => sum + (index >= 148 && index < 156 ? 32 : byte),
            0,
        );
        if (computed !== parseInt(checksum, 8)) {
            throw packageError('旧插件 TAR 条目头校验失败');
        }
        const filename = tarText(header.subarray(0, 100));
        const prefix = tarText(header.subarray(345, 500));
        const name = prefix ? prefix + '/' + filename : filename;
        const start = offset + TAR_BLOCK;
        const length = parseInt(fileSize, 8);
        offset = start + Math.ceil(length / TAR_BLOCK) * TAR_BLOCK;
        if (offset > size) {
            throw packageError('旧插件 TAR 文件不完整');
        }
        entries.push({ name, size: length, packedSize: length, start, isDirectory: false });
    }
    if (!entries.length || size - offset < TAR_BLOCK * 2) {
        throw packageError('旧插件 TAR 缺少结束块');
    }
    for await (const bytes of readRange(file, offset, size - offset)) {
        if (bytes.some(Boolean)) {
            throw packageError('旧插件 TAR 含有未登记的数据');
        }
    }
    checkArchiveLayout(entries);
    return entries;
}

async function readArchive(file, size, allowLegacy) {
    if (size < 22 || size > MAX_ARCHIVE) {
        throw packageError('插件包大小超出限制或文件不完整', 'package.limit');
    }
    const head = await readAt(file, 0, Math.min(size, TAR_BLOCK));
    if (head.readUInt32LE(0) === ZIP_LOCAL) {
        return { format: 'zip', entries: await readZip(file, size) };
    }
    if (allowLegacy && head.subarray(257, 263).toString('ascii') === 'ustar\0') {
        return { format: 'legacy-tar', entries: await readTar(file, size) };
    }
    throw packageError('不支持此插件包格式', 'package.format');
}

function discardBytes() {
    return new Writable({
        write(bytes, encoding, callback) {
            callback();
        },
    });
}

/** 分块读取压缩数据并限制实际输出，校验完成后由上层接管暂存目录。 */
async function extractArchiveEntry(archive, entry, destination) {
    const target = path.join(destination, entry.name);
    if (entry.isDirectory) {
        await fsp.mkdir(target, { recursive: true });
    } else {
        await fsp.mkdir(path.dirname(target), { recursive: true });
    }
    const output = entry.isDirectory
        ? discardBytes()
        : fs.createWriteStream(target, { flags: 'wx', mode: 0o600 });
    const input = Readable.from(readRange(archive, entry.start, entry.packedSize), { objectMode: false });
    const meter = new ArchiveFileMeter(entry.size);
    if (entry.method === ZIP_DEFLATE) {
        const inflate = createInflateRaw();
        await pipeline(input, inflate, meter, output);
        if (inflate.bytesWritten !== entry.packedSize) {
            throw packageError('插件 ZIP 的压缩流包含未登记的数据');
        }
    } else {
        await pipeline(input, meter, output);
    }
    if (meter.size !== entry.size || (entry.checksum !== undefined && meter.checksum !== entry.checksum)) {
        throw packageError('插件包文件的大小或 CRC 校验失败', 'package.integrity');
    }
}

async function writeAt(file, bytes, position) {
    let offset = 0;
    while (offset < bytes.length) {
        const { bytesWritten } = await file.write(bytes, offset, bytes.length - offset, position + offset);
        if (!bytesWritten) {
            throw packageError('写入插件包失败');
        }
        offset += bytesWritten;
    }
}

function zipNameHeader(signature, length, name) {
    const header = Buffer.alloc(length);
    header.writeUInt32LE(signature);
    name.copy(header, length - name.length);
    return header;
}

/** 用固定时间、权限和排序写出可复现的标准 ZIP，每个文件独立 Deflate。 */
async function writeZip(file, directory, names) {
    const records = [];
    let offset = 0;
    for (const name of names.sort()) {
        const nameBytes = Buffer.from(name, 'utf8');
        const result = await writeZipEntry(file, path.join(directory, name), nameBytes, offset);
        offset = result.end;
        records.push(result.record);
    }
    const centralDirectory = Buffer.concat(records);
    await writeAt(file, centralDirectory, offset);
    const footer = Buffer.alloc(22);
    footer.writeUInt32LE(ZIP_END);
    footer.writeUInt16LE(records.length, 8);
    footer.writeUInt16LE(records.length, 10);
    footer.writeUInt32LE(centralDirectory.length, 12);
    footer.writeUInt32LE(offset, 16);
    await writeAt(file, footer, offset + centralDirectory.length);
}

async function writeZipEntry(archive, filename, name, offset) {
    const { file, stat } = await openRegularFile(filename);
    try {
        const flags = ZIP_UTF8 | ZIP_HAS_DESCRIPTOR;
        const local = zipNameHeader(ZIP_LOCAL, name.length + 30, name);
        local.writeUInt16LE(20, 4);
        local.writeUInt16LE(flags, 6);
        local.writeUInt16LE(ZIP_DEFLATE, 8);
        local.writeUInt16LE(33, 12);
        local.writeUInt16LE(name.length, 26);
        await writeAt(archive, local, offset);

        const start = offset + local.length;
        let end = start;
        const meter = new ArchiveFileMeter(Math.min(stat.size, MAX_FILE));
        await pipeline(
            Readable.from(readRange(file, 0, stat.size), { objectMode: false }),
            meter,
            createDeflateRaw({ level: 6 }),
            new Writable({
                write(bytes, encoding, callback) {
                    writeAt(archive, bytes, end).then(() => {
                        end += bytes.length;
                        callback();
                    }, callback);
                },
            }),
        );
        await assertFileUnchanged(file, stat);
        const compressedSize = end - start;
        const descriptor = Buffer.alloc(16);
        descriptor.writeUInt32LE(ZIP_DESCRIPTOR);
        descriptor.writeUInt32LE(meter.checksum, 4);
        descriptor.writeUInt32LE(compressedSize, 8);
        descriptor.writeUInt32LE(meter.size, 12);
        await writeAt(archive, descriptor, end);

        const record = zipNameHeader(ZIP_CENTRAL, name.length + 46, name);
        record.writeUInt16LE(0x0314, 4);
        record.writeUInt16LE(20, 6);
        record.writeUInt16LE(flags, 8);
        record.writeUInt16LE(ZIP_DEFLATE, 10);
        record.writeUInt16LE(33, 14);
        descriptor.copy(record, 16, 4);
        record.writeUInt16LE(name.length, 28);
        record.writeUInt32LE((0o100644 << 16) >>> 0, 38);
        record.writeUInt32LE(offset, 42);
        return { record, end: end + descriptor.length };
    } finally {
        await file.close();
    }
}

module.exports = {
    MAX_FILE,
    MAX_TOTAL,
    MAX_ARCHIVE,
    MAX_FILES,
    MAX_MANIFEST,
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
};
