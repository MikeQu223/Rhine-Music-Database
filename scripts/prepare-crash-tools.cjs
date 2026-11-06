// 官方工具只在构建时下载，版本与 SHA-256 锁定；运行时不联网、不上传报告。
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');
const manifest = require('./crash-tools.json');
const root = path.resolve(__dirname, '..');
const directory = path.join(root, 'output/crash-tools');

/** 下载并验证发布归档，再提取其中的工具和原始许可证。 */
async function prepareTool(repo, version, name, checksum, target) {
    const extension = process.platform === 'win32' ? 'zip' : 'tar.xz';
    const archive = `${name}-${target}.${extension}`;
    const destination = path.join(directory, `${name}-${version}-${target}`);
    const stamp = path.join(destination, '.verified');
    if (fs.existsSync(stamp) && fs.readFileSync(stamp, 'utf8') === checksum) {
        return;
    }
    const response = await fetch(`https://github.com/${repo}/releases/download/v${version}/${archive}`);
    if (!response.ok) {
        throw new Error(`Cannot download ${archive}: ${response.status}`);
    }
    const bytes = Buffer.from(await response.arrayBuffer());
    if (createHash('sha256').update(bytes).digest('hex') !== checksum) {
        throw new Error(`Checksum mismatch: ${archive}`);
    }
    fs.mkdirSync(destination, { recursive: true });
    const archivePath = path.join(directory, archive);
    fs.writeFileSync(archivePath, bytes);
    execFileSync('tar', ['-xf', archivePath, '-C', destination], { stdio: 'inherit' });
    fs.writeFileSync(stamp, checksum);
}

/** 准备锁定的 Crashpad 源码及离线解析工具，供 CMake 和应用打包共同使用。 */
async function prepareCrashTools() {
    const platform = manifest.platforms[`${process.platform}-${process.arch}`];
    if (!platform) {
        throw new Error(`Crash tools unavailable for ${process.platform}-${process.arch}`);
    }
    fs.mkdirSync(directory, { recursive: true });
    await prepareTool(
        'rust-minidump/rust-minidump',
        manifest.stackwalkVersion,
        'minidump-stackwalk',
        platform.stackwalkSha256,
        platform.target,
    );
    await prepareTool(
        'mozilla/dump_syms',
        manifest.symbolsVersion,
        'dump_syms',
        platform.symbolsSha256,
        platform.target,
    );
    const source = path.join(root, 'output/crashpad-source');
    if (!fs.existsSync(path.join(source, '.git'))) {
        execFileSync('git', ['clone', '--no-checkout', 'https://github.com/getsentry/crashpad.git', source], {
            stdio: 'inherit',
        });
    }
    const revision = execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    if (revision !== manifest.crashpadRevision || !fs.existsSync(path.join(source, 'CMakeLists.txt'))) {
        execFileSync('git', ['-C', source, 'fetch', 'origin', manifest.crashpadRevision], {
            stdio: 'inherit',
        });
        execFileSync('git', ['-C', source, 'checkout', '--detach', manifest.crashpadRevision], {
            stdio: 'inherit',
        });
    }
    execFileSync(
        'git',
        [
            '-C',
            source,
            'submodule',
            'update',
            '--init',
            '--recursive',
            '--',
            'third_party/mini_chromium/mini_chromium',
            'third_party/zlib/zlib',
        ],
        { stdio: 'inherit' },
    );
}

if (require.main === module) {
    prepareCrashTools().catch((error) => {
        console.error(error);
        process.exitCode = 1;
    });
}
module.exports = { prepareCrashTools, directory, manifest };
