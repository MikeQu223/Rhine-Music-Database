# Android（arm64-v8a）构建装配。
#
# 与 IOS.cmake 对称：这里只做构建期装配——平台源码、Node 运行时、包元数据、内嵌资源；
# 运行期的行为（资源解包、横屏、沉浸式、生命周期）在 Qt/src/Android*.cpp 里。
#
# 与 iOS 的关键差别是资源不再落在包内目录，而是用 Qt 资源编进二进制：
# Android 的 assets/ 目录枚举依赖 AAssetDir，不保证列出子目录，靠构建期清单兜底会在
# 资源切片变化时静默漏文件；qrc 的枚举语义在所有平台上一致。

set(RHINE_ANDROID_NODE_ROOT
    ""
    CACHE PATH "Extracted nodejs-mobile Android release (bin/arm64-v8a/libnode.so)")
set(RHINE_ANDROID_RESOURCES
    "${CMAKE_SOURCE_DIR}/output/android-resources"
    CACHE PATH "Prepared Android resources")

# Qt 6.12 的 Android 终结器会给「目标的源目录」排一个延迟调用，用来递归收集 imported 共享库
# （Qt6AndroidMacros.cmake:1041 的 cmake_language(DEFER DIRECTORY ...)）。
# 本项目的可执行目标建在 Qt/ 子目录（Qt/CMakeLists.txt:2）、在顶层终结（CMakeLists.txt:647），
# 而 CMake 4 不允许向已经处理完的目录排延迟调用，configure 会直接报
# "cmake_language DEFER CALL may not be scheduled in directory .../Qt at this time"。
# 关掉这条自动收集：libnode.so 已经通过 QT_ANDROID_EXTRA_LIBS 显式列出，Qt 自己的库由
# androiddeployqt 按 kit 处理，都不依赖这次扫描。将来若引入第三方 imported 库，
# 记得同样显式加进 QT_ANDROID_EXTRA_LIBS，别指望这条自动收集。
set(QT_NO_COLLECT_IMPORTED_TARGET_APK_DEPS TRUE)

# Node 运行时：与 iOS 同一个版本（nodejs-mobile 18.20.4），但入口不同——
# iOS 的 NodeMobile.framework 导出 C 包装 node_start，Android 的 libnode.so 只导出
# node::Start(int, char**)。见 Qt/src/BridgeProcessAndroid.cpp。
# Android 没有可执行文件可以 fork，必须把运行时编进进程。
set(rhineNodeLibrary "${RHINE_ANDROID_NODE_ROOT}/bin/arm64-v8a/libnode.so")
if(NOT EXISTS "${rhineNodeLibrary}")
    message(
        FATAL_ERROR
        "libnode.so not found: ${rhineNodeLibrary}\n"
        "Run npm run build:android (it extracts the pinned nodejs-mobile release), or pass"
        " -DRHINE_ANDROID_NODE_ROOT=<extracted release>.")
endif()
add_library(RhineNodeMobile SHARED IMPORTED)
set_target_properties(RhineNodeMobile PROPERTIES IMPORTED_LOCATION "${rhineNodeLibrary}")

# Host.cpp 在移动端走进程内桥接，所以这两个实现必须编进 RhineCore 而不是主程序。
# AndroidAssets 也放在这里：它要读 BuildIdentity.h，而那个生成头只挂在 RhineCore 的
# 私有包含路径上（主程序目标拿不到）。qrc 属于主程序，但同一进程内任何代码都能读。
target_sources(RhineCore PRIVATE "${CMAKE_SOURCE_DIR}/Qt/src/PlatformAndroid.cpp"
    "${CMAKE_SOURCE_DIR}/Qt/src/BridgeProcessAndroid.cpp"
    "${CMAKE_SOURCE_DIR}/Qt/src/BridgeProcess.h"
    "${CMAKE_SOURCE_DIR}/Qt/src/AndroidMediaSession.cpp"
    "${CMAKE_SOURCE_DIR}/Qt/src/AndroidMediaSession.h"
    "${CMAKE_SOURCE_DIR}/Qt/src/AndroidAssets.cpp"
    "${CMAKE_SOURCE_DIR}/Qt/src/AndroidAssets.h")
target_link_libraries(RhineCore PRIVATE RhineNodeMobile)
# AndroidMediaSession 用 QtCore 的私有 Android 扩展（POST_NOTIFICATIONS 权限申请）；
# 私有头在 include/QtCore/6.12.0 下，CorePrivate 目标带来这条包含路径。
target_link_libraries(RhineCore PRIVATE Qt6::CorePrivate)
# 法线响应的位宽：烘焙脚本（RHINE_BAKE_NORMAL_RGBA8=1）、着色器（CMakeLists 的
# RHINE_NORMAL_RGBA8 宏）与运行时纹理格式必须是同一个决定。
#
# 目标必须同时挂到 RhineMusicDatabase，而不能只挂 RhineCore：CMakeLists.txt 的
# RHINE_CORE_SOURCES 用 FILTER EXCLUDE 剔掉了 main/Engine/RhiScene/Hud/FrameProfiler
# 与 /render/（它们链 fsr/fg，不进回归库），RhiScene.cpp 实际只编进应用目标。
# 2026-11-06 21:28 的启动崩溃就是这么来的——宏挂在 RhineCore 上从未生效，
# RhiScene.cpp 走 RGBA16F 分支去校验 8 位烘焙产物，直接 qFatal。
# 两个目标都加：RhineCore 里没有消费这个宏的文件，多一份不会改变任何产物。
if(RHINE_ANDROID_NORMAL_RGBA8)
    target_compile_definitions(RhineMusicDatabase PRIVATE RHINE_NORMAL_RGBA8=1)
    target_compile_definitions(RhineCore PRIVATE RHINE_NORMAL_RGBA8=1)
endif()

# LTO。CMakeLists.txt 给 Release 打开的 INTERPROCEDURAL_OPTIMIZATION 由 CMake 自己决定形态
# （Clang 上是 `-flto=thin`），这里关掉它，改成显式、可切换：RHINE_ANDROID_LTO = full|thin|off。
#
#   full（默认，最彻底）：`-flto` + `--lto-partitions=<N>`。整个链接单元（RhineCore +
#       RhineMusicDatabase + qrc 资源符号）一起做内联与死代码消除；全量 IR 合并阶段是
#       单线程瓶颈，`--lto-partitions` 把 codegen 拆开并行，分区之间不再互相内联——
#       所以实际效果介于 thin 与纯 full 之间，但死代码消除仍是三种形态里最彻底的。
#   thin（回退，并行）：`-flto=thin` + `--thinlto-jobs=<N>`。构建时间接近普通编译，
#       跨 TU 内联受"导入"限制；full 链接耗时不可接受时切到它。
#   off（兜底）：不加任何 LTO 标志，连 thin 的跨模块开销也不要。
#
# 必须先关掉 IPO：否则 `-flto=thin` 与 `-flto` 会同时出现在同一条命令行上，
# 两个标志谁生效取决于编译器实现细节，等于把体积交给运气。
# 只影响 Android；桌面 / iOS 保持 CMake 的默认（thin）。
include(ProcessorCount)
ProcessorCount(RHINE_ANDROID_JOBS)
if(RHINE_ANDROID_JOBS EQUAL 0)
    set(RHINE_ANDROID_JOBS 4)
endif()
set(RHINE_ANDROID_LTO
    "full"
    CACHE STRING "Android Release LTO mode: full (default) | thin (parallel fallback) | off")
set_property(CACHE RHINE_ANDROID_LTO PROPERTY STRINGS full thin off)

# 无论选哪种形态都要关掉 IPO：CMake 的 IPO 在 Clang 上展开成 -flto=thin，
# 会与本段手挂的 -flto 同命令行并存，两个标志谁生效取决于编译器实现细节。
set_target_properties(
    RhineCore
    RhineMusicDatabase
    PROPERTIES INTERPROCEDURAL_OPTIMIZATION_RELEASE FALSE)
if(RHINE_ANDROID_LTO STREQUAL "full")
    set(RHINE_ANDROID_LTO_COMPILE -flto)
    set(RHINE_ANDROID_LTO_LINK -flto -Wl,--lto-partitions=${RHINE_ANDROID_JOBS})
elseif(RHINE_ANDROID_LTO STREQUAL "thin")
    set(RHINE_ANDROID_LTO_COMPILE -flto=thin)
    set(RHINE_ANDROID_LTO_LINK -flto=thin -Wl,--thinlto-jobs=${RHINE_ANDROID_JOBS})
else()
    set(RHINE_ANDROID_LTO_COMPILE "")
    set(RHINE_ANDROID_LTO_LINK "")
endif()
if(RHINE_ANDROID_LTO_COMPILE)
    target_compile_options(RhineCore PRIVATE $<$<CONFIG:Release>:${RHINE_ANDROID_LTO_COMPILE}>)
    target_compile_options(
        RhineMusicDatabase PRIVATE $<$<CONFIG:Release>:${RHINE_ANDROID_LTO_COMPILE}>)
    # 最终链接在主目标上：静态库里的 bitcode 由这里的标志触发全量/增量优化。
    target_link_options(RhineMusicDatabase PRIVATE $<$<CONFIG:Release>:${RHINE_ANDROID_LTO_LINK}>)
    message(STATUS "Android LTO: ${RHINE_ANDROID_LTO} (${RHINE_ANDROID_JOBS} jobs)")
else()
    message(STATUS "Android LTO: off")
endif()

target_sources(RhineMusicDatabase PRIVATE "${CMAKE_SOURCE_DIR}/Qt/src/AndroidWindow.cpp"
    "${CMAKE_SOURCE_DIR}/Qt/src/AndroidWindow.h")

# 随包资源：编译进 .so 的 /rhine-assets，首次启动时解包到应用私有目录，
# 供 Node（需要真实路径）与 QFontDatabase 使用。
if(NOT EXISTS "${RHINE_ANDROID_RESOURCES}/slots.json")
    message(
        FATAL_ERROR
        "Android resources missing: ${RHINE_ANDROID_RESOURCES}/slots.json\n"
        "Run npm run build:android (it prepares resources and the Android bridge bundle).")
endif()
file(
    GLOB_RECURSE
    rhineAndroidResourceFiles
    CONFIGURE_DEPENDS
    "${RHINE_ANDROID_RESOURCES}/*")
list(LENGTH rhineAndroidResourceFiles rhineAndroidResourceCount)
message(
    STATUS
    "Android: embedding ${rhineAndroidResourceCount} resource files from ${RHINE_ANDROID_RESOURCES}")
qt_add_resources(
    RhineMusicDatabase
    "rhine_android_resources"
    PREFIX
    "/rhine-assets"
    BASE
    "${RHINE_ANDROID_RESOURCES}"
    FILES
    ${rhineAndroidResourceFiles})

# 版本号：Android 的 versionCode 是单调整数，用 major.minor.patch 直接拼出来，
# 这样"版本高 → code 大"始终成立（0.4.0 → 400）。
math(EXPR RHINE_ANDROID_VERSION_CODE
    "${PROJECT_VERSION_MAJOR} * 10000 + ${PROJECT_VERSION_MINOR} * 100 + ${PROJECT_VERSION_PATCH}")

set_target_properties(
    RhineMusicDatabase
    PROPERTIES QT_ANDROID_PACKAGE_SOURCE_DIR "${CMAKE_SOURCE_DIR}/Qt/android"
    QT_ANDROID_ABIS arm64-v8a
    QT_ANDROID_PACKAGE_NAME "${RHINE_APPLICATION_ID}"
    QT_ANDROID_APP_NAME "RHINE MUSIC DATABASE"
    QT_ANDROID_VERSION_NAME "${PROJECT_VERSION}"
    QT_ANDROID_VERSION_CODE ${RHINE_ANDROID_VERSION_CODE}
    # minSdk 28：Qt 6.12 的 Android 音频后端只有 AAudio，它要用
    # AAudioStreamBuilder_setUsage 等 API 28 才有的符号，kit 也按 28 编，
    # 声明 26 会在 Android 8 上加载 libQt6Multimedia.so 时找不到符号。
    QT_ANDROID_MIN_SDK_VERSION 28
    # compile/target 对齐本机 SDK（platforms/android-36）。目标 SDK 越高，
    # 系统对后台与存储的限制越严，但本应用不依赖这些豁免。
    QT_ANDROID_TARGET_SDK_VERSION 36
    QT_ANDROID_COMPILE_SDK_VERSION 36)

# libnode.so 必须随包进 APK 的 lib/arm64-v8a/；Qt 只自动收 Qt 自己的库。
set_property(TARGET RhineMusicDatabase APPEND PROPERTY QT_ANDROID_EXTRA_LIBS "${rhineNodeLibrary}")

# 包源目录（清单 + 图标）由脚本之外的路径也可能用到，这里先确认文件在位，
# 免得问题拖到 Gradle 阶段才以"资源找不到"的形式出现。
foreach(requiredFile AndroidManifest.xml res/mipmap-xxxhdpi/ic_launcher.png)
    if(NOT EXISTS "${CMAKE_SOURCE_DIR}/Qt/android/${requiredFile}")
        message(FATAL_ERROR "Android package source is missing ${requiredFile}")
    endif()
endforeach()
