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

val releaseSigningPropertiesFile: java.io.File =
    project.findProperty("rhineSigningProperties")?.toString()?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
        ?: System.getenv("RHINE_ANDROID_SIGNING_PROPERTIES")?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
        ?: rootProject.file("keystore.properties")

val releaseSigningValues: Map<String, String>? =
    if (!releaseSigningPropertiesFile.isFile) {
        null
    } else {
        val loaded = java.util.Properties()
        releaseSigningPropertiesFile.reader().use { loaded.load(it) }
        releaseSigningKeys.associateWith { (loaded.getProperty(it) ?: "").trim() }
    }

val releaseSigningMissingKeys: List<String> =
    releaseSigningValues?.filterValues { it.isEmpty() }?.keys?.toList() ?: releaseSigningKeys

val releaseSigningKeystoreFile: java.io.File? =
    releaseSigningValues?.get("storeFile")?.takeIf { it.isNotEmpty() }?.let { declared ->
        val candidate = java.io.File(declared)
        if (candidate.isAbsolute) candidate else java.io.File(releaseSigningPropertiesFile.parentFile, declared)
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
    compileSdk = flutter.compileSdkVersion
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
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
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
flutter {
    source = "../.."
}
