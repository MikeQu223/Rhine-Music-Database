cmake_minimum_required(VERSION 3.24)
if(APPLE AND NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.4")
endif()
# 正式版本在构建前注入；开发版仅保留系统资源所需的数字占位。
set(RHINE_VERSION
    "0.0.0"
    CACHE STRING "Application release version")
option(RHINE_RELEASE_BUILD "Build a versioned public release" OFF)
if(NOT RHINE_VERSION MATCHES "^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")
    message(FATAL_ERROR "RHINE_VERSION must use major.minor.patch")
endif()
project(
    RhineMusicDatabase
    VERSION ${RHINE_VERSION}
    # C is required by the vendored glslang/SPIRV-Tools that compiles the FidelityFX shader permutations at
    # build time.
    LANGUAGES CXX C)
# 停用D3D12入口
set(RHINE_ENABLE_D3D12_BACKEND OFF)
add_compile_definitions(RHINE_ENABLE_D3D12_BACKEND=$<BOOL:${RHINE_ENABLE_D3D12_BACKEND}>)
set(RHINE_APPLICATION_ID "rhine.music.database")
find_package(Git QUIET)
set(RHINE_COMMIT_SHA "unknown")
set(RHINE_COMMIT_TITLE "未知提交")
if(GIT_FOUND)
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" log -1 --format=%h --abbrev=12
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE commitSha
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" -c i18n.logOutputEncoding=UTF-8 log -1 --format=%s
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE commitTitle
        OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET ENCODING UTF-8)
    if(commitSha AND commitTitle)
        set(RHINE_COMMIT_SHA "${commitSha}")
        set(RHINE_COMMIT_TITLE "${commitTitle}")
    endif()
endif()
# 提交标题可能包含引号和反斜杠，写入生成头文件前先转义 C++ 字符串。
string(REPLACE "\\" "\\\\" RHINE_COMMIT_TITLE "${RHINE_COMMIT_TITLE}")
string(REPLACE "\"" "\\\"" RHINE_COMMIT_TITLE "${RHINE_COMMIT_TITLE}")
configure_file(Qt/BuildIdentity.h.in "${CMAKE_CURRENT_BINARY_DIR}/BuildIdentity.h" @ONLY)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(
    Qt6 6.12 REQUIRED
    COMPONENTS Core
               Gui
               Qml
               Quick
               Network
               Concurrent
               ShaderTools
               Multimedia)
if(WIN32 OR (APPLE AND NOT IOS))
    find_package(Qt6 6.12 REQUIRED COMPONENTS Widgets)
endif()
if(NOT TARGET Qt6::GuiPrivate)
    find_package(Qt6GuiPrivate REQUIRED)
endif()
if(NOT TARGET Qt6::MultimediaPrivate)
    find_package(Qt6MultimediaPrivate REQUIRED)
endif()
qt_policy(SET QTP0001 NEW)
qt_policy(SET QTP0004 NEW)
# 标签读取
include(FetchContent)
set(BUILD_TESTING
    OFF
    CACHE BOOL "" FORCE)
set(BUILD_BINDINGS
    OFF
    CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS
    OFF
    CACHE BOOL "" FORCE)
FetchContent_Declare(
    utfcpp
    URL "${CMAKE_CURRENT_SOURCE_DIR}/vendor/utfcpp/utfcpp-4.0.6.tar.gz"
    URL_HASH SHA256=6920a6a5d6a04b9a89b2a89af7132f8acefd46e0c2a7b190350539e9213816c0)
FetchContent_MakeAvailable(utfcpp)
set(utf8cpp_INCLUDE_DIR
    "${utfcpp_SOURCE_DIR}/source"
    CACHE PATH "" FORCE)
FetchContent_Declare(
    taglib
    URL "${CMAKE_CURRENT_SOURCE_DIR}/vendor/taglib/taglib-2.1.1.tar.gz"
    URL_HASH SHA256=bd57924496a272322d6f9252502da4e620b6ab9777992e8934779ebd64babd6e)
FetchContent_MakeAvailable(taglib)
# AMD FidelityFX（FSR3 组件 + Vulkan 后端，DX12 仅在 Windows 下接入）。 SDK 目标由 RhineMusicDatabase 链接，见文件末尾的
# FidelityFX::SDK 段。
include(cmake/FidelityFX.cmake)
# 自维护源码和锁定的二维码库构成独立应用目标。
set(RHINE_APP_SOURCES
    Qt/src/AppUpdater.cpp
    Qt/src/AppUpdater.h
    Qt/src/AudioPlayer.cpp
    Qt/src/AudioPlayer.h
    Qt/src/HttpAudioStream.cpp
    Qt/src/HttpAudioStream.h
    Qt/src/PlaybackDiagnostics.cpp
    Qt/src/PlaybackDiagnostics.h
    Qt/src/AppStorage.cpp
    Qt/src/AppStorage.h
    Qt/src/DiscGeometry.cpp
    Qt/src/DiscGeometry.h
    Qt/src/FrameProfiler.cpp
    Qt/src/FrameProfiler.h
    Qt/src/ProcessMetrics.cpp
    Qt/src/ProcessMetrics.h
    Qt/src/NativeCards.cpp
    Qt/src/NativeCards.h
    Qt/src/NativePicking.cpp
    Qt/src/NativePicking.h
    Qt/src/UiMotion.cpp
    Qt/src/UiMotion.h
    Qt/tests/NativeHostChecks.cpp
    Qt/tests/NativeMusicChecks.cpp
    Qt/tests/SessionChecks.cpp
    Qt/src/Icon.cpp
    Qt/src/main.cpp
    Qt/src/PlaybackConnection.cpp
    Qt/src/PlaybackConnection.h
    Qt/src/Host.cpp
    Qt/src/Host.h
    Qt/src/MusicApi.cpp
    Qt/src/MusicApi.h
    Qt/src/LyricsController.cpp
    Qt/src/LyricsController.h
    Qt/src/MusicSession.cpp
    Qt/src/MusicPlayer.cpp
    Qt/src/MusicPlayer.h
    Qt/src/PlaybackQueue.cpp
    Qt/src/PlaybackQueue.h
    Qt/src/MusicData.cpp
    Qt/src/MusicData.h
    Qt/src/LocalMusicLibrary.cpp
    Qt/src/LocalMusicLibrary.h
    Qt/src/LocalCollections.cpp
    Qt/src/LocalCollections.h
    Qt/src/MusicLocal.cpp
    Qt/src/MusicSiren.cpp
    Qt/src/NativeHudLocal.cpp
    Qt/src/MusicLibrary.cpp
    Qt/src/MusicLibrary.h
    Qt/src/NativeHud.h
    Qt/src/NativeHud.cpp
    Qt/src/NativeHudController.cpp
    Qt/src/NativeHudMusic.cpp
    Qt/src/NativeHudInput.cpp
    Qt/src/NativeHudDetail.cpp
    Qt/src/SongDetailCard.cpp
    Qt/src/CollectionDetailCard.cpp
    Qt/src/NativeHudPlayer.cpp
    Qt/src/PlayerBar.h
    Qt/src/PlayerBar.cpp
    Qt/src/NativeHudLibrary.cpp
    Qt/src/NativeHudSearch.cpp
    Qt/src/NativeHudDiscover.cpp
    Qt/src/SettingsSchema.cpp
    Qt/src/SettingsSchema.h
    Qt/src/SettingsCard.cpp
    Qt/src/SettingsCard.h
    Qt/src/NativeHudSettings.cpp
    Qt/src/HudScroll.h
    Qt/src/DiscoverMusicCard.cpp
    Qt/src/DiscoverArtwork.cpp
    Qt/src/NativeHudModal.cpp
    Qt/src/NativeHudBoot.cpp
    Qt/src/SceneTypes.h
    Qt/src/SceneAppearance.h
    Qt/src/SceneAppearance.cpp
    Qt/src/NativeApplication.h
    Qt/src/NativeApplication.cpp
    Qt/src/NativeScene.h
    Qt/src/NativeScene.cpp
    Qt/src/NativeSceneUpdate.cpp
    Qt/src/NativeSceneCamera.cpp
    Qt/src/NativeSceneFrame.cpp
    Qt/src/NativeSceneInput.cpp
    Qt/src/NativeViewer.h
    Qt/src/NativeViewer.cpp
    Qt/src/SceneMath.h
    Qt/src/SceneMath.cpp
    Qt/src/SceneDrag.h
    Qt/src/SceneDrag.cpp
    Qt/src/SceneMotion.h
    Qt/src/SceneMotion.cpp
    Qt/src/BootTimeline.cpp
    Qt/src/MusicDirectory.cpp
    Qt/src/MusicAccount.cpp
    Qt/src/MusicMutation.cpp
    Qt/src/MusicDiscover.cpp
    Qt/src/MusicDiscover.h
    Qt/src/Platform.cpp
    Qt/src/Engine.cpp
    Qt/src/Engine.h
    Qt/src/DeferredWindowTransition.cpp
    Qt/src/DeferredWindowTransition.h
    Qt/src/Hud.cpp
    Qt/src/Hud.h
    Qt/src/RhiScene.cpp
    Qt/src/RhiScene.h
    Qt/src/render/MotionPass.cpp
    Qt/src/render/MotionPass.h
    Qt/src/render/ScenePostProcess.cpp
    Qt/src/render/ScenePostProcess.h
    Qt/src/fsr/Fsr3Backend.cpp
    Qt/src/fsr/Fsr3Backend.h
    Qt/src/render/SceneLayerHost.cpp
    Qt/src/render/SceneLayerHost.h
    Qt/src/render/PresentationWindow.cpp
    Qt/src/render/PresentationWindow.h
    Qt/src/fg/FgBackend.cpp
    Qt/src/fg/FgBackend.h
    Qt/src/fg/FgConfig.h
    Qt/src/render/PresentationBackend.h
    Qt/src/render/RhiPresentationBackend.cpp
    Qt/src/render/PresentationShell.cpp
    Qt/src/render/PresentationShell.h
    Qt/src/Glyphs.cpp
    Qt/src/Glyphs.h
    vendor/qrcodegen/qrcodegen.cpp)
list(TRANSFORM RHINE_APP_SOURCES PREPEND "${CMAKE_CURRENT_SOURCE_DIR}/")
if(APPLE)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)
endif()
# 原生业务和场景由应用与独立回归共用，测试不需要复制整套源码目标。 FSR 与 FG 后端只被渲染器使用，跟 RhiScene 一起留在应用目标里，避免把 FidelityFX 与 Vulkan
# 链接进每个回归测试。过滤条件必须同时覆盖 /fsr/ 与 /fg/：这两处的实现依赖 Qt6::Quick 与 GuiPrivate，而 RhineCore 只链
# Core/Gui/Network/Concurrent/Multimedia。
set(RHINE_CORE_SOURCES ${RHINE_APP_SOURCES})
list(FILTER RHINE_CORE_SOURCES EXCLUDE REGEX
     "/(main|Engine|Icon|RhiScene|Hud|FrameProfiler)\\.(cpp|h)$|/tests/|/fsr/|/fg/|/render/")
list(REMOVE_ITEM RHINE_APP_SOURCES ${RHINE_CORE_SOURCES})
# 桌面后台只链接播放源码；场景、字形、资料库与 HUD 不进入服务二进制。
set(RHINE_SYSTEM_CORE RhineCore)
if(NOT IOS)
    set(RHINE_PLAYBACK_SOURCES ${RHINE_CORE_SOURCES})
    list(
        FILTER
        RHINE_PLAYBACK_SOURCES
        INCLUDE
        REGEX
        "/(AppUpdater|AppStorage|AudioPlayer|HttpAudioStream|PlaybackDiagnostics|PlaybackConnection|Host|MusicApi|MusicPlayer|PlaybackQueue|LyricsController|Platform)\\.(cpp|h)$|/qrcodegen\\.cpp$"
    )
    list(REMOVE_ITEM RHINE_CORE_SOURCES ${RHINE_PLAYBACK_SOURCES})
    add_library(RhinePlaybackCore STATIC ${RHINE_PLAYBACK_SOURCES})
    target_include_directories(
        RhinePlaybackCore
        PUBLIC Qt/src
        PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" vendor/qrcodegen)
    target_compile_definitions(
        RhinePlaybackCore
        PUBLIC RHINE_APPLICATION_ID="${RHINE_APPLICATION_ID}" RHINE_VERSION="${PROJECT_VERSION}"
               RHINE_RELEASE_BUILD=$<BOOL:${RHINE_RELEASE_BUILD}>)
    target_link_libraries(
        RhinePlaybackCore
        PUBLIC Qt6::Core Qt6::Gui Qt6::Network Qt6::Concurrent Qt6::Multimedia
        PRIVATE Qt6::MultimediaPrivate)
    if(MSVC)
        target_compile_options(RhinePlaybackCore PRIVATE /utf-8)
    endif()
    set(RHINE_SYSTEM_CORE RhinePlaybackCore)
endif()
add_library(RhineCore STATIC ${RHINE_CORE_SOURCES})
target_include_directories(
    RhineCore
    PUBLIC Qt/src
    PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" vendor/qrcodegen "${taglib_SOURCE_DIR}/taglib"
            "${taglib_SOURCE_DIR}/taglib/toolkit" "${taglib_BINARY_DIR}")
target_compile_definitions(
    RhineCore PUBLIC RHINE_APPLICATION_ID="${RHINE_APPLICATION_ID}" RHINE_VERSION="${PROJECT_VERSION}"
                     RHINE_RELEASE_BUILD=$<BOOL:${RHINE_RELEASE_BUILD}>)
target_link_libraries(
    RhineCore
    PUBLIC Qt6::Core Qt6::Gui Qt6::Network Qt6::Concurrent Qt6::Multimedia
    PRIVATE Qt6::MultimediaPrivate tag)
if(NOT IOS)
    target_link_libraries(RhineCore PUBLIC RhinePlaybackCore)
endif()
add_subdirectory(Qt)
target_link_libraries(RhineMusicDatabase PRIVATE RhineCore)
# 体积优化：随包的 97 个库都是 Qt 与发行版的 strip 二进制，编译参数无从下手，能自定义的只有这两个
# 目标。Release 开 LTO，让链接期做跨翻译单元内联与死代码消除。
# 刻意不加 -fvisibility=hidden：可执行文件本来就不导出符号，省不到 50 KB，却可能挡住 dlsym
# 一类的自省路径，收益与风险倒挂。
#
# LTO 要三样东西同时在位：编译器插件（GCC 的 liblto_plugin.so）、带插件的归档器
# （gcc-ar/gcc-ranlib——RhineCore 是静态库，CMake 建库时会强制换成这两个），以及能加载插件的
# 链接器。缺任一项 check_ipo_supported 只返回 NO，产物悄悄大 1.5 MB 而构建照常成功，因此这里
# 默认打警告把降级暴露出来；RHINE_REQUIRE_LTO=1 把它升级为配置期错误，CI 的 Linux 任务用这个开关。
set(RHINE_REQUIRE_LTO OFF)
if(DEFINED ENV{RHINE_REQUIRE_LTO} AND "$ENV{RHINE_REQUIRE_LTO}" MATCHES "^(1|[Oo][Nn]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$")
    set(RHINE_REQUIRE_LTO ON)
endif()
include(CheckIPOSupported)
check_ipo_supported(RESULT RHINE_IPO_SUPPORTED OUTPUT RHINE_IPO_ERROR LANGUAGES CXX)
if(RHINE_IPO_SUPPORTED)
    set_target_properties(
        RhineCore
        RhineMusicDatabase
        PROPERTIES INTERPROCEDURAL_OPTIMIZATION_RELEASE TRUE)
    message(STATUS "IPO/LTO enabled for Release (${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION})")
elseif(RHINE_REQUIRE_LTO)
    message(
        FATAL_ERROR
            "RHINE_REQUIRE_LTO is set but IPO/LTO is unavailable.\n"
            "Install a plugin-capable toolchain (GCC: gcc/g++/binutils provide liblto_plugin.so and"
            " gcc-ar), or unset RHINE_REQUIRE_LTO to accept a larger Release binary.\n${RHINE_IPO_ERROR}")
else()
    message(
        WARNING
            "IPO/LTO unavailable, Release builds are not optimized across translation units"
            " (expect ~1.5 MB larger binaries).\n${RHINE_IPO_ERROR}")
endif()
# Linux 再按函数/数据切段，配合 --gc-sections 回收主程序里真正到不了的部分。
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_compile_options(RhineCore PRIVATE -ffunction-sections -fdata-sections)
    target_compile_options(RhineMusicDatabase PRIVATE -ffunction-sections -fdata-sections)
    target_link_options(RhineMusicDatabase PRIVATE -Wl,--gc-sections)
endif()
# FSR 只挂在应用目标上：设置页要按编译期能力置灰，所以把可用性也传成宏。 FSR1 是纯着色器（EASU+RCAS），任何后端都能用；FSR3 需要 Vulkan 或 D3D12。
if(TARGET FidelityFX::SDK)
    target_link_libraries(RhineMusicDatabase PRIVATE FidelityFX::SDK)
endif()
if(RHINE_FFX_VK_AVAILABLE AND RHINE_FFX_SHADER_BLOBS_AVAILABLE)
    target_compile_definitions(RhineMusicDatabase PRIVATE RHINE_FSR3_VULKAN=1)
    # 设置页编在 RhineCore 里，只凭"后端名"猜不出构建是否真编进了 FSR3：同一个后端 在不同构建配置下可能可用也可能不可用。把能力宏一并传给 RhineCore，让置灰逻辑
    # 按实际编译结果判断。这里只传宏，不链接 FidelityFX。
    target_compile_definitions(RhineCore PRIVATE RHINE_FSR3_VULKAN=1)
    # 保持 Vulkan 呈现原有的构建门控，只把设备/交换链操作移入适配器。
    target_compile_definitions(RhineMusicDatabase PRIVATE RHINE_VULKAN_PRESENTATION=1)
    target_sources(RhineMusicDatabase PRIVATE Qt/src/fg/VulkanPresenter.cpp Qt/src/fg/VulkanPresenter.h
                                              Qt/src/render/VulkanPresentationBackend.cpp)
endif()
if(RHINE_FFX_DX12_AVAILABLE)
    target_compile_definitions(RhineMusicDatabase PRIVATE RHINE_FSR3_DX12=1)
    target_compile_definitions(RhineCore PRIVATE RHINE_FSR3_DX12=1)
endif()
set_source_files_properties(Qt/qml/Main.qml TARGET_DIRECTORY RhineMusicDatabase PROPERTIES QT_RESOURCE_ALIAS
                                                                                           Main.qml)
target_include_directories(RhineMusicDatabase PRIVATE vendor/qrcodegen Qt/src)
qt_add_resources(
    RhineMusicDatabase
    "rhine_animation"
    PREFIX
    "/animation"
    BASE
    "Assets/animation"
    FILES
    Assets/animation/boot-tracks.json)
qt_add_resources(
    RhineMusicDatabase
    "rhine_icons"
    PREFIX
    "/icons"
    BASE
    "Assets/icons"
    FILES
    Assets/icons/icon-16.png
    Assets/icons/icon-32.png
    Assets/icons/icon-64.png
    Assets/icons/icon-128.png
    Assets/icons/icon-256.png
    Assets/icons/icon-512.png
    Assets/icons/icon-1024.png)
# 着色器按原通道顺序打包，所有后端使用同一份公式。 GLSL 130 兼容 Windows 随包的软件 OpenGL，其他后端仍保留原有版本。
qt_add_shaders(
    RhineMusicDatabase
    "rhine_shaders"
    PREFIX
    "/shaders"
    BASE
    "Qt/shaders"
    GLSL
    "130,150,300es"
    HLSL
    50
    MSL
    12
    FILES
    Qt/shaders/quad.vert
    Qt/shaders/copyColor.frag
    Qt/shaders/aaFragment.frag
    Qt/shaders/taa.frag
    Qt/shaders/motion.vert
    Qt/shaders/velocity.frag
    Qt/shaders/fsr1_easu.frag
    Qt/shaders/fsr1_rcas.frag
    Qt/shaders/fgComposite.vert
    Qt/shaders/fgComposite.frag)
# 唯一场景的烘焙材质与最终合成着色器
set(RHINE_OPTICAL_SHADER_DEFINES)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(APPEND RHINE_OPTICAL_SHADER_DEFINES RHINE_SINGLE_PASS_MOTION=1)
endif()
# E05a：紧凑实例（80 字节）的第二套着色器烘焙放在独立子目录：
# qt_add_shaders 把 .qsb 写到当前二进制目录的 .qsb/ 下，同一目录对同一份源码烘两次会撞规则。
add_subdirectory(Qt/shaders/compact)
qt_add_shaders(
    RhineMusicDatabase
    "rhine_enhancement_shaders"
    PREFIX
    "/optical"
    BASE
    "Qt/shaders/enhancement"
    DEFINES
    ${RHINE_OPTICAL_SHADER_DEFINES}
    GLSL
    "130,150,300es"
    HLSL
    50
    MSL
    12
    FILES
    Qt/shaders/enhancement/opticalGeometry.vert
    Qt/shaders/enhancement/opticalQuad.vert
    Qt/shaders/enhancement/opticalSurface.frag
    Qt/shaders/enhancement/opticalFinalFragment.frag
    Qt/shaders/enhancement/opticalWarp.frag
    Qt/shaders/enhancement/opticalWarpEarly.frag
    Qt/shaders/enhancement/opticalWarpLate.frag
    Qt/shaders/enhancement/opticalWarpDebug.frag
    Qt/shaders/enhancement/opticalSurfaceNoMrt.frag)
target_compile_definitions(RhineMusicDatabase PRIVATE RHINE_APPLICATION_ID="${RHINE_APPLICATION_ID}"
                                                      $<$<CONFIG:Debug>:QT_QML_DEBUG>)
target_link_libraries(
    RhineMusicDatabase
    PRIVATE Qt6::Core
            Qt6::Gui
            Qt6::GuiPrivate
            Qt6::Qml
            Qt6::Quick
            Qt6::Network
            Qt6::Concurrent
            Qt6::Multimedia)
# 平台分支只处理原生能力、部署身份及链接依赖。
if(NOT IOS)
    target_sources(RhineMusicDatabase PRIVATE Qt/tests/PlaybackServiceChecks.cpp
                                              Qt/tests/WindowTransitionChecks.cpp)
    if(WIN32 OR (APPLE AND NOT IOS))
        find_package(Qt6 6.12 REQUIRED COMPONENTS Widgets)
        target_sources(RhineMusicDatabase PRIVATE Qt/src/DesktopTray.cpp Qt/src/DesktopTray.h)
        target_link_libraries(RhineMusicDatabase PRIVATE Qt6::Widgets)
    endif()
    # 后台可执行文件不链接 Qt Quick、QML 或任何渲染资源。
    qt_add_executable(
        RhinePlaybackService
        WIN32
        Qt/src/playback_main.cpp
        Qt/src/PlaybackService.cpp
        Qt/src/PlaybackService.h
        Qt/src/InterfaceSession.cpp
        Qt/src/InterfaceSession.h)
    target_link_libraries(RhinePlaybackService PRIVATE RhinePlaybackCore)
    target_include_directories(RhinePlaybackService PRIVATE Qt/src)
    if(APPLE)
        target_sources(RhineMusicDatabase PRIVATE Qt/src/InterfaceWindowMac.mm)
        target_compile_options(RhinePlaybackService PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
        target_link_libraries(RhinePlaybackService PRIVATE "-framework AppKit")
    endif()
    qt_add_resources(
        RhinePlaybackService
        "service_icons"
        PREFIX
        "/icons"
        BASE
        "Assets/icons"
        FILES
        Assets/icons/icon-256.png)
    if(MSVC)
        target_compile_options(RhinePlaybackService PRIVATE /utf-8)
    endif()
    if(APPLE)
        # helper 跟随主包一起签名和部署；主目标的打包钩子执行前必须已完成构建。
        set_target_properties(
            RhinePlaybackService
            PROPERTIES MACOSX_BUNDLE TRUE
                       MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Qt/PlaybackServiceInfo.plist.in"
                       RUNTIME_OUTPUT_DIRECTORY "$<TARGET_FILE_DIR:RhineMusicDatabase>/../Helpers")
    elseif(UNIX)
        set_target_properties(RhinePlaybackService PROPERTIES INSTALL_RPATH "\$ORIGIN/../lib")
        install(TARGETS RhinePlaybackService RUNTIME DESTINATION bin)
    endif()
    add_dependencies(RhineMusicDatabase RhinePlaybackService)
endif()
if(APPLE)
    target_sources(RhineMusicDatabase PRIVATE Qt/src/render/MetalFxBackend.mm Qt/src/render/MetalFxBackend.h
                                              Qt/src/render/FrameGenerator.h Qt/src/render/SceneResources.h)
    target_link_libraries(RhineMusicDatabase PRIVATE "-framework Metal")
    # iOS 模拟器 SDK 不带 MetalFX，仍构建共用呈现层并报告原生效果不可用。
    find_library(RHINE_METALFX_FRAMEWORK MetalFX)
    if(RHINE_METALFX_FRAMEWORK)
        target_link_libraries(RhineMusicDatabase PRIVATE "-weak_framework MetalFX")
    endif()
    target_compile_options(RhineMusicDatabase PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
endif()
if(IOS)
    target_sources(RhineCore PRIVATE Qt/src/PlatformIOS.mm Qt/src/BridgeProcessIOS.cpp Qt/src/BridgeProcess.h)
    target_link_libraries(RhineCore PRIVATE "-framework Security" "-framework UIKit" "-framework AVFAudio"
                                            "-framework MediaPlayer")
    target_compile_options(RhineCore PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    include(Qt/IOS.cmake)
elseif(APPLE)
    target_sources(${RHINE_SYSTEM_CORE} PRIVATE Qt/src/Platform.mm)
    target_link_libraries(${RHINE_SYSTEM_CORE} PRIVATE "-framework Security" "-framework AppKit"
                                                       "-framework MediaPlayer")
    target_compile_options(${RHINE_SYSTEM_CORE} PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    set_target_properties(
        RhineMusicDatabase
        PROPERTIES MACOSX_BUNDLE_GUI_IDENTIFIER ${RHINE_APPLICATION_ID}
                   MACOSX_BUNDLE_BUNDLE_NAME "RHINE MUSIC DATABASE"
                   MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Qt/Info.plist.in")
elseif(WIN32)
    target_sources(RhineMusicDatabase PRIVATE Qt/src/WindowsGraphics.cpp Qt/src/WindowsTaskbar.cpp
                                              Qt/tests/WindowsTaskbarChecks.cpp)
    target_link_libraries(RhineMusicDatabase PRIVATE dxgi ole32 uuid gdi32 dwmapi)
    if(RHINE_ENABLE_D3D12_BACKEND)
        target_link_libraries(RhineMusicDatabase PRIVATE d3d12)
    endif()
    # ffx_backend_vk 链接了 Vulkan 导入库，而该依赖 PUBLIC 传播到本目标，于是 vulkan-1.dll 成了加载期依赖。这与 README 承诺的「Vulkan
    # 不可用时回退平台默认」 直接矛盾：缺少 Vulkan 运行库的机器（CI runner、虚拟机、远程桌面）会在进程启动 阶段就拿到 0xc0000135，main.cpp 里的
    # vulkanDeviceAvailable() 探测和回退逻辑 根本没机会执行。改成延迟加载：不调用 Vulkan 就不加载，探测失败就正常回退。
    if(MSVC AND RHINE_FFX_VK_AVAILABLE)
        target_link_options(RhineMusicDatabase PRIVATE "/DELAYLOAD:vulkan-1.dll")
        target_link_libraries(RhineMusicDatabase PRIVATE delayimp)
    endif()
    configure_file(Qt/WindowsIcon.rc.in "${CMAKE_CURRENT_BINARY_DIR}/WindowsIcon.rc" @ONLY)
    target_sources(RhineMusicDatabase PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/WindowsIcon.rc")
    target_link_libraries(RhineCore PRIVATE psapi)
    target_sources(${RHINE_SYSTEM_CORE} PRIVATE Qt/src/PlatformWindows.cpp)
    target_link_libraries(${RHINE_SYSTEM_CORE} PRIVATE crypt32 shell32 user32 windowsapp runtimeobject
                                                       Qt6::MultimediaPrivate)
    target_compile_options(RhineMusicDatabase PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
    target_compile_options(RhineCore PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
elseif(UNIX)
    # Linux 复用同一份原生场景实现；凭据、协议交付和媒体集成由本平台文件补齐。
    target_sources(${RHINE_SYSTEM_CORE} PRIVATE Qt/src/PlatformLinux.cpp)
    # 显卡选择：Windows 那条直路是 DXGI + QT_D3D_ADAPTER_INDEX，Linux 只能把序号翻译成 驱动认识的环境变量，且必须在 QGuiApplication
    # 之前完成，所以单独成文件、只挂主程序。
    target_sources(RhineMusicDatabase PRIVATE Qt/src/LinuxGraphics.cpp)
    # 安装后的程序按 AppImage 前缀查找同级 Qt 运行时；构建树仍用 CMake 生成的 kit 路径， 否则 CI 中装在独立目录的 Qt 会在运行测试时找不到。
    set_target_properties(RhineMusicDatabase PROPERTIES INSTALL_RPATH "\$ORIGIN/../lib")
    install(TARGETS RhineMusicDatabase RUNTIME DESTINATION bin)
else()
    message(FATAL_ERROR "Supported desktop platforms are macOS, Linux and Windows")
endif()
# Qt Creator 的普通构建也交付完整应用，不能依赖运行目录里的 output/resources。
option(RHINE_PACKAGE_APP "Package resources and Qt libraries after a macOS CMake build" ON)
if(APPLE
   AND NOT IOS
   AND RHINE_PACKAGE_APP)
    find_program(RHINE_NPM_EXECUTABLE NAMES npm REQUIRED)
    get_filename_component(RHINE_QT_KIT "${Qt6_DIR}/../../.." ABSOLUTE)
    # 脚本、字体和场景数据改变时重新链接，确保 POST_BUILD 重新生成部署资源。
    file(
        GLOB_RECURSE
        RHINE_RESOURCE_INPUTS
        CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/Resources/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/client/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/Assets/*"
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/*")
    list(
        APPEND RHINE_RESOURCE_INPUTS "${CMAKE_CURRENT_SOURCE_DIR}/package.json"
        "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/worker.cjs" "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/qq.cjs"
        "${CMAKE_CURRENT_SOURCE_DIR}/MusicBridge/package-lock.json")
    set_property(
        TARGET RhineMusicDatabase
        APPEND
        PROPERTY LINK_DEPENDS ${RHINE_RESOURCE_INPUTS})
    add_custom_command(
        TARGET RhineMusicDatabase
        POST_BUILD
        COMMAND "${RHINE_NPM_EXECUTABLE}" run package:cmake -- "$<TARGET_BUNDLE_DIR:RhineMusicDatabase>"
                "${RHINE_QT_KIT}" "$<CONFIG>"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "Packaging standalone music panel resources and Qt runtime"
        VERBATIM)
endif()
qt_finalize_executable(RhineMusicDatabase)
# 桌面回归包含子进程和桌面路径，iOS 只构建正式应用。
if(IOS)
    return()
endif()
enable_testing()
qt_add_executable(RhinePlatformRegression Qt/tests/PlatformRegression.cpp Qt/src/AppStorage.cpp
                  Qt/src/AudioPlayer.cpp Qt/src/HttpAudioStream.cpp Qt/src/ProcessMetrics.cpp)
target_include_directories(RhinePlatformRegression PRIVATE Qt/src)
target_link_libraries(RhinePlatformRegression PRIVATE Qt6::Core Qt6::Gui Qt6::Multimedia Qt6::Network
                                                      Qt6::MultimediaPrivate)
if(WIN32)
    target_sources(RhinePlatformRegression PRIVATE Qt/src/PlatformWindows.cpp)
    target_link_libraries(
        RhinePlatformRegression
        PRIVATE Qt6::Qml
                Qt6::Network
                crypt32
                shell32
                user32
                windowsapp
                runtimeobject)
    target_compile_definitions(RhinePlatformRegression PRIVATE RHINE_APPLICATION_ID="${RHINE_APPLICATION_ID}")
    target_compile_options(RhinePlatformRegression PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
elseif(UNIX)
    # 凭据文件的位置和权限随平台不同，回归测试直接使用真实实现而不是桩。
    target_sources(RhinePlatformRegression PRIVATE Qt/src/PlatformLinux.cpp)
endif()
add_test(NAME qt_platform_regression COMMAND RhinePlatformRegression
                                             "${CMAKE_CURRENT_BINARY_DIR}/platform-regression")
set_tests_properties(qt_platform_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
qt_add_executable(RhineInputMethodRegression Qt/tests/InputMethodChecks.cpp
                  Qt/src/render/PresentationWindow.cpp Qt/src/render/PresentationWindow.h)
# 测试在内存中创建 QML；动态 Qt kit 直接加载插件，无需递归扫描仓库和部署产物。
set_target_properties(RhineInputMethodRegression PROPERTIES QT_QML_MODULE_NO_IMPORT_SCAN TRUE)
target_include_directories(RhineInputMethodRegression PRIVATE Qt/src)
target_link_libraries(RhineInputMethodRegression PRIVATE Qt6::Quick)
if(MSVC)
    target_compile_options(RhineInputMethodRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_input_method_regression COMMAND RhineInputMethodRegression)
set_tests_properties(qt_input_method_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
qt_add_executable(RhineAudioPlaybackRegression Qt/tests/AudioPlaybackChecks.cpp)
target_link_libraries(RhineAudioPlaybackRegression PRIVATE Qt6::Core Qt6::Multimedia)
if(MSVC)
    target_compile_options(RhineAudioPlaybackRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_audio_playback_regression COMMAND RhineAudioPlaybackRegression)
# 帧生成的纯逻辑（环境变量解析、能力快照、设置页三态、帧输入投递）不碰 GPU， 所以全平台都编、都跑：门控写错的后果是"该置灰的放开了"，只有用例拦得住。
qt_add_executable(RhineFgCapabilityRegression Qt/tests/FgCapabilityChecks.cpp)
target_include_directories(RhineFgCapabilityRegression PRIVATE Qt/src)
target_link_libraries(RhineFgCapabilityRegression PRIVATE Qt6::Core)
if(MSVC)
    target_compile_options(RhineFgCapabilityRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_fg_capability_regression COMMAND RhineFgCapabilityRegression)

# 渲染策略里能离线判定的那一半（GPU 计时四态、时间戳登记、AA 模式是否需要运动矢量）是 header-only 纯逻辑，
# 不碰 QRhi/窗口，所以三平台都编、都跑：真值表写错不会崩，只会让面板把"没请求"说成"没样本"，只有用例拦得住。
qt_add_executable(RhineRenderPolicyRegression Qt/tests/RenderChecks.cpp)
target_include_directories(RhineRenderPolicyRegression PRIVATE Qt/src)
target_link_libraries(RhineRenderPolicyRegression PRIVATE Qt6::Core)
if(MSVC)
    target_compile_options(RhineRenderPolicyRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_render_policy_regression COMMAND RhineRenderPolicyRegression)

# 快速滚动的冷纹理准入（B01）与封面需求账本（B03）是 header-only 纯逻辑，不碰 QRhi/窗口：
# 边界差 1ms、逻辑取消提前归还名额都不会崩，只会让界面变慢或并发慢慢失控，只能靠用例拦。
# 计时器用例需要事件循环，所以在 main 里建 QCoreApplication（不建 GUI）。
qt_add_executable(RhineMusicTextureAdmissionRegression Qt/tests/MusicTextureAdmissionChecks.cpp)
target_include_directories(RhineMusicTextureAdmissionRegression PRIVATE Qt/src)
target_link_libraries(RhineMusicTextureAdmissionRegression PRIVATE Qt6::Core)
if(MSVC)
    target_compile_options(RhineMusicTextureAdmissionRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_music_texture_admission_regression COMMAND RhineMusicTextureAdmissionRegression)

# C04：用"发布／消费"序号合并过量完整 step 是 header-only 纯策略，不读时钟、不接事件循环。
# 写错的后果不是崩溃：要么白白多算一份会被覆盖的中间状态，要么动画停在半路，只能靠用例拦。
qt_add_executable(RhineFramePacingRegression Qt/tests/FramePacingChecks.cpp)
target_include_directories(RhineFramePacingRegression PRIVATE Qt/src)
target_link_libraries(RhineFramePacingRegression PRIVATE Qt6::Core)
if(MSVC)
    target_compile_options(RhineFramePacingRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_frame_pacing_regression COMMAND RhineFramePacingRegression)

# D06：Vulkan 资源策略的纯用例（arena 步长/动态偏移/实例池/深度消费者/缓存代号）。
# 只依赖 Qt6::Core，不建 QGuiApplication，也不碰 VkDevice——离线就能跑。
qt_add_executable(RhineVulkanResourceRegression Qt/tests/VulkanResourceChecks.cpp)
target_include_directories(RhineVulkanResourceRegression PRIVATE Qt/src)
target_link_libraries(RhineVulkanResourceRegression PRIVATE Qt6::Core)
if(MSVC)
    target_compile_options(RhineVulkanResourceRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_vulkan_resource_regression COMMAND RhineVulkanResourceRegression)

qt_add_executable(RhineSceneLifetimeRegression Qt/tests/SceneLifetimeChecks.cpp)
target_include_directories(RhineSceneLifetimeRegression PRIVATE Qt/src)
target_link_libraries(RhineSceneLifetimeRegression PRIVATE Qt6::Core)
add_test(NAME qt_scene_lifetime_regression COMMAND RhineSceneLifetimeRegression)

# Linux 显卡选择里能离线验证的部分：PCI 地址解析、序号 → 环境变量的映射、序号失效时的回退。 写错的后果是"选错卡"或"配置失效后仍注入变量"，只能靠用例拦。三平台都编， sysfs
# 相关用例在源码里按平台裁剪。
qt_add_executable(RhineGpuChoiceRegression Qt/tests/LinuxGpuChecks.cpp Qt/src/LinuxGraphics.cpp
                  Qt/src/AppStorage.cpp)
target_include_directories(RhineGpuChoiceRegression PRIVATE Qt/src)
target_link_libraries(RhineGpuChoiceRegression PRIVATE Qt6::Core)
if(MSVC)
    target_compile_options(RhineGpuChoiceRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_gpu_choice_regression COMMAND RhineGpuChoiceRegression)

qt_add_executable(RhineAudioStreamRegression Qt/tests/AudioStreamChecks.cpp Qt/src/AudioPlayer.cpp
                  Qt/src/HttpAudioStream.cpp)
target_include_directories(RhineAudioStreamRegression PRIVATE Qt/src)
target_link_libraries(RhineAudioStreamRegression PRIVATE Qt6::Core Qt6::Multimedia Qt6::Network)
if(MSVC)
    target_compile_options(RhineAudioStreamRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_audio_stream_regression COMMAND RhineAudioStreamRegression)
add_test(NAME qt_offline COMMAND RhineMusicDatabase --self-test)
set_tests_properties(
    qt_offline
    PROPERTIES ENVIRONMENT
               "QT_QPA_PLATFORM=offscreen;RHINE_RESOURCES=${CMAKE_CURRENT_SOURCE_DIR}/output/resources")

qt_add_executable(RhineGlyphsRegression Qt/tests/GlyphsChecks.cpp)
target_link_libraries(RhineGlyphsRegression PRIVATE RhineCore)
if(MSVC)
    target_compile_options(RhineGlyphsRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_glyphs_regression COMMAND RhineGlyphsRegression
                                           "${CMAKE_CURRENT_SOURCE_DIR}/output/resources")
if(WIN32)
    # offscreen 插件不使用 Windows 字体库，缺字回退需要原生平台插件；测试本身不创建窗口。
    set_tests_properties(qt_glyphs_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=windows")
else()
    set_tests_properties(qt_glyphs_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()

qt_add_executable(RhineNativeHudRegression Qt/tests/NativeHudChecks.cpp)
target_compile_definitions(RhineNativeHudRegression PRIVATE RHINE_HUD_REGRESSION_TEST_MAIN)
target_link_libraries(RhineNativeHudRegression PRIVATE RhineCore)
if(MSVC)
    target_compile_options(RhineNativeHudRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_native_hud_regression COMMAND RhineNativeHudRegression
                                               "${CMAKE_CURRENT_SOURCE_DIR}/output/resources")
set_tests_properties(qt_native_hud_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

qt_add_executable(RhineUpdaterRegression Qt/tests/AppUpdaterChecks.cpp)
target_link_libraries(RhineUpdaterRegression PRIVATE RhineCore)
if(MSVC)
    target_compile_options(RhineUpdaterRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_updater_regression COMMAND RhineUpdaterRegression)
set_tests_properties(qt_updater_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

qt_add_executable(RhineLocalMusicRegression Qt/tests/LocalMusicChecks.cpp)
target_link_libraries(RhineLocalMusicRegression PRIVATE RhineCore)
if(MSVC)
    target_compile_options(RhineLocalMusicRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_local_music_regression COMMAND RhineLocalMusicRegression
                                                "${CMAKE_CURRENT_SOURCE_DIR}/output/resources")
set_tests_properties(qt_local_music_regression PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

qt_add_executable(RhinePlaybackQueueRegression Qt/tests/PlaybackQueueChecks.cpp)
target_link_libraries(RhinePlaybackQueueRegression PRIVATE RhineCore)
if(MSVC)
    target_compile_options(RhinePlaybackQueueRegression PRIVATE /utf-8)
endif()
add_test(NAME qt_playback_queue_regression COMMAND RhinePlaybackQueueRegression)

# FG 闸门探针：验证「setQueueSubmitParams 对离屏帧生效」与「共享 device 上能建交换链」。 需要真实 GPU + 显示服务（或 xvfb + lavapipe），CI runner 没有
# GPU，所以**不进默认 CTest 集合**：构建后用 `output/qt-build/RhineFgGateProbe` 手动运行，用它给出 "FG 架构成不成立"的硬结论。
if(RHINE_FFX_VK_AVAILABLE AND TARGET Qt6::GuiPrivate)
    # EXCLUDE_FROM_ALL：这是排障用的一次性探针，不该占用默认构建与 CI 的时间。 需要时显式 cmake --build output/qt-build --target
    # RhineFgGateProbe。
    qt_add_executable(RhineFgGateProbe Qt/tests/FgGateProbe.cpp)
    set_target_properties(RhineFgGateProbe PROPERTIES EXCLUDE_FROM_ALL TRUE)
    target_include_directories(RhineFgGateProbe PRIVATE Qt/src)
    target_sources(RhineFgGateProbe PRIVATE Qt/src/fg/VulkanPresenter.cpp Qt/src/fg/VulkanPresenter.h)
    target_compile_definitions(RhineFgGateProbe PRIVATE RHINE_FFX_VK_AVAILABLE=1)
    target_link_libraries(RhineFgGateProbe PRIVATE Qt6::Quick Qt6::GuiPrivate)
    if(MSVC)
        target_compile_options(RhineFgGateProbe PRIVATE /utf-8)
    else()
        # 保留符号：探针崩在 Qt 内部时，只有带 -g 才能看出是哪一步。
        target_compile_options(RhineFgGateProbe PRIVATE -g)
        target_link_options(RhineFgGateProbe PRIVATE -g)
    endif()
endif()
