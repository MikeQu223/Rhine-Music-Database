// Android（arm64-v8a）打包：准备资源与 Node 运行时 → CMake 配置 → Gradle 出包 → 用工作区内的
// 调试密钥重签。产物落在 output/，全程不写工作区以外的路径（Gradle/Android 的用户目录都改指到
// output/android-work 下）。
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { buildVersion, packageIdentity } = require('./release-version.cjs');
const toolchain = require('./android-toolchain.cjs');

const root = path.resolve(__dirname, '..');
process.chdir(root);

const prepareOnly = process.argv.includes('--prepare-only');
const unsigned = process.argv.includes('--unsigned');
const abi = 'arm64-v8a';
const buildType = 'Release';

const work = path.resolve('output/android-work');
const dependencies = path.resolve('output/dependencies/node-mobile');
const resources = path.resolve('output/android-resources');
const bridgeBundle = path.resolve('output/android-bridge-build');
const build = path.resolve('output/android-build');
const sdk = toolchain.sdkRoot();
const jdk = toolchain.jdkHome(work);
// kit 的查找顺序：显式覆盖 → 仓库里构建出来的那份（npm run build:qt:android）→ Qt 安装器默认位置。
// 这样"自己编 Qt"和"装官方 Android 组件"两条路的产物都能被自动找到。
const kit =
    process.env.RHINE_ANDROID_QT ||
    (fs.existsSync(path.resolve('output/dependencies/qt-android/bin/qt-cmake'))
        ? path.resolve('output/dependencies/qt-android')
        : path.join(os.homedir(), 'Qt', '6.12.0', 'android_arm64_v8a'));
const androidUserHome = path.join(work, 'android-user');
const keystore = path.join(work, 'debug.keystore');
const nodeMobile = require('../vendor/nodejs-mobile/android-source.json');
const version = buildVersion();

// NDK 必须落在 SDK 的 ndk/ 目录下，AGP 才按版本号找得到。
const ndk = toolchain.ndkRoot(sdk);

/** 串行执行；任何一步非零退出都立刻中断，避免把半成品签成"能装但会崩"的包。 */
function run(command, args, options = {}) {
    const result = spawnSync(command, args, { stdio: 'inherit', ...options });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw new Error(`${command} exited with ${result.status}`);
    }
}

/** 子进程统一带上工作区内的用户目录：Gradle 缓存、AGP 的调试密钥都不能落在 $HOME。 */
function toolEnvironment(extra = {}) {
    return {
        ...process.env,
        ANDROID_SDK_ROOT: sdk,
        ANDROID_HOME: sdk,
        ANDROID_NDK_ROOT: ndk,
        ANDROID_USER_HOME: androidUserHome,
        JAVA_HOME: jdk,
        PATH: `${path.join(jdk, 'bin')}:${process.env.PATH}`,
        // Gradle 缓存默认用 ~/.gradle：搬进工作区等于让 wrapper 发行包与 AGP 依赖重下几百 MB。
        // 需要完全隔离构建时，把 RHINE_GRADLE_HOME 指到工作区内的目录。
        ...(process.env.RHINE_GRADLE_HOME ? { GRADLE_USER_HOME: process.env.RHINE_GRADLE_HOME } : {}),
        ...extra,
    };
}

/** nodejs-mobile 的 Android 预编译包：libnode.so 按 ABI 分目录，sha256 与 iOS 一样钉死。 */
function prepareNodeMobile() {
    const archive = path.join(dependencies, 'nodejs-mobile-android.zip');
    fs.mkdirSync(dependencies, { recursive: true });
    if (fs.existsSync(archive) && createHash(archive) !== nodeMobile.sha256) {
        // 连接中途被掐断时 curl 仍可能返回 0，只留下一个比预期小得多的包；留着只会一直校验失败。
        console.log(`  nodejs-mobile: 现有压缩包校验不符（${fs.statSync(archive).size} 字节），重新下载`);
        fs.rmSync(archive, { force: true });
    }
    if (!fs.existsSync(archive)) {
        run('curl', [
            '-L',
            '--fail',
            '--retry',
            '3',
            '--retry-all-errors',
            nodeMobile.download,
            '-o',
            archive,
        ]);
    }
    const actual = createHash(archive);
    if (actual !== nodeMobile.sha256) {
        const size = fs.statSync(archive).size;
        // 删掉半成品，下一次重跑会重新下载，而不是卡在同一个坏文件上。
        fs.rmSync(archive, { force: true });
        throw new Error(
            `nodejs-mobile Android checksum mismatch (expected ${nodeMobile.sha256}, got ${actual}, ${size} bytes). ` +
                'The partial archive was removed; re-run to download it again.',
        );
    }
    const library = path.join(dependencies, 'bin', abi, 'libnode.so');
    if (!fs.existsSync(library)) {
        run('unzip', ['-q', '-o', archive, '-d', dependencies]);
    }
    if (!fs.existsSync(library)) {
        throw new Error(`libnode.so missing after extraction: ${library}`);
    }
    return library;
}

function createHash(file) {
    const { createHash: digest } = require('node:crypto');
    return digest('sha256').update(fs.readFileSync(file)).digest('hex');
}

function prepareResources() {
    // RHINE_ANDROID_BUILD=1 让 build.cjs 跳过"独立 node 可执行文件"那一段：
    // Android 用的是 libnode.so，包里不需要也放不进 node 二进制。
    run(process.execPath, ['scripts/build.cjs', '--resources-only'], {
        env: { ...process.env, RHINE_ANDROID_BUILD: '1' },
    });
    // 与 iOS 同一套 Node 18 运行时，所以用同一份 bundle（fetch 补丁 + isUtf8 兼容）。
    run(process.execPath, ['scripts/bundle-bridge.cjs', 'output/resources/MusicBridge', bridgeBundle], {
        env: { ...process.env, RHINE_ANDROID_BUILD: '1' },
    });
    // 白名单与许可证闭包复用桌面脚本；它读 output/bridge-build 里的上游数据目录，
    // 该目录缺失时先生成一次（不改变内容，只是让冷仓库也能直接出包）。
    if (!fs.existsSync(path.resolve('output/bridge-build/MusicBridge/worker.cjs'))) {
        run(process.execPath, ['scripts/bundle-bridge.cjs']);
    }
    fs.rmSync(resources, { recursive: true, force: true });
    // 同一个开关告诉打包脚本：没有 node 可执行文件，Node 许可证从 licenses/ 取。
    run(process.execPath, ['scripts/package-resources.cjs', resources], {
        env: { ...process.env, RHINE_ANDROID_BUILD: '1' },
    });
    const bridge = path.join(resources, 'MusicBridge');
    // package-resources 在 Android 下已经不复制 node 可执行文件；这里再删一刀，
    // 防的是将来有人把那个分支改回去——APK 里的 node 既不能执行也没人调用。
    fs.rmSync(path.join(bridge, 'node'), { force: true });
    for (const name of ['worker.cjs', 'xhr-sync-worker.js']) {
        fs.copyFileSync(path.join(bridgeBundle, 'MusicBridge', name), path.join(bridge, name));
    }
    // 进程内运行时的 IPC 与 iOS 完全一致，直接复用同一份脚本（见 BridgeProcessAndroid.cpp）。
    // 注意：android-web-apis.cjs 不需要复制——它在 bundle 阶段就被 esbuild 内联进 worker.cjs。
    fs.copyFileSync('MusicBridge/ios-runtime.cjs', path.join(bridge, 'ios-runtime.cjs'));
    fs.copyFileSync('licenses/nodejs-mobile/LICENSE', path.join(bridge, 'NODE-LICENSE'));
    fs.cpSync('licenses/nodejs-mobile', path.join(resources, 'third-party/nodejs-mobile'), {
        recursive: true,
    });
    fs.copyFileSync(
        'vendor/nodejs-mobile/android-source.json',
        path.join(resources, 'third-party/nodejs-mobile/android-source.json'),
    );
    fs.cpSync('licenses/Qt', path.join(resources, 'Qt-Licenses'), { recursive: true });
    fs.copyFileSync('LICENSE', path.join(resources, 'LICENSE'));
    fs.copyFileSync('vendor/qrcodegen/qrcodegen.hpp', path.join(resources, 'qrcodegen-LICENSE.hpp'));
    for (const name of ['taglib', 'utfcpp']) {
        fs.cpSync(path.join('vendor', name), path.join(resources, 'third-party', name), {
            recursive: true,
            filter: (source) => !source.endsWith('.tar.gz'),
        });
    }
}

/** 调试签名用的密钥只生成一次，落在工作区里：与 AGP 自动生成到 ~/.android 的那份等价，
 *  但位置可控、可随产物一起审计。 */
function ensureKeystore() {
    if (fs.existsSync(keystore)) {
        return;
    }
    fs.mkdirSync(path.dirname(keystore), { recursive: true });
    run(path.join(jdk, 'bin', 'keytool'), [
        '-genkeypair',
        '-keystore',
        keystore,
        '-storepass',
        'android',
        '-keypass',
        'android',
        '-alias',
        'rhine-debug',
        '-keyalg',
        'RSA',
        '-keysize',
        '2048',
        '-validity',
        '10000',
        '-dname',
        'CN=RHINE MUSIC DATABASE Debug, OU=Android, O=Rhine, C=CN',
    ]);
}

function findBuildTools() {
    const found = toolchain.buildToolsRoot(sdk);
    if (!found) {
        throw new Error(`No Android build-tools under ${path.join(sdk, 'build-tools')}`);
    }
    return found;
}

/** Gradle 产出的 APK 位置随 Qt 版本变化，用递归查找而不是写死路径。 */
function findApk(directory) {
    const found = [];
    const walk = (current) => {
        for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
            const full = path.join(current, entry.name);
            if (entry.isDirectory()) {
                walk(full);
            } else if (entry.name.endsWith('.apk')) {
                found.push(full);
            }
        }
    };
    if (fs.existsSync(directory)) {
        walk(directory);
    }
    // release 变体优先：debug 变体带 AGP 自己生成的调试签名与 debuggable 标记，
    // 混进产物会让人以为包是发布配置打的。
    const rank = (file) => (/release/i.test(file) ? 0 : 1);
    return found.sort((a, b) => rank(a) - rank(b) || fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
}

/** `--check`：只体检不出包。缺 Qt Android kit 时这是唯一能在几秒内跑完的入口。 */
function reportPrerequisites() {
    const rows = [];
    const add = (label, value, ok) => rows.push({ label, value, ok });
    add('Qt Android kit', kit, fs.existsSync(path.join(kit, 'bin', 'qt-cmake')));
    add('Android SDK', sdk, fs.existsSync(sdk));
    add(
        'platform android-36',
        path.join(sdk, 'platforms', 'android-36'),
        fs.existsSync(path.join(sdk, 'platforms', 'android-36')),
    );
    let buildToolsPath = '';
    try {
        buildToolsPath = findBuildTools();
    } catch {
        buildToolsPath = '(未找到)';
    }
    add('build-tools', buildToolsPath, fs.existsSync(buildToolsPath));
    add('NDK', ndk, fs.existsSync(path.join(ndk, 'source.properties')));
    add('JDK', jdk, fs.existsSync(path.join(jdk, 'bin', 'java')));
    const nodeLibrary = path.join(dependencies, 'bin', abi, 'libnode.so');
    add('libnode.so', nodeLibrary, fs.existsSync(nodeLibrary));
    console.log('Android 构建前置条件（缺失项用 MISS 标出；构建脚本会自行下载 libnode）：');
    for (const row of rows) {
        console.log(`  ${row.ok ? ' ok ' : 'MISS'}  ${row.label}: ${row.value}`);
    }
    const missing = rows.filter((row) => !row.ok && row.label !== 'libnode.so');
    if (missing.length > 0) {
        console.log(`\n还缺 ${missing.length} 项依赖；完整说明见 docs/ANDROID.md。`);
    }
}

if (process.argv.includes('--check')) {
    reportPrerequisites();
    process.exit(0);
}

// 前置检查先做：缺 Qt kit 时不该先把几十 MB 资源重新打一遍再失败。
const qtCmake = path.join(kit, 'bin', 'qt-cmake');
if (!fs.existsSync(qtCmake)) {
    throw new Error(
        `Qt for Android kit not found: ${qtCmake}\n` +
            'Two ways to get one:\n' +
            '  · build it from the vendored sources: npm run build:qt:android' +
            '  (installs to output/dependencies/qt-android)\n' +
            '  · or install the "Android arm64-v8a" component from the Qt online installer, then set' +
            ' RHINE_ANDROID_QT to that prefix.',
    );
}
if (!ndk) {
    throw new Error(
        `No Android NDK found under ${path.join(sdk, 'ndk')}. Install one with sdkmanager, or set ANDROID_NDK_ROOT.`,
    );
}
if (!fs.existsSync(path.join(jdk, 'bin', 'java'))) {
    // Gradle 需要 JDK 17–21；系统的 JDK 27 会被 AGP 直接拒掉，提前提示比让 Gradle 报栈好读。
    console.warn(
        `JAVA_HOME does not look like a JDK: ${jdk}. ` +
            'Set JAVA_HOME to a JDK 17–21 installation before building.',
    );
}

prepareNodeMobile();
prepareResources();
if (prepareOnly) {
    process.exit(0);
}

ensureKeystore();
const buildTools = findBuildTools();
run(
    qtCmake,
    [
        '-S',
        '.',
        '-B',
        build,
        '-G',
        'Ninja',
        `-DCMAKE_BUILD_TYPE=${buildType}`,
        `-DANDROID_ABI=${abi}`,
        // 与 kit 一致用 28：Qt 6.12 自己的默认 minSdk 也是 28
        // （src/corelib/Qt6AndroidGradleHelpers.cmake 里 QT_ANDROID_MIN_SDK_VERSION 的默认值）。
        '-DANDROID_PLATFORM=android-28',
        `-DANDROID_SDK_ROOT=${sdk}`,
        `-DANDROID_NDK_ROOT=${ndk}`,
        `-DRHINE_ANDROID_NODE_ROOT=${dependencies}`,
        `-DRHINE_ANDROID_RESOURCES=${resources}`,
        `-DRHINE_PACKAGE_APP=OFF`,
        `-DRHINE_VERSION=${version.version}`,
        `-DRHINE_RELEASE_BUILD=${version.release ? 'ON' : 'OFF'}`,
    ],
    { env: toolEnvironment() },
);
run('cmake', ['--build', build, '--target', 'apk', '--', '-j', process.env.RHINE_BUILD_JOBS || '8'], {
    env: toolEnvironment(),
});

const apks = findApk(build);
if (apks.length === 0) {
    throw new Error(`No APK produced under ${build}`);
}
const unsignedApk = apks[0];
console.log(`Signing ${path.relative(root, unsignedApk)}`);
const aligned = path.join(work, 'aligned.apk');
const signed = path.resolve(`output/RhineMusicDatabase-${packageIdentity(version)}-android-${abi}.apk`);
if (unsigned) {
    fs.copyFileSync(unsignedApk, signed);
} else {
    // zipalign 必须在签名之前：签名后再对齐会破坏 v2/v3 签名块。
    run(path.join(buildTools, 'zipalign'), ['-p', '-f', '4', unsignedApk, aligned]);
    run(path.join(buildTools, 'apksigner'), [
        'sign',
        '--ks',
        keystore,
        '--ks-key-alias',
        'rhine-debug',
        '--ks-pass',
        'pass:android',
        '--key-pass',
        'pass:android',
        '--min-sdk-version',
        '26',
        '--out',
        signed,
        aligned,
    ]);
}
run(process.env.PYTHON || 'python3', ['scripts/audit-android.py', signed, '--sdk', sdk]);
console.log(`Android APK: ${signed}`);
