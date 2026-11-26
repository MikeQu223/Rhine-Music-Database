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
//   npm run build:flutter:android -- --verbose    # 附上 flutter build 的 --verbose 全量日志
//                                                 # （可与 --debug 同用；也可用 RHINE_FLUTTER_VERBOSE=1）
//   npm run build:flutter:android -- --silent     # 本地默认已开 verbose，用它关掉
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
// Flutter 自己的 --verbose：只在 flutter build apk 这步生效，CMake/androiddeployqt
// 的日志量级由它们各自的开关控制。排查 APK 打包、Gradle 传参、资源合并时开它。
// 本地默认开（--silent 可关），CI 默认关（GITHUB_ACTIONS 下日志会被截断且拖慢上传）。
const flutterVerbose = process.argv.includes('--silent')
    ? false
    : process.argv.includes('--verbose') ||
      process.env.RHINE_FLUTTER_VERBOSE === '1' ||
      !process.env.GITHUB_ACTIONS;

// javapatch/EXPECTED.sha256 是用 javac 27.0.1 编出来的 class 字节录的；换 javac 大版本
// 一定对不上。这个数字和 EXPECTED.sha256 必须一起改。
const JAVAC_MAJOR = 27;

const sdk = toolchain.sdkRoot();
// CI 用 ANDROID_NDK_ROOT 钉住 30.0.16248370；本地若也显式设置，就以它为准，
// 避免机器上装了更新 NDK 时悄悄换版本、与 CI 产物不一致。
const ndk = process.env.ANDROID_NDK_ROOT || toolchain.ndkRoot(sdk);
const kit = process.env.RHINE_ANDROID_QT || path.resolve('output/dependencies/qt-android');
const hostQt = process.env.QT_ROOT_DIR || process.env.RHINE_HOST_QT || '/usr';

/** 读 Qt 前缀的版本（ConfigVersionImpl 里那一行 set(PACKAGE_VERSION "x.y.z")），读不到返回空串。 */
function qtVersion(prefix) {
    const file = path.join(prefix, 'lib/cmake/Qt6/Qt6ConfigVersionImpl.cmake');
    if (!fs.existsSync(file)) {
        return '';
    }
    const match = /set\(PACKAGE_VERSION\s+"([^"]+)"\)/.exec(fs.readFileSync(file, 'utf8'));
    return match ? match[1] : '';
}

// 宿主侧的 qmlcachegen 必须与 Android kit 同版本：它生成 AOT lookup 表时会把 kit
// 版本的 ABI 结构写死进 .cpp。发行版滚动更新到 6.12.1 后，生成的
// Type{...QTypeRevision()...} 与 6.12.0 头文件里的 Type{...IsComposite...} 字段顺序
// 不一致，编译期直接报 "no viable conversion from 'QTypeRevision' to 'IsComposite'"。
// 所以 kit 与宿主版本不同时，优先用 output/dependencies/qt-host-<kit 版本> 里钉住的
// 同版本工具。那个前缀按发行包布局放，root 下有 usr/ 一层。
const kitVersion = qtVersion(kit);
const hostVersion = qtVersion(hostQt);
const pinnedBase = kitVersion ? path.resolve(`output/dependencies/qt-host-${kitVersion}`) : '';
const pinnedRoot = pinnedBase ? path.join(pinnedBase, 'usr') : '';

// 钉住前缀按发行包布局放（root 下多一层 usr/）。它可能已经存在，也可能是新机器上
// 第一次构建——这时从 pacman 缓存里的同版本包现解（qt6-base + qt6-declarative）。
// 缓存里没有就明确报错并给出可复制的命令，绝不静默回退到版本不一致的宿主工具。
function ensurePinnedHostTools(base, root, version) {
    const marker = path.join(root, 'lib/cmake/Qt6QmlTools/Qt6QmlToolsConfig.cmake');
    if (fs.existsSync(marker)) {
        return true;
    }
    const cache = process.env.RHINE_PACMAN_CACHE || '/var/cache/pacman/pkg';
    // 只解真正需要的东西：qt6-declarative 的整个 usr/lib/qt6（含 qmlcachegen、
    // qmlaotstats 与 qml 模块）与工具 cmake 包；qt6-base 的三个 Tools 包。
    // qmlcachegen 运行时依赖的 Qt6Core/Qml/Network 实体挑最常需的几条。
    const packages = [
        [
            'qt6-declarative',
            'usr/lib/qt6',
            'usr/lib/cmake',
            'usr/lib/libQt6Qml.so.6.12.0',
            'usr/lib/libQt6QmlCompiler.so.6.12.0',
            'usr/lib/libQt6QmlModels.so.6.12.0',
            'usr/lib/libQt6QmlWorkerScript.so.6.12.0',
            'usr/lib/libQt6QmlMeta.so.6.12.0',
            'usr/lib/libQt6QmlLocalStorage.so.6.12.0',
        ],
        [
            'qt6-base',
            'usr/lib/cmake/Qt6CoreTools',
            'usr/lib/cmake/Qt6GuiTools',
            'usr/lib/cmake/Qt6WidgetsTools',
            'usr/lib/libQt6Core.so.6.12.0',
            'usr/lib/libQt6Gui.so.6.12.0',
            'usr/lib/libQt6Network.so.6.12.0',
        ],
    ];
    const archives = [];
    for (const [name, ...members] of packages) {
        const prefix = `${name}-${version}-`;
        const found = fs.existsSync(cache)
            ? fs
                  .readdirSync(cache)
                  .filter((file) => file.startsWith(prefix) && file.endsWith('.pkg.tar.zst'))
                  .sort()
                  .pop()
            : undefined;
        if (!found) {
            return false;
        }
        archives.push({ archive: path.join(cache, found), members });
    }
    fs.mkdirSync(base, { recursive: true });
    // 包内路径已经是 usr/lib/...，解到 base（= <pin> 根）才会落成 <pin>/usr/lib/...。
    for (const { archive, members } of archives) {
        const result = spawnSync('tar', ['-xf', archive, '-C', base, ...members], { stdio: 'inherit' });
        if (result.status !== 0) {
            return false;
        }
    }
    // qmlcachegen 的 RUNPATH 是 $ORIGIN/../（即 <root>/lib），发行包只装
    // libQt6X.so.6.12.0 这样的实体名，补上 .so.6 / .so 两条软链它才找得到。
    const libs = path.join(root, 'lib');
    for (const file of fs.readdirSync(libs)) {
        const match = /^(libQt6[^.]+\.so)\.(\d+\.\d+\.\d+)$/.exec(file);
        if (!match) {
            continue;
        }
        const soBase = match[1];
        const abi = `${soBase}.${match[2].split('.')[0]}`;
        for (const link of [abi, soBase]) {
            const target = path.join(libs, link);
            if (!fs.existsSync(target)) {
                fs.symlinkSync(file, target);
            }
        }
    }
    return fs.existsSync(marker);
}

const pinnedToolsUsable =
    hostVersion !== kitVersion && pinnedRoot !== '' && ensurePinnedHostTools(pinnedBase, pinnedRoot, kitVersion);
if (kitVersion !== '' && hostVersion !== kitVersion && !pinnedToolsUsable) {
    throw new Error(
        `宿主 Qt ${hostVersion} 与 Android kit ${kitVersion} 版本不一致，而钉住的同版本工具不可用。\n` +
            `  qmlcachegen 换版本会让 Qt native 编译失败（no viable conversion from 'QTypeRevision'）。\n` +
            `  修法：把 qt6-base / qt6-declarative 的 ${kitVersion} 发行包放进 pacman 缓存\n` +
            `  （默认 /var/cache/pacman/pkg，可用 RHINE_PACMAN_CACHE 指定），脚本会自动解到\n` +
            `  ${pinnedBase}；或用 QT_ROOT_DIR 指向一个 ${kitVersion} 的宿主 Qt。`,
    );
}
const hostTools = pinnedToolsUsable ? pinnedRoot : hostQt;
if (pinnedToolsUsable) {
    console.log(`宿主 Qt ${hostVersion} 与 kit ${kitVersion} 不同版本，改用钉住的宿主工具：${pinnedRoot}`);
}
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
//    hostTools 见上方：钉住时是 <pin>/usr，否则就是 hostQt。
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
        // 钉住同版本工具时，只覆盖 Qt6QmlTools（qmlcachegen/qmlaotstats 在这里）。
        // Core/Gui/Widgets 的宿主工具（moc/rcc/uic）在 6.12.0 与 6.12.1 之间没有
        // ABI 变化，继续用发行版那套；换掉它们反而要求压缩包里的每个工具
        // （syncqt 等）都被解出来，install-qt 布局下会缺文件。
        ...(pinnedToolsUsable
            ? [`-DQt6QmlTools_DIR=${path.join(hostTools, 'lib/cmake/Qt6QmlTools')}`]
            : []),
        '-DQT_QMAKE_TARGET_MKSPEC=android-clang',
        '-DANDROID_ABI=arm64-v8a',
        '-DANDROID_PLATFORM=android-28',
        `-DANDROID_NDK_ROOT=${ndk}`,
        `-DANDROID_SDK_ROOT=${sdk}`,
        `-DCMAKE_BUILD_TYPE=${buildType}`,
        `-DCMAKE_MAKE_PROGRAM=${ninja}`,
        // 显式钉住 cache 默认值：CMake 不会用源码里的新默认覆盖已有 cache。
        //   LTO / SIZE_OPT 与 build-android.cjs 同款，可用环境变量覆盖；
        //   NORMAL_RGBA8 必须与烘焙硬编码 RHINE_BAKE_NORMAL_RGBA8 同步，否则启动 qFatal。
        `-DRHINE_ANDROID_LTO=${process.env.RHINE_ANDROID_LTO || 'full'}`,
        `-DRHINE_ANDROID_SIZE_OPT=${process.env.RHINE_ANDROID_SIZE_OPT || 'oz'}`,
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
// androiddeployqt 是宿主侧工具，交叉编译的 kit 不产出它（qtbase 的工具门控
// qt_internal_return_unless_building_tools，-qt-host-path 模式下宿主工具全部
// 复用宿主 Qt）。官方安装器布局在 <host>/bin；发行版包会拆开：Fedora 在
// /usr/lib/qt6/bin，有的发行版在 /usr/lib64/qt6/bin——都不在 <host>/bin。
// PATH 兜底可能命中别的版本，所以排在显式路径之后；kit 的 bin 最后。
const deployQtCandidates = [
    path.join(hostQt, 'bin/androiddeployqt'),
    path.join(hostQt, 'lib/qt6/bin/androiddeployqt'),
    path.join(hostQt, 'lib64/qt6/bin/androiddeployqt'),
    executable('androiddeployqt'),
    path.join(kit, 'bin/androiddeployqt'),
];
const deployQt = deployQtCandidates.find(
    (candidate) => candidate !== '' && fs.existsSync(candidate),
);
if (!deployQt) {
    throw new Error(
        '找不到 androiddeployqt（宿主 Qt 或 Android kit 的 bin 目录）。\n' +
            `  已查：\n    ${deployQtCandidates.join('\n    ')}`,
    );
}
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
        ...(flutterVerbose ? ['--verbose'] : []),
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
