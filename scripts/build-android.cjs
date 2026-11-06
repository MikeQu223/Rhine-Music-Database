// Android（arm64-v8a）打包：准备资源与 Node 运行时 → CMake 配置 → Gradle 出包 → 签名。
// 项目根存在 Rhine-Music-Database.key 与同名 .password.key 时改用发布密钥，产物加
// -signed 后缀；否则沿用工作区内的调试密钥。全程不写工作区以外的路径（Gradle/Android
// 的用户目录都改指到 output/android-work 下）。
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
// 发布密钥：两个文件同时存在才启用（缺密码文件时安静回退到调试密钥）。
// 它们是 .gitignore 覆盖的本地文件，脚本绝不把密码读进日志或拼进 pass: 字面量。
const releaseKeystore = path.resolve('Rhine-Music-Database.key');
const releasePasswordFile = path.resolve('Rhine-Music-Database.key.password.key');
const useReleaseKey = fs.existsSync(releaseKeystore) && fs.existsSync(releasePasswordFile);
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
    // Android 的 3D 源是独立副本 Assets/android-3d/：用同一套导出与烘焙脚本重新生成到
    // output/android-3d/，再由 package-resources.cjs 优先取这里的文件。副本目前与公共源
    // 逐字节一致；将来改副本只影响 Android，桌面与 iOS 仍走 output/resources。
    const android3dOutput = path.resolve('output/android-3d');
    fs.rmSync(android3dOutput, { recursive: true, force: true });
    const android3dEnv = {
        ...process.env,
        RHINE_3D_SOURCE: path.resolve('Assets/android-3d'),
        RHINE_3D_OUTPUT: android3dOutput,
        // Android 专属的烘焙变体（桌面 / iOS 不设这些变量，产物逐字节不变）：
        //   LIGHT_HALF —— 光场空间分辨率减半（层数不动），5.3 MB → 1.33 MB，有机会留在 L2；
        //   NORMAL_RGBA8 —— 法线响应 8 位，逐像素带宽减半。
        // 后者必须与 CMakeLists 的 RHINE_ANDROID_NORMAL_RGBA8 保持一致，否则纹理尺寸对不上。
        //
        // ETC2 已停：那套手写编码器有字节序（ETC2 要求大端块）与 individual 模式位布局
        // 两处缺陷，标准解码器实测 PSNR 5.7 dB、真机是花屏，运行时也默认关闭
        // （RHINE_SURFACE_ETC2=1 才读）。留着烘焙只是每次白花十几秒再打 700 KB 死重。
        // 换成可靠编码器（etcpak / etc2comp）后，把 RHINE_BAKE_ETC2 加回来即可。
        RHINE_BAKE_LIGHT_HALF: '1',
        RHINE_BAKE_NORMAL_RGBA8: '1',
    };
    const python = process.env.PYTHON || 'python3';
    run(python, ['scripts/export-assets.py'], { env: android3dEnv });
    run(python, ['scripts/bake-archive-lighting.py'], { env: android3dEnv });
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

/**
 * 包源目录的 build.gradle 是「Qt 模板副本 + 末尾追加段」：Qt 升级换了模板就必须重新生成，
 * 否则新模板里的字段再也进不了包，而构建会安静地沿用旧配置。这里只比对前缀，
 * 追加段（第三方依赖）随仓库自由演进。
 */
function gradleTemplateInSync() {
    const template = path.join(kit, 'src/android/templates/build.gradle');
    const ours = path.resolve('Qt/android/build.gradle');
    if (!fs.existsSync(template)) {
        // 少数发行套件不带模板源码，没法比对，放行即可（构建时 androiddeployqt 仍会用它自己的）。
        return true;
    }
    if (!fs.existsSync(ours)) {
        return false;
    }
    return fs.readFileSync(ours, 'utf8').startsWith(fs.readFileSync(template, 'utf8'));
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
    add(
        'Qt/android/build.gradle',
        gradleTemplateInSync()
            ? '与 kit 的 Gradle 模板一致'
            : '与 kit 模板不一致（跑 android-gradle-sync.cjs）',
        gradleTemplateInSync(),
    );
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

if (!gradleTemplateInSync()) {
    throw new Error(
        `Qt/android/build.gradle 缺失，或前缀不再等于 kit 的 Gradle 模板：\n` +
            `  ${path.join(kit, 'src/android/templates/build.gradle')}\n` +
            '这个文件是「Qt 模板副本 + 末尾追加段（第三方依赖）」的组合，Qt 升级后必须重新生成：\n' +
            '  node scripts/android-gradle-sync.cjs\n' +
            '追加段在「// ===== RHINE additions below」之后，会被原样保留。',
    );
}

prepareNodeMobile();
prepareResources();
if (prepareOnly) {
    process.exit(0);
}

// 用发布密钥时不必再生成调试密钥；--unsigned 本来也不签名。
if (!useReleaseKey && !unsigned) {
    ensureKeystore();
}
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
        // CMake 的 set(... CACHE STRING ...) 不会覆盖已有缓存：本机 output/android-build
        // 里一旦存过旧的 LTO 档位，源码改默认值也不会生效，而 CI 每次干净 checkout
        // 一定拿到新默认值 —— 两边会用不同的 LTO 编出不同的包。每次 configure
        // 都显式传值即可让增量构建与 CI 干净构建对齐。RHINE_ANDROID_LTO 可覆盖。
        `-DRHINE_ANDROID_LTO=${process.env.RHINE_ANDROID_LTO || 'full'}`,
        // 这一项与 prepareResources 里硬编码的烘焙产物形态必须一致
        // （RHINE_BAKE_NORMAL_RGBA8=1）：缓存漂移会让法线位宽与 shader 解码分支
        // 对不上，历史上直接导致过启动崩溃，所以每次 configure 都钉死。
        // QUAD_FOLD 只影响观感、且允许手动 -DRHINE_ANDROID_QUAD_FOLD=OFF，不在这里钉。
        '-DRHINE_ANDROID_NORMAL_RGBA8=ON',
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
// --unsigned 出来的是未签名包，不能叫 -signed；用调试密钥时保持原有文件名。
const signSuffix = useReleaseKey && !unsigned ? '-signed' : '';
const signed = path.resolve(
    `output/RhineMusicDatabase-${packageIdentity(version)}-android-${abi}${signSuffix}.apk`,
);

/**
 * 发布密钥的 apksigner 参数。
 *
 * 密码走 file: 而不是 pass: —— 不进命令行、不进日志、不需要转义特殊字符。
 * apksigner 对同一个 file: 按行依次取多个密码：只给 --ks-pass 时它会用
 * keystore 密码解私钥（PKCS12 的常规做法），不会触发交互式提示；若密码文件
 * 有两行（第一行 store、第二行 key），才同时给 --key-pass 让它读第二行。
 */
function releaseSignArgs() {
    const lines = fs
        .readFileSync(releasePasswordFile, 'utf8')
        .split(/\r?\n/)
        .filter((line) => line.length > 0).length;
    const pass = `file:${releasePasswordFile}`;
    const args = [
        '--ks',
        releaseKeystore,
        // 扩展名是 .key，apksigner 无法按后缀推断容器类型。
        '--ks-type',
        process.env.RHINE_SIGN_KS_TYPE || 'PKCS12',
        '--ks-pass',
        pass,
    ];
    if (lines >= 2) {
        args.push('--key-pass', pass);
    }
    // keystore 只有一个 key 时 apksigner 自动选择；多个 key 用环境变量指定。
    const alias = process.env.RHINE_SIGN_KEY_ALIAS;
    if (alias) {
        args.push('--ks-key-alias', alias);
    }
    return args;
}

if (unsigned) {
    fs.copyFileSync(unsignedApk, signed);
} else {
    // zipalign 必须在签名之前：签名后再对齐会破坏 v2/v3 签名块。
    run(path.join(buildTools, 'zipalign'), ['-p', '-f', '4', unsignedApk, aligned]);
    console.log(
        useReleaseKey
            ? '使用项目根发布密钥签名（产物带 -signed 后缀）'
            : '使用工作区调试密钥签名',
    );
    run(path.join(buildTools, 'apksigner'), [
        'sign',
        ...(useReleaseKey
            ? releaseSignArgs()
            : [
                  '--ks',
                  keystore,
                  '--ks-key-alias',
                  'rhine-debug',
                  '--ks-pass',
                  'pass:android',
                  '--key-pass',
                  'pass:android',
              ]),
        '--min-sdk-version',
        '26',
        '--out',
        signed,
        aligned,
    ], { stdio: ['ignore', 'inherit', 'inherit'] });
    // stdin 给 EOF：万一发布密钥的私钥密码与库密码不同，apksigner 会想交互提示，
    // 构建脚本不能挂在那里等输入；它会读到 EOF 并给出明确的错误。
}
run(process.env.PYTHON || 'python3', ['scripts/audit-android.py', signed, '--sdk', sdk]);
console.log(`Android APK: ${signed}`);
