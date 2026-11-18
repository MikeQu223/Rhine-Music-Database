# iOS 构建
target_sources(RhineCore PRIVATE "${CMAKE_SOURCE_DIR}/Qt/src/IOSServerTrust.mm")
target_sources(RhineMusicDatabase PRIVATE "${CMAKE_SOURCE_DIR}/Qt/src/IOSWindow.mm"
                                          "${CMAKE_SOURCE_DIR}/Qt/tests/IOSBridgeChecks.cpp")
set(RHINE_NODE_MOBILE_ROOT
    ""
    CACHE PATH "Extracted nodejs-mobile iOS release")
set(RHINE_IOS_RESOURCES
    "${CMAKE_SOURCE_DIR}/output/ios-resources"
    CACHE PATH "Prepared iOS resources")
if(CMAKE_OSX_SYSROOT MATCHES "simulator")
    set(nodePlatform "ios-arm64_x86_64-simulator")
else()
    set(nodePlatform "ios-arm64")
endif()
set(nodeFramework "${RHINE_NODE_MOBILE_ROOT}/NodeMobile.xcframework/${nodePlatform}/NodeMobile.framework")
if(NOT EXISTS "${nodeFramework}/NodeMobile")
    message(FATAL_ERROR "NodeMobile.framework not found: ${nodeFramework}; run npm run build:ios")
endif()
target_link_libraries(RhineCore PRIVATE "${nodeFramework}")
set_target_properties(
    RhineMusicDatabase
    PROPERTIES MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Qt/InfoIOS.plist.in"
               MACOSX_BUNDLE_GUI_IDENTIFIER "${RHINE_APPLICATION_ID}"
               XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
               XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
               XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
               XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${RHINE_APPLICATION_ID}")
set_property(
    TARGET RhineMusicDatabase
    APPEND
    PROPERTY XCODE_EMBED_FRAMEWORKS "${nodeFramework}")
set_property(TARGET RhineMusicDatabase PROPERTY XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY OFF)
set(QT_NO_FFMPEG_XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY ON)
set(RHINE_IOS_FFMPEG_ROOT
    ""
    CACHE PATH "Matching FFmpeg frameworks for arm64 simulator")
if(CMAKE_OSX_SYSROOT MATCHES "simulator" AND RHINE_IOS_FFMPEG_ROOT)
    foreach(component avcodec avformat avutil swresample swscale)
        set(framework "${RHINE_IOS_FFMPEG_ROOT}/lib${component}.framework")
        if(NOT EXISTS "${framework}/lib${component}")
            message(FATAL_ERROR "Missing arm64 simulator FFmpeg framework: ${framework}")
        endif()
        target_link_libraries(RhineMusicDatabase PRIVATE "${framework}")
        set_property(
            TARGET RhineMusicDatabase
            APPEND
            PROPERTY XCODE_EMBED_FRAMEWORKS "${framework}")
    endforeach()
    set_property(
        TARGET RhineMusicDatabase
        APPEND
        PROPERTY XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks")
else()
    qt_add_ios_ffmpeg_libraries(RhineMusicDatabase)
endif()
if(NOT EXISTS "${RHINE_IOS_RESOURCES}/slots.json")
    message(FATAL_ERROR "iOS resources missing; run npm run build:ios")
endif()
file(GLOB_RECURSE iosResources CONFIGURE_DEPENDS "${RHINE_IOS_RESOURCES}/*")
# Finder 元数据可能进入暂存区，不把它登记为 Xcode 应用资源。
list(FILTER iosResources EXCLUDE REGEX "/[.]DS_Store$")
foreach(resource IN LISTS iosResources)
    file(RELATIVE_PATH resourcePath "${RHINE_IOS_RESOURCES}" "${resource}")
    get_filename_component(resourceDirectory "${resourcePath}" DIRECTORY)
    set_source_files_properties("${resource}" TARGET_DIRECTORY RhineMusicDatabase
                                PROPERTIES MACOSX_PACKAGE_LOCATION "RhineAssets/${resourceDirectory}")
endforeach()
target_sources(RhineMusicDatabase PRIVATE ${iosResources})

# 图标使用 iOS 原生尺寸
file(GLOB iosIcons "${CMAKE_SOURCE_DIR}/output/ios-icons/*.png")
set_source_files_properties(${iosIcons} TARGET_DIRECTORY RhineMusicDatabase PROPERTIES MACOSX_PACKAGE_LOCATION
                                                                                       Resources)
target_sources(RhineMusicDatabase PRIVATE ${iosIcons})
