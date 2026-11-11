import QtQuick
import QtQuick.Window
import Rhine.Native 1.0

// 组合根：Window 只负责窗口本身与"必须挂在窗口上"的对象，画面内容拆成两层——
// Scene3D.qml（3D，可被 FG 单独以渲染帧率出图并插值）与 Overlay.qml（UI，按显示帧率叠加）。
// 默认路径（不开 FG）下两层仍由这个 Window 承载，渲染顺序、坐标、焦点与交互与拆分前一致；
// FG 路径下由 SceneLayerHost 用两个 QQuickRenderControl 分别载入这两个文件。
Window {
    id: root
    readonly property bool ios: Qt.platform.os === "ios"
    readonly property bool android: Qt.platform.os === "android"
    width: 1280
    height: 720
    // 移动端是全屏 Activity，窗口尺寸跟随屏幕；给桌面保留的最小尺寸在手机上会把布局顶破。
    minimumWidth: ios || android ? 0 : 320
    minimumHeight: ios || android ? 0 : 540
    visible: true
    property bool windowsFrameless: Qt.platform.os === "windows"
    flags: (windowsFrameless ? Qt.FramelessWindowHint : 0) | Qt.Window | Qt.WindowTitleHint | Qt.WindowSystemMenuHint | Qt.WindowMinMaxButtonsHint | Qt.WindowCloseButtonHint | Qt.WindowFullscreenButtonHint
    title: "RHINE MUSIC DATABASE"
    color: "#e7e7e1"
    // Tray-close events are intercepted before QML. On an accepted primary-window close,
    // hide the companion so it cannot keep Qt's last-window quit behavior alive.
    onClosing: {
        if (!root.ios) {
            rhineMv.hideForQuit();
        }
    }
    // 原生对话框挂在真实窗口；iOS 使用独立的导入入口。
    Loader {
        active: !root.ios
        sourceComponent: LocalMusicDialogs {
            backend: rhine
        }
    }
    // 舞台换算留在 Window 上：Overlay 注入后与原值完全相同，但公开属性不变，
    // 外部（测试/后续 FG 宿主）仍可按原方式读取。
    property real stageScale: height / 1080
    property real stageWidth: width / stageScale
    onVisibilityChanged: function (visibility) {
        rhine.setVisible(visible && visibility !== Window.Minimized);
    }
    onWidthChanged: rhine.resize(width, height)
    onHeightChanged: rhine.resize(width, height)
    Component.onCompleted: {
        rhine.resize(width, height);
        // 焦点原本落在 Window 里的 inputLayer 上；拆层后它在 Overlay 内部。
        overlay.focusInputLayer();
    }
    // 快捷键（Ctrl+Q / F11 / F10）已随 UI 层一起迁到 Overlay.qml。
    // 原因：FG 路径根本不加载 Main.qml，留在 Window 侧等于 FG 完全没有快捷键；
    // 而 Overlay.qml 在两条路径下都会被实例化，所以只保留那一份定义，
    // 默认路径不会出现重复注册。
    // 3D 层：RhiScene。
    Scene3D {
        anchors.fill: parent
    }
    // UI 层：原 Main.qml:78-336 的 HUD、输入层、面板、搜索框、窗口边框与性能面板。
    Overlay {
        id: overlay
        anchors.fill: parent
        stageScale: root.stageScale
        stageWidth: root.stageWidth
        hostWindow: root
        frameless: root.windowsFrameless
    }
}
