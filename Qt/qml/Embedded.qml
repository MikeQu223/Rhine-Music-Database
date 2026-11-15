import QtQuick
import Rhine.Native 1.0

// Flutter 内嵌路径的 QML 根（RHINE_QT_EMBEDDED=1）。
//
// 这里只有场景层：没有 Window，也没有 Overlay。宿主是 Flutter 的 PlatformView——
// Qt 的 QQuickView 挂在 Flutter 传进来的父窗口上，占据 Siren 界面里原本属于
// 3D 容器的那块区域；材质、修改后的模型、相机、归档布局、抽出返回与触摸
// 全部由这一份 Qt 场景实现持有，Flutter 不在这里再叠一套 HUD，也不并行起
// 第二套播放器。
//
// 尺寸只在 Qt 这一侧换算：宿主 view 每次 resize（首帧、旋转、分屏、键盘）都会
// 走 onWidthChanged/onHeightChanged，渲染目标跟着变，场景状态不重建。
Item {
    id: root

    function syncSize() {
        if (width > 0 && height > 0)
            rhine.resize(width, height)
    }

    Component.onCompleted: {
        syncSize()
        rhine.setVisible(true)
    }
    onWidthChanged: syncSize()
    onHeightChanged: syncSize()

    Scene3D {
        anchors.fill: parent
    }
}
