// Qt 的部分 iOS kit 只附带 Intel 模拟器 FFmpeg；在独立目录补齐同版本 arm64 库。
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync, execFileSync } = require('node:child_process');
const source = require('../vendor/ffmpeg/source.json');
const root = path.resolve(__dirname, '..');
const directory = path.join(root, 'output/dependencies/ffmpeg-simulator');
const archive = path.join(directory, `ffmpeg-${source.version}.tar.xz`);
const install = path.join(directory, 'install');
const frameworks = path.join(directory, 'frameworks');

function run(command, args, cwd = directory) {
    const result = spawnSync(command, args, { cwd, stdio: 'inherit' });
    if (result.error || result.status !== 0) {
        throw result.error || new Error(`${command} exited with ${result.status}`);
    }
}

/** 交叉编译全部解码能力，保持与设备相同的 FFmpeg ABI；禁用未使用的录制和命令行工具。 */
function main() {
    fs.mkdirSync(directory, { recursive: true });
    if (!fs.existsSync(archive)) {
        run('curl', ['-L', '--fail', '--retry', '3', source.download, '-o', archive]);
    }
    const hash = createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    if (hash !== source.sha256) {
        throw new Error('FFmpeg source checksum mismatch');
    }
    const buildKey = hash + '\n' + createHash('sha256').update(fs.readFileSync(__filename)).digest('hex');
    const stamp = path.join(frameworks, '.source.sha256');
    if (fs.existsSync(stamp) && fs.readFileSync(stamp, 'utf8') === buildKey) {
        return;
    }
    run('tar', ['-xf', archive]);
    const build = path.join(directory, 'build');
    fs.mkdirSync(build, { recursive: true });
    const sdk = execFileSync('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-path'], {
        encoding: 'utf8',
    }).trim();
    run(
        path.join(directory, `ffmpeg-${source.version}/configure`),
        [
            `--prefix=${install}`,
            `--sysroot=${sdk}`,
            '--arch=arm64',
            '--target-os=darwin',
            '--cc=xcrun --sdk iphonesimulator clang',
            '--cxx=xcrun --sdk iphonesimulator clang++',
            '--enable-cross-compile',
            '--enable-shared',
            '--disable-static',
            '--disable-programs',
            '--disable-doc',
            '--disable-debug',
            '--disable-autodetect',
            '--disable-audiotoolbox',
            '--enable-videotoolbox',
            '--disable-encoders',
            '--disable-muxers',
            '--disable-avdevice',
            '--disable-avfilter',
            '--extra-cflags=-mios-simulator-version-min=18.0',
            '--extra-ldflags=-mios-simulator-version-min=18.0',
            '--install-name-dir=@rpath',
        ],
        build,
    );
    run('make', ['-j', process.env.RHINE_BUILD_JOBS || '4'], build);
    run('make', ['install'], build);
    fs.mkdirSync(frameworks, { recursive: true });
    const names = ['avcodec', 'avformat', 'avutil', 'swresample', 'swscale'];
    for (const name of names) {
        const frameworkName = `lib${name}`;
        const framework = path.join(frameworks, frameworkName + '.framework');
        fs.mkdirSync(framework, { recursive: true });
        const binary = path.join(framework, frameworkName);
        fs.copyFileSync(path.join(install, 'lib', frameworkName + '.dylib'), binary);
        run('install_name_tool', ['-id', `@rpath/${frameworkName}.framework/${frameworkName}`, binary]);
        const dependencies = execFileSync('otool', ['-L', binary], { encoding: 'utf8' }).split('\n').slice(1);
        for (const dependency of dependencies) {
            const library = dependency.trim().split(' (')[0];
            for (const target of names) {
                if (path.basename(library).match(new RegExp(`^lib${target}(?:\\.[0-9]+)*\\.dylib$`))) {
                    run('install_name_tool', [
                        '-change',
                        library,
                        `@rpath/lib${target}.framework/lib${target}`,
                        binary,
                    ]);
                }
            }
        }
        fs.writeFileSync(
            path.join(framework, 'Info.plist'),
            `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${frameworkName}</string>
<key>CFBundleIdentifier</key><string>rhine.music.ffmpeg.${name}</string>
<key>CFBundleName</key><string>${frameworkName}</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>${source.version}</string>
<key>CFBundleShortVersionString</key><string>${source.version}</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
</dict></plist>\n`,
        );
    }
    fs.writeFileSync(stamp, buildKey);
}
main();
