import QtQuick

// 触摸拖动 → 滚轮：列表/弹层的滚动在桌面吃滚轮事件，触摸端把拖动换算成同一条通路，
// 不给场景另开一套手势语义。iOS 只在弹层与详情里接管（主场景与系统返回手势冲突）；
// Android 全程接管——主场景的列表在桌面同样吃滚轮，拖动就是它的滑动。
DragHandler {
    required property var stage
    required property var backend
    target: null
    acceptedDevices: PointerDevice.TouchScreen
    enabled: stage.ios ? (!!backend.state.modal || backend.state.mode === "detail")
                       : stage.android
    xAxis.enabled: false
    property real previousY: 0
    onActiveChanged: previousY = 0
    onTranslationChanged: {
        if (active) {
            const delta = translation.y - previousY;
            previousY = translation.y;
            backend.wheelInput(centroid.scenePosition.x / stage.stageScale, centroid.scenePosition.y / stage.stageScale, delta / stage.stageScale, 0);
        }
    }
}
