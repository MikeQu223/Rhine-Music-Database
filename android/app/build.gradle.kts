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
// 发布签名（DEDUP-09）：fail-closed，绝不回退 debug 签名。
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
// 缺文件 / 缺键 / storeFile 指向的 keystore 不存在时：
//   * 标准 release 入口（assembleRelease / bundleRelease / build …）→ 配置阶段抛 GradleException；
//   * 任务名缩写（如 aR）或包装任务 → 任务图就绪时抛 GradleException，仍早于任何任务执行；
//   * 纯 debug 构建 → 不抛异常，debug 继续用 AGP 默认 debug 密钥。
// release 任何路径都拿不到 debug 签名配置；材料缺失时标准入口（assemble/bundle/install/
// package/publish 及其 Release 变体）在配置阶段失败，缩写/包装任务由图守卫覆盖，均早于任何
// 任务执行；不会静默产出 debug 签名或未签名的 release 包。
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

// 只有 release 相关任务才需要签名材料；debug 构建不因材料缺失而失败。
val releaseSigningAggregateTasks = setOf("build", "assemble", "bundle", "install", "package", "publish")
val releaseSigningRequired: Boolean = gradle.startParameter.taskNames.any { requested ->
    val taskName = requested.substringAfterLast(':')
    taskName.contains("Release") || taskName in releaseSigningAggregateTasks
}

val releaseSigningHint: String =
    "请在 ${releaseSigningPropertiesFile.absolutePath}、-PrhineSigningProperties=<path>" +
        " 或 RHINE_ANDROID_SIGNING_PROPERTIES=<path> 指向的文件中提供" +
        " ${releaseSigningKeys.joinToString("、")}。" +
        " 拒绝回退 debug 签名，也拒绝产出未签名的 release 包。"

val releaseSigningMessage: String? =
    releaseSigningProblem?.let { "release 签名未配置（fail-closed）: $it。$releaseSigningHint" }

// 第一道守卫：标准入口（assemble/bundle/install/package/publish 及其 Release 变体）在配置
// 阶段就失败。此时任务图尚未建立，不可能产出任何包。
val releaseSigningMessageAtConfiguration = releaseSigningMessage
if (releaseSigningRequired && releaseSigningMessageAtConfiguration != null) {
    throw org.gradle.api.GradleException(releaseSigningMessageAtConfiguration)
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

    buildTypes {
        release {
            // DEDUP-09：原 debug 回退赋值已删除；release 只允许使用上面的外部签名材料。
            if (releaseSigningProblem == null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// 第二道守卫：任务名缩写（如 aR）或包装任务在配置阶段看不出 release；这里在任务图就绪后、
// 任何任务执行之前按解析后的任务名再检查一次，throw 仍然早于打包。
val releaseSigningMessageAtGraph = releaseSigningMessage
if (releaseSigningMessageAtGraph != null) {
    gradle.taskGraph.whenReady {
        if (allTasks.any { task -> task.project == project && task.name.contains("Release") }) {
            throw org.gradle.api.GradleException(releaseSigningMessageAtGraph)
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
//   cmake -S Qt -B output/qt-android-flutter + ninja apk（androiddeployqt --no-build）
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
// 局部 jar 补丁必须挂在构建里（审查 MUST-3）：
// androiddeployqt 每次 Qt 构建都会用 SDK 里的 stock Qt6Android.jar 覆盖
// <deploy>/libs/Qt6Android.jar，如果补丁只靠人手跑一次，下一次 Qt 重建就静默回退成
// stock——"设备上装的是补丁类"这件事就再也没有证据。这里让 preBuild 依赖
// android/app/javapatch/apply.sh：它只改本卡 deploy（不碰全局 SDK / 冻结产物），
// 幂等（已打成期望字节就跳过），并且**编译出的 class 内容 sha256 必须等于
// android/app/javapatch/EXPECTED.sha256**，否则构建失败。
val javapatchDir = File(project.projectDir, "javapatch")
val patchQtAndroidJar = tasks.register<Exec>("patchQtAndroidJar") {
    description = "把 android/app/javapatch 的局部补丁打进本卡 Qt deploy 的 Qt6Android.jar 并校验字节"
    group = "qt"
    workingDir = javapatchDir
    commandLine("bash", File(javapatchDir, "apply.sh").absolutePath, qtAndroidDeployDir.absolutePath)
    // 幂等脚本，跳过时只有几百毫秒；不做 up-to-date 缓存，避免"jar 被 androiddeployqt 换掉
    // 但 gradle 认为没变化"这一类假通过。
    outputs.upToDateWhen { false }
}

val qtAndroidLibsDir = File(qtAndroidDeployDir, "libs")
val qtAndroidAbiDir = File(qtAndroidLibsDir, "arm64-v8a")
val qtRuntimeLibsXml = File(qtAndroidDeployDir, "res/values/libs.xml")

if (!qtAndroidAbiDir.isDirectory) {
    throw org.gradle.api.GradleException(
        "Qt 场景运行时不在 " + qtAndroidDeployDir.absolutePath + "（缺 libs/arm64-v8a）。" +
            "先用源码重建本分支的 Qt 运行时：" +
            " cmake -S Qt -B output/qt-android-flutter" +
            " -G Ninja -DCMAKE_TOOLCHAIN_FILE=<qt-android>/lib/cmake/Qt6/qt.toolchain.cmake" +
            " -DQT_HOST_PATH=/usr -DQT_HOST_PATH_CMAKE_DIR=/usr/lib/cmake" +
            " -DQT_QMAKE_TARGET_MKSPEC=android-clang -DANDROID_ABI=arm64-v8a" +
            " -DANDROID_PLATFORM=android-28 -DANDROID_NDK_ROOT=/home/aibeto/Android/Sdk/ndk/30.0.16248370" +
            " -DANDROID_SDK_ROOT=/home/aibeto/Android/Sdk -DCMAKE_BUILD_TYPE=Release" +
            " -DCMAKE_MAKE_PROGRAM=/usr/bin/ninja" +
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
