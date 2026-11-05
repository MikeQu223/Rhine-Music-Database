// 重新生成 Qt/android/build.gradle：把文件上半部分的「Qt 模板副本」换成当前 Android kit 里的
// 模板，`// ===== RHINE additions below` 之后的追加段原样保留。
//
// 为什么需要它：Qt 的 Gradle 工程由 androiddeployqt 从 <kit>/src/android/templates/build.gradle
// 复制到构建目录，而包源目录（QT_ANDROID_PACKAGE_SOURCE_DIR = Qt/android）里的同名文件会整份
// 覆盖它——想加第三方依赖只能整份接管。为了让「模板变了」这件事不至于静默，构建脚本会校验
// 这个文件的前缀与 kit 模板逐字节一致（见 scripts/build-android.cjs 的 checkGradleTemplate），
// 升级 Qt 后跑一次本脚本即可修好。
//
// 用法：node scripts/android-gradle-sync.cjs
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const target = path.join(root, 'Qt/android/build.gradle');
// 标记行：它之前是 Qt 模板，之后是我们自己的内容。
const marker = '// ===== RHINE additions below';

// 首次生成（文件被删掉）时用的追加段；正常情况下以仓库里的文件为准。
const bootstrapAdditions = `${marker}: everything above is Qt's template, verbatim =====
//
// Qt 的 Gradle 工程由 androiddeployqt 从 <kit>/src/android/templates/build.gradle 复制而来，
// 包源目录（QT_ANDROID_PACKAGE_SOURCE_DIR = Qt/android）里的同名文件会整份覆盖它。
// 所以本文件 = 模板的逐字节副本 + 末尾追加段：
//   · 上半部分不要手改；升级 Qt 后跑 node scripts/android-gradle-sync.cjs 重新生成；
//   · scripts/build-android.cjs 在构建前校验这段前缀，模板一变就直接报错，
//     不会静默沿用上一版的 Gradle 配置。
// 仓库：模板已声明 google() 与 mavenCentral()，Clarity 在 Maven Central，其传递依赖
// installreferrer 在 Google Maven，两个仓库都够用，无需再补。

dependencies {
    // Microsoft Clarity（会话行为分析）。版本写死而不是 3.+：动态版本会让同一份源码
    // 在不同时间解析出不同产物，CI 的缓存键也抓不到这种变化。
    implementation 'com.microsoft.clarity:clarity:3.10.0'

    // Clarity 是 Kotlin 写的：kotlin-stdlib 只随它的 runtime 变体传递，编译期不在
    // classpath 上。当前只用 ClarityConfig(String) 与 Clarity.initialize，javac 不解析
    // kotlin 类型也编得过；这条 compileOnly 是防将来调用带 kotlin.* 签名的成员时，
    // 报出「cannot access kotlin.jvm.functions.Function2」这种没头没脑的错误。
    // compileOnly 不进 APK，运行期的 stdlib 由 Clarity 自己传递进来。
    compileOnly 'org.jetbrains.kotlin:kotlin-stdlib:1.8.0'
}
`;

/** kit 的查找顺序与 build-android.cjs 保持一致：显式覆盖 → 仓库自建 → Qt 安装器默认位置。 */
function findKit() {
    if (process.env.RHINE_ANDROID_QT) {
        return process.env.RHINE_ANDROID_QT;
    }
    const built = path.join(root, 'output/dependencies/qt-android');
    if (fs.existsSync(path.join(built, 'bin/qt-cmake'))) {
        return built;
    }
    return path.join(os.homedir(), 'Qt/6.12.0/android_arm64_v8a');
}

const kit = findKit();
const template = path.join(kit, 'src/android/templates/build.gradle');
if (!fs.existsSync(template)) {
    console.error(`找不到 kit 里的 Gradle 模板：${template}`);
    console.error('先构建 Android kit（npm run build:qt:android），或用 RHINE_ANDROID_QT 指向已装的 kit。');
    process.exit(1);
}

const templateText = fs.readFileSync(template, 'utf8');
const current = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : '';
let additions;
if (current.includes(marker)) {
    additions = current.slice(current.indexOf(marker));
} else if (current) {
    console.error(`${path.relative(root, target)} 里找不到标记行「${marker}」，放弃覆盖以免丢内容。`);
    process.exit(1);
} else {
    additions = bootstrapAdditions;
    console.log('追加段缺失，使用脚本内置的默认内容。');
}

const next = `${templateText}\n${additions}`;
if (next === current) {
    console.log(`${path.relative(root, target)} 已与 ${path.relative(root, template)} 同步。`);
    process.exit(0);
}

fs.writeFileSync(target, next);
console.log(`已按 ${path.relative(root, template)} 重新生成 ${path.relative(root, target)}（追加段保留）。`);
