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
// 仓库：模板已声明 google() 与 mavenCentral()。Clarity 与 Bugly 都在 Maven Central，
// Clarity 的传递依赖 installreferrer 在 Google Maven，两个仓库都够用，无需再补。

dependencies {
    // Microsoft Clarity（会话行为分析）。版本写死而不是 3.+：动态版本会让同一份源码
    // 在不同时间解析出不同产物，CI 的缓存键也抓不到这种变化。
    implementation 'com.microsoft.clarity:clarity:3.10.0'

    // 腾讯 Bugly（Java 崩溃与 ANR 上报）。同样钉死版本；只有中国大陆用户在许可闸门
    // 里点过「同意」才会初始化，见 ConsentStore.startSdks()。AAR 的清单只声明 uses-sdk，
    // 不带任何权限，POM 也没有传递依赖。
    implementation 'com.tencent.bugly:crashreport:4.1.9.7'

    // Clarity 是 Kotlin 写的：kotlin-stdlib 只随它的 runtime 变体传递，编译期不在
    // classpath 上。当前只用 ClarityConfig(String) 与 Clarity.initialize，javac 不解析
    // kotlin 类型也编得过；这条 compileOnly 是防将来调用带 kotlin.* 签名的成员时，
    // 报出「cannot access kotlin.jvm.functions.Function2」这种没头没脑的错误。
    // compileOnly 不进 APK，运行期的 stdlib 由 Clarity 自己传递进来。
    compileOnly 'org.jetbrains.kotlin:kotlin-stdlib:1.8.0'
}

// Bugly 的 AAR 自带 5 个 ABI 的 libBugly_Native.so。工程只按 qtTargetAbiList 打包，
// defaultConfig 里的 ndk.abiFilters 会过滤一次；这里再显式排除用不到的 ABI，
// 免得 AGP 升级后悄悄把多余的 .so 混进 APK（scripts/audit-android.py 只允许一个 ABI）。
// 排除项是按当前打包目标算出来的，将来支持多 ABI 时不必改这段。
android {
    packagingOptions {
        jniLibs {
            def qtAbis = qtTargetAbiList.split(',')*.trim().toSet()
            ['armeabi', 'armeabi-v7a', 'x86', 'x86_64', 'arm64-v8a'].each { abi ->
                if (!qtAbis.contains(abi)) {
                    excludes.add("**/\${abi}/libBugly_Native.so".toString())
                }
            }
        }
    }
}

// 体积裁剪一：APK 里最大的几块里，有一批 Android 侧永远用不到的 Qt 库。
// 判据是实际 import——Qt/qml/*.qml 只 import QtQuick、QtQuick.Window、QtQuick.Dialogs，
// C++ 侧没有 QQuickStyle::setStyle、也没有任何 QuickControls 类型。
//   · QuickControls2 的五套样式包（FluentWinUI3/Imagine/Material/Universal/Fusion 及其
//     StyleImpl）共约 13 MB，是 androiddeployqt 按 QML 依赖图整包带进来的；
//   · qmltooling 的 qmldbg_*（约 1 MB）是开发期调试器，release 不需要；
//   · Qt.labs.folderlistmodel 没有任何 QML import 它。
// 刻意保留 Qt6QuickControls2 / QuickControls2Impl / QuickControls2Basic（约 2.5 MB）：
// 那是 QQC2 的默认样式兜底。万一将来某条 import 链把它拉进来，少一个 .so 就是启动即崩，
// 省 2.5 MB 换一个必崩风险不划算。真要连它们一起删，先确认所有 QML 与 C++ 都不碰
// QtQuick.Controls，并真机冷启动验证一次。
android {
    packagingOptions {
        jniLibs {
            // 与上面 Bugly 那段一致用 addAll：excludes 是可变 Set，用 += 会走
            // 属性读改写，AGP 版本一换就可能只在某些配置下生效。
            // 注意 android-gradle-sync.cjs 里这段在 JS 模板字符串内，注释里不能出现反引号。
            excludes.addAll([
                '**/libQt6QuickControls2FluentWinUI3*.so',
                '**/libQt6QuickControls2Imagine*.so',
                '**/libQt6QuickControls2Material*.so',
                '**/libQt6QuickControls2Universal*.so',
                '**/libQt6QuickControls2Fusion*.so',
                '**/libplugins_qmltooling_*.so',
                '**/libQt6LabsFolderListModel*.so',
            ])
        }
    }
}

// 体积裁剪二：把 .so 压进 APK。
// Qt 模板的 gradle.properties 写的是 legacyPackaging=false，即 extractNativeLibs=false：
// 库以 STORED 存进 APK、运行时直接从 APK mmap——启动最快、安装后不额外占空间，
// 但 152 MB 的 lib 目录**完全不压缩**，占了整包九成。改成 true 后 AGP 用 deflate 压缩，
// 下载体积大约降到六成；代价是安装时解压到 /data/app/.../lib/，占用变成「APK + 解压后」，
// 首次启动多一次解压。对 sideload 分发，下载体积比安装后占用更重要，所以默认开。
// 改回：RHINE_ANDROID_LEGACY_PACKAGING=0 重建。
android {
    packagingOptions {
        jniLibs {
            def rhineLegacy = System.getenv('RHINE_ANDROID_LEGACY_PACKAGING') ?: '1'
            useLegacyPackaging = rhineLegacy != '0'
        }
    }
}

// 体积裁剪三：R8 收缩。
// 只开收缩、**不开混淆**（-dontobfuscate）。所有 JNI 入口（QtActivity/QtNative、
// RhineMediaService、Consent*）都是按类名与方法名字符串查找的，混淆一旦改到名字就是
// 启动即崩；这点体积不值得拿启动换。shrinkResources 依赖 minifyEnabled，
// 它删的是没有任何 R. 引用的资源条目。
// 规则在配置期写到 projectDir，不依赖 androiddeployqt 是否把 Qt/android/ 下的
// 额外文件拷过来（它只 merge src/res/assets/清单这几类）。
// 关掉：RHINE_ANDROID_R8=0 重建。
android {
    buildTypes {
        release {
            def rhineR8 = System.getenv('RHINE_ANDROID_R8') ?: '1'
            minifyEnabled = rhineR8 != '0'
            shrinkResources = rhineR8 != '0'
            if (rhineR8 != '0') {
                def rhineRules = new File(projectDir, 'rhine-r8.pro')
                rhineRules.text = '''# Generated by Qt/android/build.gradle on every configure - do not edit here.
# R8 只做收缩与优化，不改名：JNI 侧全部按字符串查找类和方法。
-dontobfuscate

# Qt 的 Java 层（QtActivity / QtNative / QtService / QtLoader 等）由 C++ 经 JNI 调用，
# 清单里也按类名注册。
-keep class org.qtproject.** { *; }

# 本工程自己的 Java/Kotlin：ConsentActivity 是唯一 LAUNCHER、RhineApplication 由清单指定、
# RhineMediaService 是前台服务，全部按名字实例化。
-keep class rhine.music.database.** { *; }

# 两个 SDK 都依赖反射与注解，且源码不在本仓库内，无法静态确认哪些成员被用到。
-keep class com.microsoft.clarity.** { *; }
-keep class com.tencent.bugly.** { *; }
-dontwarn com.microsoft.clarity.**
-dontwarn com.tencent.bugly.**

# native 方法所在的类不能被删或改名，否则 UnsatisfiedLinkError。
-keepclasseswithmembernames class * { native <methods>; }
'''
                proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'),
                        rhineRules.name
            }
        }
    }
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
