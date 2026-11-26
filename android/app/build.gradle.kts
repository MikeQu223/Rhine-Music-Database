// Gradle Kotlin DSL 会在 Project 上生成 `val Project.`java`: JavaPluginExtension` 扩展属性，
// 因此表达式位置的 `java.util.Properties()` / `java.io.File(...)` 会被解析成对该 accessor 的
// 成员访问（Unresolved reference 'util' / 'io'）。改为导入具体类型并使用非限定名。
import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// 发布签名（DEDUP-09）：有签名材料就签，没有就产出未签名 release。
//
// 签名材料只从版本控制之外读取，路径按顺序取第一个非空者：
//   1. Gradle 属性  -PrhineSigningProperties=<路径>
//   2. 环境变量     RHINE_ANDROID_SIGNING_PROPERTIES=<路径>
//   （相对路径统一按 android/ 解析，与本文件默认的 keystore.properties 同级）
//   3. android/keystore.properties（不入库，见 android/.gitignore）
// 文件内必须提供 storeFile / storePassword / keyAlias / keyPassword 四个键；
// storeFile 可用绝对路径，也可用相对该 properties 文件所在目录的路径。
// 仓库内不保存任何口令、别名或密钥路径；此处不生成、不下载、不伪造密钥材料。
//
// 缺文件 / 缺键 / storeFile 指向的 keystore 不存在时：不注册 release signingConfig，
// AGP 直接产出 app-release-unsigned.apk（Flutter 工具会复制成 app-release.apk），
// 只在配置阶段打一条警告。任何路径都不会回退到 debug 签名。
// ---------------------------------------------------------------------------
val releaseSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

val releaseSigningPropertiesFile: File =
    project.findProperty("rhineSigningProperties")?.toString()?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
        ?: System.getenv("RHINE_ANDROID_SIGNING_PROPERTIES")?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
        ?: rootProject.file("keystore.properties")

val releaseSigningValues: Map<String, String>? =
    if (!releaseSigningPropertiesFile.isFile) {
        null
    } else {
        val loaded = Properties()
        releaseSigningPropertiesFile.reader().use { loaded.load(it) }
        releaseSigningKeys.associateWith { (loaded.getProperty(it) ?: "").trim() }
    }

val releaseSigningMissingKeys: List<String> =
    releaseSigningValues?.filterValues { it.isEmpty() }?.keys?.toList() ?: releaseSigningKeys

val releaseSigningKeystoreFile: File? =
    releaseSigningValues?.get("storeFile")?.takeIf { it.isNotEmpty() }?.let { declared ->
        val candidate = File(declared)
        if (candidate.isAbsolute) candidate else File(releaseSigningPropertiesFile.parentFile, declared)
    }

val releaseSigningKeystoreMissing: Boolean = releaseSigningKeystoreFile?.isFile != true

val releaseSigningProblem: String? = when {
    releaseSigningValues == null ->
        "签名配置文件不存在: ${releaseSigningPropertiesFile.absolutePath}"
    releaseSigningMissingKeys.isNotEmpty() ->
        "签名配置缺少键: ${releaseSigningMissingKeys.joinToString(", ")}（文件 ${releaseSigningPropertiesFile.absolutePath}）"
    releaseSigningKeystoreMissing ->
        "keystore 不存在: ${releaseSigningKeystoreFile?.absolutePath}"
    else -> null
}

val releaseSigningHint: String =
    "如需签名：在 ${releaseSigningPropertiesFile.absolutePath}、-PrhineSigningProperties=<path>" +
        " 或 RHINE_ANDROID_SIGNING_PROPERTIES=<path> 指向的文件中提供" +
        " ${releaseSigningKeys.joinToString("、")}。不会回退 debug 签名。"

val releaseSigningMessage: String? =
    releaseSigningProblem?.let { "release 未配置签名，将产出未签名 APK: $it。$releaseSigningHint" }

// 只告警、不阻断：未签名 release 是允许的产物（CI / 侧载验证包）。
if (releaseSigningMessage != null) {
    logger.warn(releaseSigningMessage)
}

// 说明：签名材料在配置阶段读取。若将来启用 configuration cache，Gradle 会把这里读到的文件与
// 环境变量作为配置输入；口令只来自仓库外的 properties 或环境变量，绝不写入仓库。

android {
    namespace = "rhine.music.database"
    // DEDUP-43：SDK 三轴显式 pin 到 Qt 构建真值，不随 flutter.* 工具链漂移。
    // 真值来源：output/android-build/Qt/android-build/gradle.properties
    // （androidCompileSdkVersion / qtMinSdkVersion / qtTargetSdkVersion）。
    // DEDUP-43：compileSdk 对齐 Qt androidCompileSdkVersion=android-36。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "rhine.music.database"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // DEDUP-43：minSdk 对齐 Qt qtMinSdkVersion=28（显式 pin，不随 flutter.* 漂移）。
        minSdk = 28
        // DEDUP-43：targetSdk 对齐 Qt qtTargetSdkVersion=36（显式 pin，不随 flutter.* 漂移）。
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // release 签名配置只在材料完整时注册；材料缺失时守卫（配置阶段 + android{} 之后的任务
    // 图阶段）会抛异常，所以不注册也绝不会产出 debug 签名或未签名的 release 包。
    if (releaseSigningProblem == null) {
        signingConfigs {
            create("release") {
                storeFile = releaseSigningKeystoreFile
                storePassword = releaseSigningValues?.get("storePassword")
                keyAlias = releaseSigningValues?.get("keyAlias")
                keyPassword = releaseSigningValues?.get("keyPassword")
            }
        }
    }

    // 内嵌 Node 运行时宿主（cpp/node_host.cpp）：Flutter 侧要跑 MusicBridge 的
    // ios-runtime.cjs，就必须自己把 libnode.so 的 node::Start 拉起来。只编这一个
    // 很小的 JNI 库，不接管 Qt 的 CMake 工程。
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            // DEDUP-09：仍不回退 debug 签名；材料完整就签，缺失则保持未签名。
            if (releaseSigningProblem == null) {
                signingConfig = signingConfigs.getByName("release")
            }
            // Flutter 的 Gradle 插件会为 release 打开 R8 与资源压缩（FlutterPlugin.kt:218-219）。
            // Qt 的 Java 桥与 QtLoader 按名字读取的资源都没有静态引用，必须显式保活，否则
            // release 包会在启动时停在 "Use local Qt libs is false" 并抛 UnsatisfiedLinkError。
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies { testImplementation("junit:junit:4.13.2") }

// ---------------------------------------------------------------------------
// Qt 场景运行时（PARITY QT-OVERLAY-128）：APK 里的 Qt 只在**同一个进程**里跑，
// 视图由 org.qtproject.qt.android.RhineQtView 挂进 Flutter 页面（platform view），
// 不是另一个 Activity/APK。
//
// 运行时来源必须是本仓库源码自己跑 androiddeployqt 的产物，而不是一个文件名带旧
// SHA 的 APK：目录里必须有 libs/arm64-v8a/（含 libRhineMusicDatabase_arm64-v8a.so）、
// assets/android_rcc_bundle.rcc 和 res/values/libs.xml（QtLoader 靠它反射读取
// qt_libs/bundled_libs/load_local_libs）。
//
// 解析顺序：
//   1. -PrhineQtAndroidDeployDir=<path>
//   2. RHINE_QT_ANDROID_DEPLOY_DIR 环境变量
//   3. 本卡默认构建目录（本工作树自己的 Qt Debug staging）
//
// 目录缺失时**配置阶段就失败**：没有 Qt 运行时的 APK 里，场景视图在运行时找不到
// QtNative 只能退化成空白——那正是本卡要取消的"假内嵌"，不允许静默产出。
// ---------------------------------------------------------------------------
// 默认目录 = 本仓库内的 Qt 侧 staging，不写死绝对路径：
//   rootProject.projectDir = <repo>/android → parentFile = <repo>
//   cmake -S . -B output/qt-android-flutter -DRHINE_FLUTTER_HOST_ONLY=ON
//   + 构建 RhineMusicDatabase_prepare_apk_dir（androiddeployqt --aux-mode 落 staging）
//   会在 output/qt-android-flutter/Qt/android-build 下落出 libs/ 与 res/values/libs.xml。
// 只指向**本树自己的** Qt staging：旧卡 builds/QT-OVERLAY-128 与
// builds/DEVICE-VISUAL-131 是冻结产物，默认回落到它们会让"改了 Qt 源码却装到旧 .so"
// 静默发生（那是假验证）。
val qtOverlayDefaultDeployDir: File =
    File(rootProject.projectDir.parentFile, "output/qt-android-flutter/Qt/android-build")

val qtAndroidDeployDir: File =
    (project.findProperty("rhineQtAndroidDeployDir") as String?)
        ?.takeIf { it.isNotBlank() }
        ?.let { rootProject.file(it) }
        ?: System.getenv("RHINE_QT_ANDROID_DEPLOY_DIR")
            ?.takeIf { it.isNotBlank() }
            ?.let { rootProject.file(it) }
        ?: qtOverlayDefaultDeployDir

// ---------------------------------------------------------------------------
// 局部 jar 补丁必须挂在构建里：androiddeployqt 每次 Qt 构建都会用 stock
// Qt6Android.jar 覆盖 deploy 里的那份，只靠人手跑一次就会静默回退。
// preBuild 依赖 javapatch/apply.sh：幂等，且编译出的 class sha256 必须等于
// EXPECTED.sha256，否则构建失败。
val javapatchDir = File(project.projectDir, "javapatch")
// javac 版本必须与录制 EXPECTED.sha256 的一致，但它不必是跑 Gradle 的那套 JDK。
// 通过 -PrhineJavacHome=<jdk> 显式传入；Gradle 的 Exec 会把它写进子进程环境，
// 不依赖 PATH（CI 里 PATH/Gradle daemon 环境都不可靠）。
val rhineJavacHome: String? =
    (project.findProperty("rhineJavacHome")?.toString()
        ?: System.getenv("RHINE_JAVAC_HOME"))?.trim()?.takeIf { it.isNotEmpty() }
val patchQtAndroidJar = tasks.register<Exec>("patchQtAndroidJar") {
    description = "把 android/app/javapatch 的局部补丁打进本卡 Qt deploy 的 Qt6Android.jar 并校验字节"
    group = "qt"
    workingDir = javapatchDir
    commandLine("bash", File(javapatchDir, "apply.sh").absolutePath, qtAndroidDeployDir.absolutePath)
    if (rhineJavacHome != null) {
        environment("RHINE_JAVAC", File(rhineJavacHome, "bin/javac").absolutePath)
    }
    // 幂等脚本，跳过时只有几百毫秒；不做 up-to-date 缓存，避免"jar 被 androiddeployqt 换掉
    // 但 gradle 认为没变化"这一类假通过。
    outputs.upToDateWhen { false }
}

val qtAndroidLibsDir = File(qtAndroidDeployDir, "libs")
val qtAndroidAbiDir = File(qtAndroidLibsDir, "arm64-v8a")
val qtRuntimeLibsXml = File(qtAndroidDeployDir, "res/values/libs.xml")

// 提示文案里的 SDK/NDK 必须在运行时推导，不能写死本机路径：
//   SDK：ANDROID_SDK_ROOT > ANDROID_HOME > AGP 自己解析出的 android.sdkDirectory；
//   NDK：ANDROID_NDK_ROOT，否则给 <sdk>/ndk/<已安装版本> 占位符（AGP 按版本号到那里找）。
// 宿主 Qt 与 ninja 无法可靠猜测，统一给 <qt-host> / <ninja> 占位符。都不传时用占位符，
// 命令仍是可直接照抄替换的形态。
val androidSdkForHint: String =
    (System.getenv("ANDROID_SDK_ROOT") ?: System.getenv("ANDROID_HOME"))
        ?.takeIf { it.isNotBlank() }
        ?: runCatching {
            (project.extensions.getByName("android") as com.android.build.gradle.BaseExtension)
                .sdkDirectory.absolutePath
        }.getOrNull()?.takeIf { it.isNotBlank() }
        ?: "<android-sdk>"

val androidNdkForHint: String =
    System.getenv("ANDROID_NDK_ROOT")?.takeIf { it.isNotBlank() }
        ?: "<sdk>/ndk/<installed-version>"

if (!qtAndroidAbiDir.isDirectory) {
    throw org.gradle.api.GradleException(
        "Qt 场景运行时不在 " + qtAndroidDeployDir.absolutePath + "（缺 libs/arm64-v8a）。" +
            "先用源码重建本分支的 Qt 运行时：" +
            " cmake -S . -B output/qt-android-flutter" +
            " -G Ninja -DCMAKE_TOOLCHAIN_FILE=<qt-android>/lib/cmake/Qt6/qt.toolchain.cmake" +
            " -DQT_HOST_PATH=<qt-host> -DQT_HOST_PATH_CMAKE_DIR=<qt-host>/lib/cmake" +
            " -DQT_QMAKE_TARGET_MKSPEC=android-clang -DANDROID_ABI=arm64-v8a" +
            " -DANDROID_PLATFORM=android-28 -DANDROID_NDK_ROOT=" + androidNdkForHint +
            " -DANDROID_SDK_ROOT=" + androidSdkForHint + " -DCMAKE_BUILD_TYPE=Release" +
            " -DCMAKE_MAKE_PROGRAM=<ninja>" +
            " -DRHINE_ANDROID_NODE_ROOT=<node-mobile> -DRHINE_ANDROID_RESOURCES=<android-resources>" +
            " 然后 ninja -j20 apk；或用 -PrhineQtAndroidDeployDir=<path> /" +
            " RHINE_QT_ANDROID_DEPLOY_DIR=<path> 指向已有产物。",
    )
}

if (!qtRuntimeLibsXml.isFile) {
    throw org.gradle.api.GradleException(
        "Qt 场景运行时缺 " + qtRuntimeLibsXml.absolutePath + "：QtLoader 靠 libs.xml 里的" +
            " qt_libs/bundled_libs/load_local_libs 决定加载哪些 .so，缺了会在启动时找不到 Qt。",
    )
}

// Qt 的 libs.xml 与 Flutter 自己那份 res/values/styles.xml 不同义，整目录并进 app 的
// res 会撞名（Qt 还有自己的 styles.xml）。这里只把 libs.xml 抄进独立的结果目录；文件
// 2.7KB，配置阶段完成即可，不需要额外任务依赖。
val qtRuntimeResDir = layout.buildDirectory.dir("qt-runtime-res").get().asFile
qtRuntimeResDir.resolve("values").mkdirs()
qtRuntimeLibsXml.copyTo(
    qtRuntimeResDir.resolve("values/libs.xml"),
    overwrite = true,
)

android {
    sourceSets.getByName("main") {
        // .so 走 jniLibs：AGP 按 ABI 目录收进 APK，并在安装时解包到 nativeLibraryDir。
        jniLibs.srcDir(qtAndroidLibsDir)
        // assets/android_rcc_bundle.rcc：Qt 的 Android 平台插件启动时从
        // assets:/android_rcc_bundle.rcc 注册资源（androidjnimain.cpp:475）。
        assets.srcDir(File(qtAndroidDeployDir, "assets"))
        // 只有 values/libs.xml 这一份 Qt 资源，见上面的取名理由。
        res.srcDir(qtRuntimeResDir)
    }

    packaging {
        jniLibs {
            // Qt 的插件加载按文件路径 dlopen（libplugins_platforms_qtforandroid_*.so
            // 与 imageformats/multimedia/tls 插件），必须真实解包到 nativeLibraryDir，
            // 不能只映射 APK 内的未压缩项。等价于 android:extractNativeLibs="true"。
            useLegacyPackaging = true
            // qmltooling 的 qmldbg_*（12 个，约 2.4 MB 未压缩）是 QML 调试器插件，
            // 不在 QtLoader 的部署清单（qt_libs / bundled_libs / load_local_libs）
            // 里，运行时从不被加载，release 包不需要。与 Qt 打包链路的规则一致：
            // scripts/android-gradle-sync.cjs「体积裁剪一」注入的同款 excludes。
            // 判据提醒：只排清单外的库。qt_libs 里的库（含五套 QQC2 样式与
            // Qt6LabsFolderListModel）一个都不能排——QtLoader 按 qt_libs 逐个
            // System.load，缺一个就是启动即崩，教训见 docs/ANDROID.md §5.2
            // 「排除清单的教训」。
            excludes.add("**/libplugins_qmltooling_*.so")
        }
    }
}

// 打补丁 + 校验必须早于任何消费 jar 的编译/打包任务。
tasks.named("preBuild") {
    dependsOn(patchQtAndroidJar)
}

dependencies {
    // Qt 的 Java 对端（QtNative/QtLoader/QtView/QtWindow…）必须与 app 在同一个
    // classloader 里：RhineQtView 直接 extends QtView，QtLoader 又要在同一个进程里
    // 启动 Qt。这里用 deploy 目录里的 jar，保证 Java 与 .so 来自同一次构建。
    implementation(fileTree(qtAndroidLibsDir) { include("*.jar") })
}

flutter {
    source = "../.."
}
