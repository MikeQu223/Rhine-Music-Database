# 将应用的 QML 扫描限定在 Qt 源码目录，避免遍历部署包和 Node 依赖。 资源、平台依赖和打包钩子由根目录配置完成后再统一结束目标初始化。
qt_add_executable(RhineMusicDatabase WIN32 MACOSX_BUNDLE MANUAL_FINALIZATION ${RHINE_APP_SOURCES})
include("${CMAKE_SOURCE_DIR}/cmake/CrashDiagnostics.cmake")
target_sources(RhineMusicDatabase PRIVATE src/Gamepad.cpp src/Gamepad.h)
set_target_properties(RhineMusicDatabase PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
if(WIN32)
    target_link_libraries(RhineMusicDatabase PRIVATE xinput9_1_0)
endif()
set_source_files_properties(qml/Main.qml PROPERTIES QT_RESOURCE_ALIAS Main.qml)
set_source_files_properties(qml/PerformancePanel.qml PROPERTIES QT_RESOURCE_ALIAS PerformancePanel.qml)
set_source_files_properties(qml/WindowChrome.qml PROPERTIES QT_RESOURCE_ALIAS WindowChrome.qml)
# FG 路径把 3D 与 UI 拆成两个可独立渲染的场景；Main.qml 的默认路径用同样两个组件组合， 所以两条路径共用同一份界面定义，不会各自漂移。
set_source_files_properties(qml/Scene3D.qml PROPERTIES QT_RESOURCE_ALIAS Scene3D.qml)
set_source_files_properties(qml/Overlay.qml PROPERTIES QT_RESOURCE_ALIAS Overlay.qml)
set_source_files_properties(qml/IOSInput.qml PROPERTIES QT_RESOURCE_ALIAS IOSInput.qml)
set_source_files_properties(qml/LocalMusicDialogs.qml PROPERTIES QT_RESOURCE_ALIAS LocalMusicDialogs.qml)
set_source_files_properties(qml/MvWindow.qml PROPERTIES QT_RESOURCE_ALIAS MvWindow.qml)
set_source_files_properties(qml/MvWallpaper.qml PROPERTIES QT_RESOURCE_ALIAS MvWallpaper.qml)
set_source_files_properties(qml/MvDesktopControls.qml PROPERTIES QT_RESOURCE_ALIAS MvDesktopControls.qml)
qt_add_qml_module(
    RhineMusicDatabase
    URI
    RhineMusic
    VERSION
    1.0
    OUTPUT_DIRECTORY
    "${CMAKE_BINARY_DIR}/RhineMusic"
    QML_FILES
    qml/Main.qml
    qml/MvWindow.qml
    qml/MvWallpaper.qml
    qml/MvDesktopControls.qml
    qml/IOSInput.qml
    qml/LocalMusicDialogs.qml
    qml/PerformancePanel.qml
    qml/WindowChrome.qml
    qml/Scene3D.qml
    qml/Overlay.qml)
