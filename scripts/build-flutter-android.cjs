// Flutter Android（arm64-v8a）APK 的唯一构建入口：CI 与本地共用这一条链路。
//
// 以前 CI 的 .github/workflows/flutter.yaml 把「准备资源 → CMake 配置 → 编 native →
// androiddeployqt --aux-mode → flutter build apk」五步内联在 YAML 里，本地只能照着
// 文档各拼一遍，参数很容易走偏（例如漏掉 RHINE_FLUTTER_HOST_ONLY / QT_NO_GLOBAL_APK_TARGET_PART_OF_ALL，
// 或用了错误的 javac 导致 patchQtAndroidJar 的 sha 门禁失败）。这里把这些步骤收敛成
// 一个脚本，两边都只调用它，不再各自维护命令。
//
// 用法：
//   npm run build:flutter:android                 # release（与 CI 一致）
//   npm run build:flutter:android -- --debug      # debug
//
// 环境前提（脚本会逐项检查并给出缺什么）：
//   * Flutter SDK、Android SDK/NDK、CMake + Ninja；
//   * Qt for Android kit：output/dependencies/qt-android（或 RHINE_ANDROID_QT）；
//   * 宿主 Qt（moc/rcc/qmlcachegen）：QT_ROOT_DIR / RHINE_HOST_QT，缺省 /usr；
//   * Gradle 用的 JDK 17–25；javac 27（javapatch 的 EXPECTED.sha256 由 27.0.1 录制）。
//
// 输出：build/app/outputs/flutter-apk/app-arm64-v8a-<buildType>.apk
//       （--split-per-abi 按 ABI 分片命名；--target-platform android-arm64 保证只有 arm64-v8a 这一片）
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const toolchain = require('./android-toolchain.cjs');

const root = path.resolve(__dirname, '..');
process.chdir(root);

const debug = process.argv.includes('--debug');
const buildType = debug ? 'Debug' : 'Release';
const modeFlag = debug ? '--debug' : '--release';

// javapatch/EXPECTED.sha256 是用 javac 27.0.1 编出来的 class 字节录的；换 javac 大版本
// 一定对不上。这个数字和 EXPECTED.sha256 必须一起改。
const JAVAC_MAJOR = 27;

const sdk = toolchain.sdkRoot();
// CI 用 ANDROID_NDK_ROOT 钉住 30.0.16248370；本地若也显式设置，就以它为准，
// 避免机器上装了更新 NDK 时悄悄换版本、与 CI 产物不一致。
const ndk = process.env.ANDROID_NDK_ROOT || toolchain.ndkRoot(sdk);
const kit = process.env.RHINE_ANDROID_QT || path.resolve('output/dependencies/qt-android');
const hostQt = process.env.QT_ROOT_DIR || process.env.RHINE_HOST_QT || '/usr';
const buildDirectory = path.resolve(
    process.env.RHINE_QT_ANDROID_FLUTTER_BUILD_DIR || 'output/qt-android-flutter',
);
const deployDirectory = path.resolve(
    process.env.RHINE_QT_ANDROID_DEPLOY_DIR || path.join(buildDirectory, 'Qt/android-build'),
);
const jobs = process.env.RHINE_BUILD_JOBS || String(Math.max(4, Math.min(8, os.cpus().length)));

function run(command, args, options = {}) {
    console.log(`\n$ ${[command, ...args].join(' ')}`);
    const result = spawnSync(command, args, { stdio: 'inherit', ...options });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw new Error(`${command} exited with ${result.status}`);
    }
}

function executable(name) {
    const finder = process.platform === 'win32' ? 'where' : 'which';
    const result = spawnSync(finder, [name], { encoding: 'utf8' });
    if (result.status !== 0) {
        return '';
    }
    return (result.stdout || '').split(/\r?\n/).find(Boolean)?.trim() || '';
}

/** 读 `java -version` / `javac -version` 的 major，拿不到返回 0。 */
function javaMajor(home) {
    for (const name of ['java', 'javac']) {
        const binary = path.join(home, 'bin', name);
        if (!fs.existsSync(binary)) {
            continue;
        }
        const result = spawnSync(binary, ['-version'], { encoding: 'utf8' });
        const text = `${result.stderr || ''}${result.stdout || ''}`;
        const match = /version "(\d+)/.exec(text) || /\b(?:javac|java)\s+(\d+)/.exec(text);
        if (match) {
            return Number(match[1]);
        }
    }
    return 0;
}

function jdkCandidates() {
    const candidates = [
        process.env.RHINE_GRADLE_JDK,
        process.env.JAVA_HOME,
        // Android Studio 自带的 JBR 是本地最常见的 17–25 JDK。
        '/opt/android-studio/jbr',
        '/Applications/Android Studio.app/Contents/jbr/Contents/Home',
    ];
    const managed = path.resolve('output/android-work/jdk');
    if (fs.existsSync(managed)) {
        for (const name of fs.readdirSync(managed)) {
            candidates.push(path.join(managed, name));
        }
    }
    return candidates.filter(Boolean);
}

function resolveGradleJdk() {
    for (const candidate of jdkCandidates()) {
        const major = javaMajor(candidate);
        if (major >= 17 && major <= 25) {
            return candidate;
        }
    }
    throw new Error(
        '找不到 Gradle 能用的 JDK（需要 17–25）。\n' +
            '  * 设置 JAVA_HOME 指向 JDK 21/25，或\n' +
            '  * 设置 RHINE_GRADLE_JDK，或\n' +
            '  * 把 JDK 解压到 output/android-work/jdk/ 下。',
    );
}

function resolveJavacHome() {
    const candidates = [
        process.env.RHINE_JAVAC_HOME,
        process.env.JDK27_HOME,
        process.env.JAVA_HOME_27_X64,
        process.env.JAVA_HOME,
    ];
    const managed = path.resolve('output/android-work');
    if (fs.existsSync(managed)) {
        for (const name of fs.readdirSync(managed)) {
            if (name.startsWith('jdk')) {
                candidates.push(path.join(managed, name));
            }
        }
    }
    const systemJavac = executable('javac');
    if (systemJavac) {
        // /usr/bin/javac 通常是符号链接，realpath 才能拿到 JDK 根。
        candidates.push(path.dirname(path.dirname(fs.realpathSync(systemJavac))));
    }
    for (const candidate of candidates.filter(Boolean)) {
        if (javaMajor(candidate) === JAVAC_MAJOR) {
            return candidate;
        }
    }
    throw new Error(
        `patchQtAndroidJar 的 EXPECTED.sha256 由 javac ${JAVAC_MAJOR} 录制，找不到该版本的 javac。\n` +
            '  * 设置 RHINE_JAVAC_HOME（或 CI 里的 JDK27_HOME），或\n' +
            '  * 把 JDK 27 解压到 output/android-work/jdk27/ 下。',
    );
}

function resolveFlutter() {
    if (process.env.FLUTTER_ROOT) {
        const rooted = path.join(process.env.FLUTTER_ROOT, 'bin/flutter');
        if (fs.existsSync(rooted)) {
            return rooted;
        }
    }
    // PATH 是调用方最明确的选择（CI 的 setup-flutter 就装在这里）。
    const onPath = executable('flutter');
    if (onPath) {
        return onPath;
    }
    const candidates = [
        path.join(os.homedir(), 'flutter/bin/flutter'),
        path.join(os.homedir(), 'development/flutter/bin/flutter'),
        '/opt/flutter/bin/flutter',
        '/usr/local/flutter/bin/flutter',
    ];
    const local = candidates.find((candidate) => fs.existsSync(candidate));
    if (local) {
        return local;
    }
    throw new Error('找不到 flutter；请把 Flutter SDK 的 bin 目录加进 PATH，或设置 FLUTTER_ROOT。');
}

function assertFile(file, message) {
    if (!fs.existsSync(file)) {
        throw new Error(`${message}\n  缺少：${file}`);
    }
}

function findDeploymentSettings(directory) {
    // androiddeployqt 的 settings 只会在构建根或 Qt/ 子目录下，别递归扫整个编译树。
    for (const candidate of [directory, path.join(directory, 'Qt')]) {
        if (!fs.existsSync(candidate)) {
            continue;
        }
        for (const entry of fs.readdirSync(candidate)) {
            if (/^android-.*deployment-settings\.json$/.test(entry)) {
                return path.join(candidate, entry);
            }
        }
    }
    return '';
}

const javaHome = resolveGradleJdk();
const javacHome = resolveJavacHome();
const flutter = resolveFlutter();
const ninja = executable('ninja');

console.log('Flutter Android 构建（CI 与本地同一链路）');
console.log(`  build type : ${buildType}`);
console.log(`  Gradle JDK : ${javaHome} (java ${javaMajor(javaHome)})`);
console.log(`  javac      : ${javacHome} (java ${javaMajor(javacHome)})`);
console.log(`  SDK / NDK  : ${sdk} / ${ndk}`);
console.log(`  Qt kit     : ${kit}`);
console.log(`  宿主 Qt    : ${hostQt}`);
console.log(`  Flutter    : ${flutter}`);
console.log(`  staging    : ${deployDirectory}`);

assertFile(path.join(sdk, 'platform-tools'), `Android SDK 不可用（${sdk}）。`);
assertFile(path.join(ndk, 'source.properties'), 'Android NDK 不可用，设置 ANDROID_NDK_ROOT。');
assertFile(
    path.join(kit, 'lib/cmake/Qt6/qt.toolchain.cmake'),
    `Qt for Android kit 不可用（${kit}）。先运行：npm run build:qt:android`,
);
assertFile(
    path.join(hostQt, 'lib/cmake/Qt6HostInfo'),
    `宿主 Qt 不可用（${hostQt}）。设置 QT_ROOT_DIR 或 RHINE_HOST_QT 指向 Qt 6.12 桌面 kit。`,
);
assertFile(ninja, '找不到 ninja；安装后重试（apt install ninja-build / brew install ninja）。');

// 两个 JDK 各司其职：JAVA_HOME 给 Gradle/AGP，rhineJavacHome 只给 patchQtAndroidJar。
const environment = {
    ...process.env,
    ANDROID_SDK_ROOT: sdk,
    ANDROID_HOME: sdk,
    ANDROID_NDK_ROOT: ndk,
    JAVA_HOME: javaHome,
    GRADLE_OPTS: `${process.env.GRADLE_OPTS || ''} -Dorg.gradle.java.home=${javaHome}`.trim(),
    // build.gradle.kts 用它找 libs/Qt6Android.jar 与 res/values/libs.xml；
    // 统一写成绝对路径，避免 rootProject.file() 把相对路径解析到 android/ 下。
    RHINE_QT_ANDROID_DEPLOY_DIR: deployDirectory,
};

// 1) Node 运行时与 Android 资源（字体、场景、桥接 bundle）。
run('node', ['scripts/build-android.cjs', '--prepare-only'], { env: environment });

// 2) Qt native：只编宿主库，不产出纯 Qt APK。
run(
    'cmake',
    [
        '-S',
        '.',
        '-B',
        buildDirectory,
        '-G',
        'Ninja',
        `-DCMAKE_TOOLCHAIN_FILE=${path.join(kit, 'lib/cmake/Qt6/qt.toolchain.cmake')}`,
        `-DQT_HOST_PATH=${hostQt}`,
        `-DQT_HOST_PATH_CMAKE_DIR=${path.join(hostQt, 'lib/cmake')}`,
        '-DQT_QMAKE_TARGET_MKSPEC=android-clang',
        '-DANDROID_ABI=arm64-v8a',
        '-DANDROID_PLATFORM=android-28',
        `-DANDROID_NDK_ROOT=${ndk}`,
        `-DANDROID_SDK_ROOT=${sdk}`,
        `-DCMAKE_BUILD_TYPE=${buildType}`,
        `-DCMAKE_MAKE_PROGRAM=${ninja}`,
        // 显式钉住 cache 默认值（docs/ANDROID.md §5.5 的教训：CMake 不会用源码里的
        // 新默认覆盖已有 cache，本机 build 树曾停在旧档位上静默漂移；显式传值让
        // 本机增量构建与 CI 干净构建永远同档）。
        //   LTO：与 build-android.cjs 同款写法，可用 RHINE_ANDROID_LTO 覆盖；
        //   NORMAL_RGBA8：必须与烘焙硬编码 RHINE_BAKE_NORMAL_RGBA8=1 同步，两者
        //   错位就是启动 qFatal（2026-11-06 的启动崩溃即此根因），option 默认 ON
        //   但不依赖它，显式传死。
        `-DRHINE_ANDROID_LTO=${process.env.RHINE_ANDROID_LTO || 'full'}`,
        '-DRHINE_ANDROID_NORMAL_RGBA8=ON',
        '-DRHINE_FLUTTER_HOST_ONLY=ON',
        '-DQT_NO_GLOBAL_APK_TARGET_PART_OF_ALL=ON',
        `-DRHINE_ANDROID_NODE_ROOT=${path.resolve('output/dependencies/node-mobile')}`,
        `-DRHINE_ANDROID_RESOURCES=${path.resolve('output/android-resources')}`,
    ],
    { env: environment },
);

// 3) 编 .so 并放进 staging/libs/arm64-v8a；aux 模式要求应用库已经在那里。
run('cmake', ['--build', buildDirectory, '--target', 'RhineMusicDatabase_prepare_apk_dir', '--', `-j${jobs}`], {
    env: environment,
});

// 4) androiddeployqt --aux-mode：只补 Qt 依赖、qt_libs 资源与 jar，不跑 Gradle。
const settings = findDeploymentSettings(buildDirectory);
assertFile(settings, '找不到 androiddeployqt 的 deployment-settings.json。');
const hostDeployQt = path.join(hostQt, 'bin/androiddeployqt');
const kitDeployQt = path.join(kit, 'bin/androiddeployqt');
const deployQt = fs.existsSync(hostDeployQt) ? hostDeployQt : kitDeployQt;
assertFile(deployQt, '找不到 androiddeployqt（宿主 Qt 或 Android kit 的 bin 目录）。');
run(deployQt, ['--input', settings, '--output', deployDirectory, '--aux-mode'], { env: environment });

for (const file of [
    path.join(deployDirectory, 'libs/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so'),
    path.join(deployDirectory, 'libs/Qt6Android.jar'),
    path.join(deployDirectory, 'res/values/libs.xml'),
    path.join(deployDirectory, 'assets/android_rcc_bundle.rcc'),
]) {
    assertFile(file, 'staging 不完整，androiddeployqt 没有产出 Qt 运行时。');
}

// 5) Flutter 出包。release 的 R8/资源压缩规则由 android/app/proguard-rules.pro 与
//    android/app/src/main/res/raw/keep.xml 保活 Qt 的反射入口，CI 与本地完全一致。
//    --split-per-abi + 单个 --target-platform：AGP 只切出 arm64-v8a 一片，不再出
//    universal APK（isUniversalApk=false）。README/CI 拿到的永远是 ABI 明确的包。
//    force-version-code-ignoring-abi：分 ABI 构建时 Flutter 会把 versionCode 改写成
//    `ABI 系数*1000 + pubspec build number`（arm64-v8a 系数 2，即 +2000，
//    FlutterPlugin.kt:659-676）。本项目只出 arm64 一片，不需要 ABI 区分码，
//    显式关掉后 APK 的 versionCode 就是 pubspec.yaml 里写的 `+N`——否则
//    `+79900` 会被写成 81900，和版本口径对不上。
run(
    flutter,
    [
        'build',
        'apk',
        modeFlag,
        '--split-per-abi',
        '--target-platform',
        'android-arm64',
        '--android-project-arg',
        `rhineJavacHome=${javacHome}`,
        '--android-project-arg',
        'force-version-code-ignoring-abi=true',
    ],
    { env: environment },
);

// --split-per-abi 后产物按 ABI 命名（flutter_tools listApkPaths: app-<abi>-<buildType>.apk）。
const apkDirectory = path.resolve('build/app/outputs/flutter-apk');
const apk = path.join(apkDirectory, `app-arm64-v8a-${debug ? 'debug' : 'release'}.apk`);
assertFile(apk, 'Flutter 构建结束但没有找到 arm64-v8a 分片 APK。');

// 从产物本身确认"只有 arm64-v8a"：分 ABI 后 AGP 按 .so 目录切分片，依赖里混进别的 ABI
// 就会多出分片。查目录有没有残留文件会误判历史产物，所以直接读 APK 的 native-code。
// 找不到 aapt2 时只告警：这条是护栏，不该成为本地出包的硬依赖。
function readBadging(file) {
    const buildTools = path.join(sdk, 'build-tools');
    if (!fs.existsSync(buildTools)) {
        return null;
    }
    const candidates = fs
        .readdirSync(buildTools)
        .filter((version) => fs.existsSync(path.join(buildTools, version, 'aapt2')))
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    if (candidates.length === 0) {
        return null;
    }
    const badging = spawnSync(path.join(buildTools, candidates.pop(), 'aapt2'), ['dump', 'badging', file], {
        encoding: 'utf8',
        maxBuffer: 8 << 20,
    });
    return badging.status === 0 ? badging.stdout || '' : null;
}

function nativeCodeOf(badging) {
    const line = /^native-code:(.*)$/m.exec(badging);
    return line ? [...line[1].matchAll(/'([^']+)'/g)].map((match) => match[1]) : [];
}

function versionCodeOf(badging) {
    const match = /versionCode='(\d+)'/.exec(badging);
    return match ? Number(match[1]) : null;
}

const badging = readBadging(apk);
const nativeCode = badging === null ? null : nativeCodeOf(badging);
const versionCode = badging === null ? null : versionCodeOf(badging);
if (badging === null) {
    console.warn('  跳过 ABI / versionCode 校验：build-tools 里找不到可用的 aapt2。');
} else {
    if (nativeCode.length !== 1 || nativeCode[0] !== 'arm64-v8a') {
        throw new Error(
            `APK 的 native-code 不是单一 arm64-v8a：${nativeCode.join(', ') || '(空)'}——检查依赖或 staging 里的 .so ABI。`,
        );
    }
    // versionCode 必须**等于** pubspec 的 build number：分 ABI 时 Flutter 会再加
    // `ABI 系数*1000`（arm64-v8a = +2000），本项目用 force-version-code-ignoring-abi
    // 关掉了它。这条断言把"偏移又生效"挡在出包这一步，而不是等发版时才发现版本号对不上。
    const pubspec = fs.readFileSync(path.resolve('pubspec.yaml'), 'utf8');
    const buildNumberMatch = /^version:\s*[^\s+]+\+(\d+)\s*$/m.exec(pubspec);
    const buildNumber = buildNumberMatch ? Number(buildNumberMatch[1]) : NaN;
    if (!Number.isInteger(buildNumber)) {
        throw new Error('pubspec.yaml 的 version 缺少 +<build number>，无法核对 APK 的 versionCode。');
    }
    if (versionCode !== buildNumber) {
        throw new Error(
            `APK 的 versionCode ${versionCode} ≠ pubspec.yaml 的 +${buildNumber}——ABI 偏移又生效了` +
                '（Flutter 分片会给 versionCode 加 ABI 系数*1000，arm64-v8a 是 +2000）。' +
                '检查 --android-project-arg force-version-code-ignoring-abi=true 是否还在。',
        );
    }
    console.log(`  versionCode ${versionCode} = pubspec +${buildNumber}（ABI 偏移已关闭）`);
}

console.log(
    `\nAPK: ${apk}${nativeCode ? ` (native-code ${nativeCode.join(', ')}${versionCode === null ? '' : `, versionCode ${versionCode}`})` : ''}`,
);
