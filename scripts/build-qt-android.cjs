// 从 third_party/qt/* 的固定提交构建 Qt for Android（arm64-v8a）kit。
//
// 这一步只在搭环境或换 Qt 版本时跑一次，出 APK 用 scripts/build-android.cjs。
// 和 iOS/桌面不同，Android 的 Qt 6.12 没有公开的预编译包（Qt 在线仓库的 Android
// 组件只到 6.6.3），所以只能拿自己的源码树交叉编译一份。
//
// 顺序：OpenSSL（静态，供 Qt Network 的 TLS）→ qtbase → qtshadertools → qtdeclarative
// → qtsvg → qtmultimedia。后四个用 qtbase 装出来的 qt.toolchain.cmake 配置。
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');

const root = path.resolve(__dirname, '..');
process.chdir(root);

const checkOnly = process.argv.includes('--check');
const force = process.argv.includes('--force');
const jobs = process.env.RHINE_BUILD_JOBS || String(Math.max(4, Math.min(8, os.cpus().length)));

const toolchain = require('./android-toolchain.cjs');
const sdk = toolchain.sdkRoot();
const kit = process.env.RHINE_ANDROID_QT || path.resolve('output/dependencies/qt-android');
const buildRoot = path.resolve('output/qt-android-build');
const opensslPrefix = path.resolve('output/dependencies/openssl-android');
const opensslRelease = require('../vendor/openssl/source.json');
const opensslSource = path.resolve(`output/dependencies/openssl-src/openssl-${opensslRelease.version}`);
const hostQt = process.env.RHINE_HOST_QT || '/usr';

/** Android 包的 Qt 版本必须与 host 侧一致：moc/rcc/qmlcachegen 的产线在这里对齐。 */
const qtVersion = '6.12.0';

// Qt 6.12 的 Android 音频后端只有 AAudio（没有 OpenSL ES 了），而
// AAudioStreamBuilder_setUsage / setContentType / setInputPreset 都是 API 28 才引入的
// （NDK 头里带 __INTRODUCED_IN(28)），Qt 源码里没有条件编译，所以在 API 26 下必然编不过。
// 因此 kit 按 28 编，应用侧的 minSdk 也一并提到 28（Android 9）。
const androidPlatform = '28';

// 依赖顺序即构建顺序：qtdeclarative 的 qmlcachegen 需要 qtshadertools，qtmultimedia
// 的 QML 插件需要 qtdeclarative，qtsvg 只提供图片插件但一同进 kit。
const modules = ['qtbase', 'qtshadertools', 'qtdeclarative', 'qtsvg', 'qtmultimedia'];

const ndk = toolchain.ndkRoot(sdk);
// Qt 的 Android 平台分支会 find_package(Java Development)，必须给出 JDK 17–21；
// 系统那套是 27，AGP 和 Qt 的 Java 步骤都不认。
const jdk = toolchain.jdkHome(path.resolve('output/android-work'));

function run(command, args, options = {}) {
    const started = Date.now();
    const result = spawnSync(command, args, { stdio: 'inherit', ...options });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw new Error(`${command} exited with ${result.status}`);
    }
    return Math.round((Date.now() - started) / 1000);
}

function sourceDirectory(name) {
    return path.join(root, 'third_party', 'qt', name);
}

function modulePackageName(name) {
    // qtbase 装出来的包名就是 Qt6；其余模块是 Qt6 + 去掉 qt 前缀的驼峰名。
    if (name === 'qtbase') {
        return 'Qt6';
    }
    const suffix = name.replace(/^qt/, '').replace(/^./, (character) => character.toUpperCase());
    return `Qt6${suffix}`;
}

function moduleReady(name) {
    // 装完的模块会在 kit 里留下自己的 CMake 包：比标记文件更能说明"能用"。
    return fs.existsSync(path.join(kit, 'lib', 'cmake', modulePackageName(name)));
}

function report() {
    const rows = [
        ['host Qt', hostQt, fs.existsSync(path.join(hostQt, 'lib', 'cmake', 'Qt6HostInfo'))],
        ['Android SDK', sdk, fs.existsSync(sdk)],
        ['NDK', ndk, ndk !== '' && fs.existsSync(path.join(ndk, 'source.properties'))],
        ['JDK', `${jdk} (java ${javaMajor(jdk) || '?'})`, gradleJdkOk(jdk)],
    ];
    rows.push(['source openssl', opensslSource, fs.existsSync(path.join(opensslSource, '.extracted'))]);
    for (const name of modules) {
        const directory = sourceDirectory(name);
        rows.push([
            `source ${name}`,
            directory,
            fs.existsSync(path.join(directory, 'CMakeLists.txt')) ||
                fs.existsSync(path.join(directory, 'Configure')),
        ]);
    }
    rows.push(['kit', kit, fs.existsSync(path.join(kit, 'lib', 'cmake', 'Qt6'))]);
    console.log('Qt for Android kit 构建前置条件：');
    for (const [label, value, ok] of rows) {
        console.log(`  ${ok ? ' ok ' : 'MISS'}  ${label}: ${value}`);
    }
    const missing = rows.filter((row) => !row[2] && row[0] !== 'kit');
    if (missing.length > 0) {
        console.log('\nQt 源码先初始化子模块：git submodule update --init --depth 1 third_party/qt');
    }
}

if (checkOnly) {
    report();
    process.exit(0);
}
if (!ndk) {
    throw new Error(`No Android NDK under ${path.join(sdk, 'ndk')}; set ANDROID_NDK_ROOT.`);
}
// 只编 OpenSSL：Qt 源码还没就位时也能先把 TLS 依赖准备好。
if (process.argv.includes('--openssl-only')) {
    fs.mkdirSync(buildRoot, { recursive: true });
    buildOpenSsl();
    process.exit(0);
}

for (const name of modules) {
    const directory = sourceDirectory(name);
    if (!fs.existsSync(directory)) {
        throw new Error(
            `Missing source tree: ${directory} (run: git submodule update --init --depth 1 third_party/qt)`,
        );
    }
}
// 这台机器默认的 java 是 27：Gradle 9 的 Groovy 解析不了它的 class 文件，报
// "Unsupported class file major version 71"。宁可在这里停住，也不要编到一半才炸。
if (!gradleJdkOk(jdk)) {
    throw new Error(
        `Gradle needs JDK 17–25, but ${jdk} reports Java ${javaMajor(jdk) || 'unknown'}.\n` +
            'Set JAVA_HOME to a JDK 21 (or unpack Temurin 21 into output/android-work/jdk).',
    );
}
fs.mkdirSync(buildRoot, { recursive: true });

/**
 * OpenSSL 用发布包而不是子模块：它是构建期依赖，版本与哈希记在 vendor/openssl/source.json，
 * 下载一次缓存到 output/dependencies，之后的构建直接复用解压结果。
 */
function ensureOpenSslSource() {
    // 用标记文件而不是只看 Configure：解压被打断时 Configure 可能已经在位，
    // 但 util/perl 之类的目录还没落地，Configure 会以 "Can't locate OpenSSL/fallback.pm" 失败。
    if (fs.existsSync(path.join(opensslSource, '.extracted'))) {
        return;
    }
    const archive = path.resolve(`output/dependencies/openssl-${opensslRelease.version}.tar.gz`);
    fs.mkdirSync(path.dirname(archive), { recursive: true });
    if (!fs.existsSync(archive)) {
        run('curl', ['-L', '--fail', '--retry', '3', opensslRelease.download, '-o', archive]);
    }
    const digest = createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    if (digest !== opensslRelease.sha256) {
        throw new Error(`OpenSSL checksum mismatch: expected ${opensslRelease.sha256}, got ${digest}`);
    }
    fs.rmSync(opensslSource, { recursive: true, force: true });
    fs.mkdirSync(path.dirname(opensslSource), { recursive: true });
    // -m（--touch）跳过 mtime 恢复：在受限沙箱里 utime 会被拒绝，整包解压会因此中断。
    run('tar', ['xmf', archive, '-C', path.dirname(opensslSource)]);
    if (!fs.existsSync(path.join(opensslSource, 'util', 'perl', 'OpenSSL', 'fallback.pm'))) {
        throw new Error('OpenSSL source tree is incomplete after extraction');
    }
    fs.writeFileSync(path.join(opensslSource, '.extracted'), `${opensslRelease.version}\n`);
}

/**
 * OpenSSL 走静态链接：Android 的 APK 只接受 lib*.so 形态的共享库，
 * 带版本号的 libssl.so.3 塞不进 lib/arm64-v8a，而静态库直接进进 libQt6Network.so，
 * 既没有 SONAME 问题，也不用把两份 .so 加进 QT_ANDROID_EXTRA_LIBS。
 */
function buildOpenSsl() {
    ensureOpenSslSource();
    const stamp = path.join(opensslPrefix, 'lib', 'libssl.a');
    if (fs.existsSync(stamp) && !force) {
        console.log('OpenSSL: already built');
        return;
    }
    console.log('OpenSSL: configure (android-arm64, static)');
    const toolchain = path.join(ndk, 'toolchains', 'llvm', 'prebuilt', 'linux-x86_64', 'bin');
    const environment = {
        ...process.env,
        ANDROID_NDK_ROOT: ndk,
        PATH: `${toolchain}:${process.env.PATH}`,
    };
    // OpenSSL 的 Configure 会把上次的配置写进 Makefile，换 ABI 或换 NDK 时必须先清干净。
    if (fs.existsSync(path.join(opensslSource, 'Makefile'))) {
        run('make', ['distclean'], { cwd: opensslSource, env: environment });
    }
    run(
        './Configure',
        [
            'android-arm64',
            'no-shared',
            'no-tests',
            'no-docs',
            `--prefix=${opensslPrefix}`,
            `--openssldir=${opensslPrefix}/ssl`,
            '-D__ANDROID_API__=26',
        ],
        { cwd: opensslSource, env: environment },
    );
    console.log(`OpenSSL: build (-j${jobs})`);
    run('make', [`-j${jobs}`], { cwd: opensslSource, env: environment });
    run('make', ['install_sw'], { cwd: opensslSource, env: environment });
    console.log(`OpenSSL: installed to ${opensslPrefix}`);
}

/** Android 交叉编译的定位全部走环境变量：Qt 的 configure 与 NDK 的 toolchain 都读它们。 */
function androidEnvironment() {
    const environment = {
        ...process.env,
        ANDROID_NDK_ROOT: ndk,
        ANDROID_SDK_ROOT: sdk,
        ANDROID_HOME: sdk,
        JAVA_HOME: jdk,
        PATH: `${path.join(jdk, 'bin')}:${process.env.PATH}`,
        // 客户端 JVM 上的系统属性同样参与 Gradle 的 JVM 选择；和下面的
        // gradle.properties 一起构成双保险。
        GRADLE_OPTS: `${process.env.GRADLE_OPTS || ''} -Dorg.gradle.java.home=${jdk}`.trim(),
    };
    // Gradle 缓存默认在 ~/.gradle。搬进工作区会让 wrapper 发行包与 AGP/androidx 依赖
    // 全部重下一遍（几百 MB，且构建机常常没有代理），所以只在显式要求时改：
    if (process.env.RHINE_GRADLE_HOME) {
        environment.GRADLE_USER_HOME = process.env.RHINE_GRADLE_HOME;
    }
    return environment;
}

/** 取 JDK 的 major 版本；拿不到就返回 0（交给调用方当作不可用）。 */
function javaMajor(home) {
    const binary = path.join(home, 'bin', 'java');
    if (!fs.existsSync(binary)) {
        return 0;
    }
    const result = spawnSync(binary, ['-version'], { encoding: 'utf8' });
    const match = /version "(\d+)/.exec(`${result.stderr || ''}${result.stdout || ''}`);
    return match ? Number(match[1]) : 0;
}

/** Gradle 9 运行的 JDK 上限是 25；低于 17 时 AGP 也不接受。 */
function gradleJdkOk(home) {
    const major = javaMajor(home);
    return major >= 17 && major <= 25;
}

/**
 * 兜底：把 JDK 写进生成的 ninja 规则。
 *
 * Qt 的 jar 规则是 `cmake -E env ANDROID_SDK_ROOT=… gradlew …`，本身不带 JAVA_HOME，靠继承
 * 调用方的环境。脚本自己调用时会传 androidEnvironment()，但如果构建被 Ctrl-C 打断、之后有人
 * 直接在构建目录里跑 `ninja`，Gradle 就退回系统默认的 java（这台机器是 27），Groovy 读不了
 * major 71 的 class 文件，报 "Unsupported class file major version 71"。
 * 构建目录属于 output/，改它既不碰子模块，也不需要调用方配合。
 */
function pinGradleJvm(buildDirectory) {
    const file = path.join(buildDirectory, 'build.ninja');
    if (!fs.existsSync(file)) {
        return 0;
    }
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    const needle = `ANDROID_SDK_ROOT=${sdk} `;
    let patched = 0;
    for (let index = 0; index < lines.length; ++index) {
        const line = lines[index];
        if (!line.includes('gradlew') || !line.includes(needle) || line.includes('JAVA_HOME=')) {
            continue;
        }
        lines[index] = line.replace(needle, `${needle}JAVA_HOME=${jdk} `);
        ++patched;
    }
    if (patched > 0) {
        fs.writeFileSync(file, lines.join('\n'));
        console.log(`  gradle: ${patched} 条 jar 规则已带上 JAVA_HOME=${jdk}`);
    }
    return patched;
}

/** qtbase 用 configure（它会自己带好 Android 工具链）；其余模块用 kit 里的 toolchain 文件。 */
function buildQtBase() {
    if (moduleReady('qtbase') && !force) {
        console.log('qtbase: already installed');
        return;
    }
    const source = sourceDirectory('qtbase');
    const build = path.join(buildRoot, 'qtbase');
    // Qt 的 Android 自动探测只看缓存里的 ANDROID_NDK_ROOT，环境变量不够；
    // 单模块构建本来就该显式给工具链文件（Qt 文档里 per-repo build 的写法）。
    const toolchainFile = path.join(ndk, 'build', 'cmake', 'android.toolchain.cmake');
    const cache = path.join(build, 'CMakeCache.txt');
    if (
        fs.existsSync(cache) &&
        !fs.readFileSync(cache, 'utf8').includes(`CMAKE_TOOLCHAIN_FILE:FILEPATH=${toolchainFile}`)
    ) {
        // 上一次 configure 失败会留下没有切工具链的缓存，CMake 拒绝在已有缓存上换工具链。
        fs.rmSync(build, { recursive: true, force: true });
    }
    fs.mkdirSync(build, { recursive: true });
    // 目录被清掉、或本来就是空的，才算首次配置；已有缓存时沿用当初写进去的 ANDROID_PLATFORM。
    const freshBuild = !fs.existsSync(cache);
    console.log('qtbase: configure');
    // NDK 与 SDK 只认环境变量：Qt 6 的 configure 没有 -android-ndk / -android-sdk 选项，
    // 传了会被当成未知参数直接报错（见 cmake/QtProcessConfigureArgs.cmake）。
    run(
        path.join(source, 'configure'),
        [
            // 路径类选项一律「选项 + 独立参数」：Qt 的解析器按 arg STREQUAL 逐项比对，
            // -prefix=... 这种合并写法会被判成 Unknown command line option。
            '-prefix',
            kit,
            '-release',
            '-openssl-linked',
            '-android-abis',
            'arm64-v8a',
            // 平台只在首次配置时写进缓存：改 ANDROID_PLATFORM 会让 CMake 重编全部对象，
            // 已经能用的构建树不值得为一个 minSdk 数字付这个代价（26 编出来的库在 28+ 上照样跑）。
            ...(freshBuild ? ['-android-ndk-platform', androidPlatform] : []),
            '-qt-host-path',
            hostQt,
            '-nomake',
            'examples',
            '-nomake',
            'tests',
            // '--' 之后的参数原样交给 CMake（QtProcessConfigureArgs.cmake:228）。
            // 不能用 '-D变量=值'：configure 会把它塞进 QT_EXTRA_DEFINES（编译器宏），
            // 结果 CMAKE_TOOLCHAIN_FILE 根本没进缓存，CMake 就报"没指定 Android 工具链"。
            '--',
            `-DCMAKE_TOOLCHAIN_FILE=${toolchainFile}`,
            // QtPlatformAndroid.cmake 直接读缓存变量，环境变量满足不了它。
            `-DANDROID_SDK_ROOT=${sdk}`,
            // Qt 的 Android 库只支持 c++_shared，静态 STL 会在这里被直接判错。
            '-DANDROID_STL=c++_shared',
            // qtbase 要编 src/android/jar，它用 Gradle 拉 AGP 与 androidx；Qt 默认在
            // "building Qt" 时禁止下载，除非显式打开（QtJavaHelpers.cmake:153）。
            '-DQT_ALLOW_DOWNLOAD=ON',
            `-DOPENSSL_ROOT_DIR=${opensslPrefix}`,
            '-DOPENSSL_USE_STATIC_LIBS=TRUE',
        ],
        { cwd: build, env: androidEnvironment() },
    );
    pinGradleJvm(build);
    // 每一步都要带 androidEnvironment()：少了它，Gradle 会用系统默认的 java 而不是 JDK 21，
    // configure 能过，编译到 jar 步骤才报 "Unsupported class file major version 71"。
    console.log(`qtbase: build (-j${jobs})`);
    run('cmake', ['--build', '.', '--parallel', jobs], { cwd: build, env: androidEnvironment() });
    run('cmake', ['--install', '.'], { cwd: build, env: androidEnvironment() });
}

function buildModule(name) {
    if (moduleReady(name) && !force) {
        console.log(`${name}: already installed`);
        return;
    }
    const source = sourceDirectory(name);
    const build = path.join(buildRoot, name);
    fs.mkdirSync(build, { recursive: true });
    console.log(`${name}: configure`);
    run(
        'cmake',
        [
            '-S',
            source,
            '-B',
            build,
            '-G',
            'Ninja',
            `-DCMAKE_TOOLCHAIN_FILE=${path.join(kit, 'lib', 'cmake', 'Qt6', 'qt.toolchain.cmake')}`,
            `-DANDROID_SDK_ROOT=${sdk}`,
            '-DANDROID_STL=c++_shared',
            // qtmultimedia 的 AAudio 后端要用 API 28 的符号；其余模块照常。
            `-DANDROID_PLATFORM=${androidPlatform}`,
            `-DQT_HOST_PATH=${hostQt}`,
            `-DCMAKE_INSTALL_PREFIX=${kit}`,
            '-DCMAKE_BUILD_TYPE=Release',
            '-DQT_BUILD_EXAMPLES=OFF',
            '-DQT_BUILD_TESTS=OFF',
        ],
        { cwd: root, env: androidEnvironment() },
    );
    pinGradleJvm(build);
    console.log(`${name}: build (-j${jobs})`);
    run('cmake', ['--build', build, '--parallel', jobs], { cwd: root, env: androidEnvironment() });
    run('cmake', ['--install', build], { cwd: root, env: androidEnvironment() });
}

buildOpenSsl();
buildQtBase();
for (const name of modules.slice(1)) {
    buildModule(name);
}

// 收尾检查：没有 Qt6Multimedia 与 Qt6ShaderTools 的 kit 是半成品，宁可在这里失败，
// 也不要等到配置应用时才发现。
for (const name of ['Qt6', 'Qt6Qml', 'Qt6ShaderTools', 'Qt6Multimedia']) {
    const directory = path.join(kit, 'lib', 'cmake', name);
    if (!fs.existsSync(directory)) {
        throw new Error(`Qt kit is incomplete, missing ${directory}`);
    }
}
console.log(`Qt for Android kit ready: ${kit} (Qt ${qtVersion})`);
