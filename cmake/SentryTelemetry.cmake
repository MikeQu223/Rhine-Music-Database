include("${CMAKE_CURRENT_LIST_DIR}/SentryConfig.cmake")
if(NOT RHINE_ENABLE_SENTRY)
    return()
endif()

include(FetchContent)
# 固定官方稳定版 0.17.6。Native 后端只发送调用栈时无需引入第二套 Crashpad。
set(SENTRY_BACKEND native)
set(SENTRY_INTEGRATION_QT ON)
set(SENTRY_SCREENSHOT none)
set(SENTRY_BUILD_SHARED_LIBS OFF)
set(SENTRY_BUILD_TESTS OFF)
set(SENTRY_BUILD_EXAMPLES OFF)
set(SENTRY_ENABLE_INSTALL OFF)
FetchContent_Declare(
    sentry_native
    URL https://codeload.github.com/getsentry/sentry-native/tar.gz/7afc37457d7fcc37fb0bace9c8045d3fa687717f
    URL_HASH SHA256=6b0e5ec8977748a27e24f1fcff8e754b809157fc17f47645ad723198d71693e8)
FetchContent_MakeAvailable(sentry_native)

target_sources(RhinePlaybackCore PRIVATE Qt/src/SentryTelemetry.cpp Qt/src/SentryTelemetryNative.cpp)
target_compile_definitions(RhinePlaybackCore PUBLIC RHINE_SENTRY=1)
target_include_directories(RhinePlaybackCore PRIVATE "${RHINE_SENTRY_CONFIG_DIR}")
target_link_libraries(RhinePlaybackCore PRIVATE sentry::sentry)

# 播放服务独立崩溃，需要与 GUI 分别保留匹配的调试信息。
if(MSVC)
    target_compile_options(RhinePlaybackService PRIVATE /Zi)
    target_link_options(RhinePlaybackService PRIVATE /DEBUG:FULL /OPT:REF /OPT:ICF)
elseif(APPLE)
    target_compile_options(RhinePlaybackService PRIVATE -g -fno-omit-frame-pointer)
    target_link_options(RhinePlaybackService PRIVATE
                        "LINKER:-object_path_lto,${CMAKE_BINARY_DIR}/rhine-playback-symbols-lto.o")
endif()

set(sentry_helpers "$<TARGET_FILE:sentry-crash>")
set(sentry_helper_targets sentry-crash)
set(sentry_license_dir "$<TARGET_FILE_DIR:RhineMusicDatabase>")
if(WIN32)
    list(APPEND sentry_helpers "$<TARGET_FILE:sentry-wer>")
    list(APPEND sentry_helper_targets sentry-wer)
elseif(APPLE)
    set(sentry_license_dir "$<TARGET_BUNDLE_CONTENT_DIR:RhineMusicDatabase>/Resources")
endif()
add_custom_target(
    RhineSentryRuntime
    COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_FILE_DIR:RhineMusicDatabase>" "${sentry_license_dir}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${sentry_helpers} "$<TARGET_FILE_DIR:RhineMusicDatabase>"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${sentry_native_SOURCE_DIR}/LICENSE"
            "${sentry_license_dir}/Sentry-LICENSE"
    DEPENDS ${sentry_helper_targets}
    VERBATIM)
add_dependencies(RhineMusicDatabase RhineSentryRuntime)
add_dependencies(RhinePlaybackService RhineSentryRuntime)
