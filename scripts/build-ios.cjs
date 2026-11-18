const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { buildVersion, packageIdentity } = require('./release-version.cjs');
const root = path.resolve(__dirname, '..');
process.chdir(root);
const simulator = process.argv.includes('--simulator');
const prepareOnly = process.argv.includes('--prepare-only');
const qtVersion = '6.12.0';
const kit =
    process.env.RHINE_IOS_QT ||
    path.join(os.homedir(), 'Qt', qtVersion, simulator ? 'ios_simulator_arm64' : 'ios_device');
const dependencies = path.resolve('output/dependencies/node-mobile');
const resources = path.resolve('output/ios-resources');
const bundle = path.resolve('output/ios-bridge-build');
const build = path.resolve(simulator ? 'output/ios-simulator-build' : 'output/ios-device-build');
const config = 'Release';
const version = buildVersion();
const release = require('../vendor/nodejs-mobile/source.json');

/** 串行准备资源、生成 Xcode 工程和编译；iOS 不写入桌面构建目录。 */
function run(command, args, options = {}) {
    const result = spawnSync(command, args, { stdio: 'inherit', ...options });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw new Error(`${command} exited with ${result.status}`);
    }
}

function prepareNodeMobile() {
    const archive = path.join(dependencies, 'nodejs-mobile-ios.zip');
    fs.mkdirSync(dependencies, { recursive: true });
    if (!fs.existsSync(archive)) {
        run('curl', ['-L', '--fail', '--retry', '3', release.download, '-o', archive]);
    }
    const hash = createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    if (hash !== release.sha256) {
        throw new Error('NodeMobile archive checksum mismatch; remove the archive and retry');
    }
    run('unzip', ['-q', '-o', archive, '-d', dependencies]);
}

function prepareResources() {
    run(process.execPath, ['scripts/build.cjs', '--resources-only']);
    run(process.execPath, ['scripts/bundle-bridge.cjs', 'output/resources/MusicBridge', bundle], {
        env: { ...process.env, RHINE_IOS_BUILD: '1' },
    });
    const icons = path.resolve('output/ios-icons');
    fs.mkdirSync(icons, { recursive: true });
    for (const size of [76, 120, 152, 167, 180]) {
        run('sips', [
            '-z',
            String(size),
            String(size),
            'Assets/icons/icon-1024.png',
            '--out',
            path.join(icons, `app-icon-${size}.png`),
        ]);
    }
    // 沿用桌面资源白名单和许可证闭包，再用 iOS 专用 bundle 替换协议层。
    fs.rmSync(resources, { recursive: true, force: true });
    run(process.execPath, ['scripts/package-resources.cjs', resources]);
    const bridge = path.join(resources, 'MusicBridge');
    fs.rmSync(path.join(bridge, 'node'), { force: true });
    for (const name of ['worker.cjs']) {
        fs.copyFileSync(path.join(bundle, 'MusicBridge', name), path.join(bridge, name));
    }
    fs.copyFileSync('MusicBridge/ios-runtime.cjs', path.join(bridge, 'ios-runtime.cjs'));
    fs.cpSync('licenses/nodejs-mobile', path.join(resources, 'third-party/nodejs-mobile'), {
        recursive: true,
    });
    fs.copyFileSync(
        'vendor/nodejs-mobile/source.json',
        path.join(resources, 'third-party/nodejs-mobile/source.json'),
    );
    fs.copyFileSync('licenses/nodejs-mobile/LICENSE', path.join(bridge, 'NODE-LICENSE'));
    fs.cpSync('licenses/Qt', path.join(resources, 'Qt-Licenses'), { recursive: true });
    fs.copyFileSync('LICENSE', path.join(resources, 'LICENSE'));
    fs.cpSync('licenses/FFmpeg', path.join(resources, 'third-party/FFmpeg'), { recursive: true });
    fs.copyFileSync('vendor/ffmpeg/source.json', path.join(resources, 'third-party/FFmpeg/source.json'));
    // iOS 专用 fetch 及其新增依赖保留版本、来源和原始许可证。
    const fetchPackages = [
        'node-fetch',
        'node-fetch/node_modules/tr46',
        'node-fetch/node_modules/webidl-conversions',
        'node-fetch/node_modules/whatwg-url',
    ];
    for (const name of fetchPackages) {
        const source = path.join('output/resources/MusicBridge/node_modules', name);
        const manifest = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
        const destination = path.join(
            resources,
            'third-party/ios-fetch',
            `${manifest.name}-${manifest.version}`,
        );
        fs.mkdirSync(destination, { recursive: true });
        for (const file of fs.readdirSync(source)) {
            if (file === 'package.json' || /^(?:license|copying|readme)(?:\.|$)/i.test(file)) {
                fs.copyFileSync(path.join(source, file), path.join(destination, file));
            }
        }
    }
    fs.copyFileSync('vendor/qrcodegen/qrcodegen.hpp', path.join(resources, 'qrcodegen-LICENSE.hpp'));
    for (const name of ['taglib', 'utfcpp']) {
        fs.cpSync(path.join('vendor', name), path.join(resources, 'third-party', name), {
            recursive: true,
            filter: (source) => !source.endsWith('.tar.gz'),
        });
    }
}

prepareNodeMobile();
prepareResources();
const ffmpeg = simulator ? path.resolve('output/dependencies/ffmpeg-simulator/frameworks') : '';
if (simulator && !prepareOnly) {
    run(process.execPath, ['scripts/prepare-ios-ffmpeg.cjs']);
    // 旧 XCFramework 的展开结果会抢先进入 Xcode 的搜索路径，切换库后必须移除。
    for (const name of ['avcodec', 'avformat', 'avutil', 'swresample', 'swscale']) {
        fs.rmSync(path.join(build, 'Release', `lib${name}.framework`), { recursive: true, force: true });
    }
}
if (prepareOnly) {
    process.exit(0);
}
// 旧资源目录会让系统把 iOS 应用误识别为旧式 Bundle，增量构建也必须清理。
fs.rmSync(path.join(build, 'Release/RhineMusicDatabase.app/resources'), { recursive: true, force: true });
// 删除旧归属副本，避免依赖布局变化后增量打包残留已移除的目录。
fs.rmSync(path.join(build, 'Release/RhineMusicDatabase.app/RhineAssets/third-party/ios-fetch'), {
    recursive: true,
    force: true,
});
run(path.join(kit, 'bin/qt-cmake'), [
    '-S',
    '.',
    '-B',
    build,
    '-G',
    'Xcode',
    `-DCMAKE_OSX_SYSROOT=${simulator ? 'iphonesimulator' : 'iphoneos'}`,
    '-DCMAKE_OSX_ARCHITECTURES=arm64',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',
    '-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO',
    `-DRHINE_NODE_MOBILE_ROOT=${dependencies}`,
    `-DRHINE_IOS_RESOURCES=${resources}`,
    `-DRHINE_IOS_FFMPEG_ROOT=${ffmpeg}`,
    '-DRHINE_PACKAGE_APP=OFF',
    `-DRHINE_VERSION=${version.version}`,
    `-DRHINE_RELEASE_BUILD=${version.release ? 'ON' : 'OFF'}`,
]);
run('cmake', [
    '--build',
    build,
    '--config',
    config,
    '--target',
    'RhineMusicDatabase',
    '--',
    '-jobs',
    process.env.RHINE_BUILD_JOBS || '4',
    'CODE_SIGNING_ALLOWED=NO',
]);
const app = path.join(build, 'Release', 'RhineMusicDatabase.app');
if (!fs.existsSync(app)) {
    throw new Error(`Built application missing: ${app}`);
}
run(process.env.PYTHON || 'python3', ['scripts/audit-ios.py', app, ...(simulator ? ['--simulator'] : [])]);
if (simulator) {
    run('codesign', ['--force', '--deep', '--sign', '-', app]);
    console.log(`Simulator app: ${app}`);
} else {
    const staging = path.resolve('output/ios-unsigned');
    fs.rmSync(staging, { recursive: true, force: true });
    fs.mkdirSync(path.join(staging, 'Payload'), { recursive: true });
    fs.cpSync(app, path.join(staging, 'Payload/RhineMusicDatabase.app'), { recursive: true });
    const ipa = path.resolve('output/RhineMusicDatabase-ios-unsigned.ipa');
    fs.rmSync(ipa, { force: true });
    run('ditto', ['-c', '-k', '--norsrc', '--noextattr', '--noqtn', '--keepParent', 'Payload', ipa], {
        cwd: staging,
    });
    fs.copyFileSync(
        ipa,
        path.resolve(`output/RhineMusicDatabase-${packageIdentity(version)}-ios-unsigned.ipa`),
    );
    console.log(`Unsigned IPA (requires signing before installation): ${ipa}`);
}
