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
# RHINE_NORMAL_RGBA8 宏）与这里的纹理格式必须是同一个决定。RhiScene.cpp 在 RhineCore 里，
# 所以 C++ 侧也要拿到这个宏，否则它会按 RGBA16F 建纹理去读 8 位数据。
if(RHINE_ANDROID_NORMAL_RGBA8)
    target_compile_definitions(RhineCore PRIVATE RHINE_NORMAL_RGBA8=1)
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
