include("${CMAKE_CURRENT_LIST_DIR}/SentryConfig.cmake")
if(NOT RHINE_ENABLE_SENTRY)
    return()
endif()

include(FetchContent)
# 使用官方 SentryObjC-Dynamic 预编译包，保留独立动态框架。
# SHA256 取自同版本的官方 Package.swift。Rhine 不编译任何 Swift 源文件。
FetchContent_Declare(
    sentry_cocoa
    URL https://github.com/getsentry/sentry-cocoa/releases/download/9.35.0/SentryObjC-Dynamic.xcframework.zip
    URL_HASH SHA256=199980b6a7aed5fcba387c3fc47872710d24829af04fb5c90a291084f197e7ba
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(sentry_cocoa)

set(sentry_xcframework "${sentry_cocoa_SOURCE_DIR}")
# CMake 下载解包会移除压缩包唯一的外层目录；本地源码缓存也可保留完整的发行包布局。
if(IS_DIRECTORY "${sentry_xcframework}/SentryObjC-Dynamic.xcframework")
    string(APPEND sentry_xcframework "/SentryObjC-Dynamic.xcframework")
endif()
if(CMAKE_OSX_SYSROOT MATCHES "simulator")
    set(sentry_slice "ios-arm64_x86_64-simulator")
else()
    set(sentry_slice "ios-arm64")
endif()
set(sentry_framework "${sentry_xcframework}/${sentry_slice}/SentryObjC.framework")
if(NOT EXISTS "${sentry_framework}/SentryObjC")
    message(FATAL_ERROR "Incomplete SentryObjC XCFramework slice: ${sentry_framework}")
endif()

# 该发行包未嵌入其源码所带隐私清单，应用资源保留官方声明并加入 HUD 语义记录用途。
set(sentry_resources
    "${CMAKE_CURRENT_SOURCE_DIR}/Qt/PrivacyInfo.xcprivacy"
    "${CMAKE_CURRENT_SOURCE_DIR}/vendor/sentry-cocoa/SentryCocoa-LICENSE.md")
set_source_files_properties(${sentry_resources} TARGET_DIRECTORY RhineMusicDatabase
                            PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
target_sources(RhineMusicDatabase PRIVATE ${sentry_resources})
file(GENERATE
     OUTPUT "${RHINE_SENTRY_CONFIG_DIR}/ios-framework-debug-file.txt"
     CONTENT "${sentry_xcframework}/${sentry_slice}/dSYMs/SentryObjC.framework.dSYM/Contents/Resources/DWARF/SentryObjC
")

target_sources(RhineCore PRIVATE Qt/src/SentryTelemetry.cpp Qt/src/SentryTelemetryApple.mm)
target_compile_definitions(RhineCore PUBLIC RHINE_SENTRY=1)
target_include_directories(RhineCore PRIVATE "${RHINE_SENTRY_CONFIG_DIR}")
target_link_libraries(RhineCore PRIVATE "${sentry_framework}" "-framework Foundation")
set_property(TARGET RhineMusicDatabase APPEND PROPERTY XCODE_EMBED_FRAMEWORKS "${sentry_framework}")

if(RHINE_RELEASE_BUILD)
    foreach(target RhineCore RhineMusicDatabase)
        target_compile_options(${target} PRIVATE $<$<CONFIG:Release>:-g>)
    endforeach()
    set_target_properties(RhineMusicDatabase PROPERTIES
                         XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT "dwarf-with-dsym")
    target_link_options(RhineMusicDatabase PRIVATE
                        "LINKER:-object_path_lto,${CMAKE_CURRENT_BINARY_DIR}/rhine-ios-symbols-lto.o")
endif()
