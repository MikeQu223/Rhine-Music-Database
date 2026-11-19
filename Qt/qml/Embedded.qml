import QtQuick
import QtQuick.Window
import Rhine.Native 1.0

// Flutter 内嵌模式（RHINE_QT_EMBEDDED=1）的场景根。
//
// 这一层只做三件事，别的都不做：
//   1. 把宿主给的像素尺寸交给 Qt 的场景（rhine.resize）；
//   2. 承载 Qt 自己的 3D 层（Scene3D → RhiScene，材质/模型/相机/归档全部由 Qt 持有）；
//   3. 把**原始指针输入**按 Overlay.qml 的同一套舞台换算转给 rhine.pointer，
//      让 NativeSceneInput 的归档拖拽、唱片左右拖旋转、拾取选中在嵌入路径下照样成立。
//
// 这里刻意没有右栏遮罩：Qt 自己的右栏遮罩是 NativeHud 的 frame op（只在
// mode == archive 且 archive-mask-strength > 0 时画），而嵌入模式的 HUD 由 Flutter
// 画、Qt 的 Hud 项不在这一棵树里。此前这里抄过一份 Rectangle 渐变，几何按"铺满整个
// 舞台"算（maskRatio 789/984 of 1080 高），但宿主给的矩形只是左栏，于是遮罩压掉了
// 视图右侧 ~84% 的画面——那不是全幅构图，是几何错位。宿主矩形改成全幅之前，这里
// 不画任何遮罩；要遮罩就由宿主（Flutter HUD）自己画。
Item {
    id: root
    objectName: "embeddedRoot"

    // 与 Overlay.qml 完全相同的舞台换算：Qt 场景内部固定按 1080 高归一化
    // （Engine::resize 里 scene.resize(width / (height / 1080), 1080)），
    // 所以交给 rhine.pointer 的坐标是"舞台单位"，不是像素。
    readonly property real stageScale: height > 0 ? height / 1080 : 1

    // 场景尺寸：只有在宽高都大于 0 时才推，避免 QQuickView 创建到设尺寸之间把 0 推下去。
    function syncSize() {
        if (width > 0 && height > 0)
            rhine.resize(width, height);
    }

    Component.onCompleted: {
        syncSize();
        rhine.setVisible(true);
        inputLayer.forceActiveFocus();
    }
    onWidthChanged: syncSize()
    onHeightChanged: syncSize()

    // 3D 层：与 Overlay.qml 的 Scene3D 同一份组件，保证渲染路径完全一致。
    Scene3D {
        anchors.fill: parent
    }

    // 原始输入层（对齐 Overlay.qml 的 inputLayer）。
    //
    // 为什么必须有：Embedded.qml 之前完全没有输入层，rhine.pointer 一次都不会被调用，
    // NativeSceneInput 里已经实现的"归档拖拽"与"唱片左右拖旋转
    // （pointermove: m_targetRotation += dx * 0.004，clamp ±0.8）在嵌入路径下
    // 永远收不到事件——这是"原生唱片不支持左右拖旋转"最直接的一层原因。
    //
    // 为什么不在这里做手势判定：不造相机、不做第二次相机拖拽、不双消费。这里只把
    // 原始 down/move/up 交给 Qt，谁被拖、拖多远由 Qt 的场景状态机决定。
    MouseArea {
        id: inputLayer
        anchors.fill: parent
        objectName: "embeddedInputLayer"
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        focus: true

        // viewerPinch 活跃时必须让路：否则双指缩放期间这里还在发 pointermove/up，
        // 与 PinchHandler 的 pointercancel + pan 抢同一路输入（= 双消费同一手势）。
        // 权威实现见 Qt/qml/Overlay.qml 的 inputLayer（:95-97、:101-103、:107-109）。
        onPressed: (mouse) => {
            if (viewerPinch.active)
                return;
            forceActiveFocus();
            rhine.pointer("pointerdown", mouse.x / root.stageScale, mouse.y / root.stageScale);
        }
        onPositionChanged: (mouse) => {
            if (viewerPinch.active)
                return;
            rhine.pointer("pointermove", mouse.x / root.stageScale, mouse.y / root.stageScale);
        }
        onReleased: (mouse) => {
            if (viewerPinch.active)
                return;
            rhine.pointer("pointerup", mouse.x / root.stageScale, mouse.y / root.stageScale);
        }
        onCanceled: {
            rhine.pointer("pointercancel", 0, 0);
        }
        onExited: {
            rhine.pointer("pointerleave", 0, 0);
        }
        onWheel: (wheel) => {
            wheel.accepted = true;   // Overlay.qml:116 同义：滚轮在此被消费，不再冒泡
            rhine.wheelInput(wheel.x / root.stageScale, wheel.y / root.stageScale,
                             wheel.pixelDelta.y, wheel.angleDelta.y);
        }

        Keys.onPressed: (event) => {
            if (rhine.keyEvent(event.key, event.modifiers, event.text))
                event.accepted = true;
        }
    }

    // 封面查看页的双指平移（与 Overlay.qml 的 viewerPinch 同义）：只在 viewer 打开时
    // 生效，避免把归档拖拽的触点抢走。x/y 是位移增量，不是指针位置
    // （NativeApplication.cpp:224-227 的 positional 判定）。
    PinchHandler {
        id: viewerPinch
        target: null
        acceptedDevices: PointerDevice.TouchScreen
        enabled: !!(rhine.state && rhine.state.viewer)
        property point lastPan: Qt.point(0, 0)

        function forwardPan() {
            if (!active)
                return;
            const now = centroid.scenePosition;
            const dx = now.x - lastPan.x;
            const dy = now.y - lastPan.y;
            lastPan = now;
            if (dx === 0 && dy === 0)
                return;
            if (Math.abs(dx) > root.width * 0.4 || Math.abs(dy) > root.height * 0.4)
                return;
            rhine.pointer("pan", dx / root.stageScale, dy / root.stageScale);
        }
        onActiveChanged: {
            if (active) {
                // 第二根手指落下时结束可能已开始的单指旋转，避免两个手势叠加。
                rhine.pointer("pointercancel", 0, 0);
            }
            lastPan = active ? centroid.scenePosition : Qt.point(0, 0);
        }
        // 双指捏合缩放：与 Overlay.qml 完全同一条通路（wheelInput），
        // 350 来自 NativeViewer 的 pow(0.95, 0.7*|delta|*0.01) 换算。
        onScaleChanged: function (delta) {
            if (!active || !isFinite(delta) || delta <= 0)
                return;
            const p = centroid.scenePosition;
            rhine.wheelInput(p.x / root.stageScale, p.y / root.stageScale,
                             Math.log(delta) * 350, 0);
        }
        // 双保险：translationChanged 与 centroidChanged 哪个存在都能触发，
        // 都存在时第二次位移差为 0，天然幂等。
        onTranslationChanged: forwardPan()
        onCentroidChanged: forwardPan()
    }
}
