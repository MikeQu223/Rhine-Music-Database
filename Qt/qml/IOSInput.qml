import QtQuick

// 触摸拖动：弹窗与歌曲详情整页滚动，资料库主界面只有列表区域响应。
Item {
    id: root
    required property var stage
    required property var backend
    width: stage.width
    height: stage.height

    DragHandler {
        target: null
        acceptedDevices: PointerDevice.TouchScreen
        enabled: (root.stage.ios || root.stage.compactLayout) && !(root.stage.compactLayout && root.backend.state.lyricsMode && !root.backend.state.modal) && (!!root.backend.state.modal || root.backend.state.mode === "detail")
        xAxis.enabled: false
        property real previousY: 0
        onActiveChanged: previousY = 0
        onTranslationChanged: {
            if (active) {
                const delta = translation.y - previousY;
                previousY = translation.y;
                root.backend.wheelInput(centroid.scenePosition.x / root.stage.stageScale, centroid.scenePosition.y / root.stage.stageScale, root.stage.compactLayout ? delta : delta / root.stage.stageScale, 0);
            }
        }
    }

    // 场景和列表各自接收从本区域开始的拖动，跨区后不切换手势所有者。
    Item {
        visible: root.stage.compactLayout && root.backend.state.mode === "archive" && !root.backend.state.modal
        width: root.stage.width
        height: (root.backend.state.archiveListY || 0) * root.stage.stageScale

        DragHandler {
            target: null
            acceptedDevices: PointerDevice.TouchScreen
            xAxis.enabled: false
            property real previousY: 0
            onActiveChanged: previousY = 0
            onTranslationChanged: {
                if (active) {
                    const delta = translation.y - previousY;
                    previousY = translation.y;
                    root.backend.wheelInput(centroid.scenePressPosition.x / root.stage.stageScale, centroid.scenePressPosition.y / root.stage.stageScale, root.stage.compactLayout ? delta : delta / root.stage.stageScale, 0);
                }
            }
        }
    }

    // 使用一个稳定的输入面覆盖整个列表，条目重绘不会打断按压或误触其他栏目。
    MouseArea {
        visible: root.stage.compactLayout && root.backend.state.mode === "archive" && !root.backend.state.modal
        x: 0
        y: (root.backend.state.archiveListY || 0) * root.stage.stageScale
        width: root.stage.width
        height: Math.max(0, ((root.backend.state.playerBounds || {}).y || 0) * root.stage.stageScale - y)
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        property real originY: 0
        property real previousY: 0
        property bool moved: false
        property string pressedAction: ""
        onPressed: function (mouse) {
            originY = mouse.y;
            previousY = mouse.y;
            moved = false;
            pressedAction = "";
            root.backend.pointer("pointercancel", 0, 0);
            root.backend.action("mobile:archive-begin");
            const px = mouse.x / root.stage.stageScale;
            const py = (y + mouse.y) / root.stage.stageScale;
            // 与 QML 控件的堆叠顺序一致，优先处理后绘制的行内按钮。
            for (let index = root.backend.hits.length - 1; index >= 0; --index) {
                const hit = root.backend.hits[index];
                if (px >= hit.x && px <= hit.x + hit.width && py >= hit.y && py <= hit.y + hit.height) {
                    pressedAction = hit.action;
                    break;
                }
            }
        }
        onPositionChanged: function (mouse) {
            if (!pressed) {
                return;
            }
            if (!moved && Math.abs(mouse.y - originY) <= 6) {
                return;
            }
            moved = true;
            const delta = mouse.y - previousY;
            previousY = mouse.y;
            root.backend.wheelInput(mouse.x / root.stage.stageScale, (y + originY) / root.stage.stageScale, delta, 0);
        }
        onReleased: {
            root.backend.action("mobile:archive-release");
            if (!moved && pressedAction) {
                root.backend.action(pressedAction);
            }
            pressedAction = "";
        }
        onCanceled: {
            root.backend.action("mobile:archive-release");
            pressedAction = "";
        }
        onWheel: function (wheel) {
            root.backend.wheelInput(wheel.x / root.stage.stageScale, (y + wheel.y) / root.stage.stageScale, wheel.pixelDelta.y, wheel.angleDelta.y);
            wheel.accepted = true;
        }
    }
    // 歌词滚动与页头下拉各自占有手势，滚动正文不会误关闭整页。
    Item {
        visible: root.stage.compactLayout && root.backend.state.lyricsMode && !root.backend.state.modal
        y: 158 * root.stage.stageScale * (root.backend.state.compactUnit || 1)
        width: root.width
        height: Math.max(0, ((root.backend.state.playerBounds || {}).y || 0) * root.stage.stageScale - y)
        DragHandler {
            target: null
            acceptedDevices: PointerDevice.TouchScreen
            xAxis.enabled: false
            property real previousY: 0
            onActiveChanged: previousY = 0
            onTranslationChanged: {
                if (active) {
                    const delta = translation.y - previousY;
                    previousY = translation.y;
                    root.backend.wheelInput(centroid.scenePosition.x / root.stage.stageScale, centroid.scenePosition.y / root.stage.stageScale, delta, 0);
                }
            }
        }
    }
    MouseArea {
        visible: root.stage.compactLayout && root.backend.state.lyricsMode && !root.backend.state.modal
        y: 60 * root.stage.stageScale * (root.backend.state.compactUnit || 1)
        width: root.width
        height: 96 * root.stage.stageScale * (root.backend.state.compactUnit || 1)
        preventStealing: true
        property real originY: 0
        property bool moved: false
        property string tapAction: ""
        onPressed: function (mouse) {
            originY = mouse.y;
            moved = false;
            tapAction = "";
            const px = mouse.x / root.stage.stageScale;
            const py = (y + mouse.y) / root.stage.stageScale;
            // 与 QML 控件的堆叠顺序一致，优先处理后绘制的行内按钮。
            for (let index = root.backend.hits.length - 1; index >= 0; --index) {
                const hit = root.backend.hits[index];
                if (px >= hit.x && px <= hit.x + hit.width && py >= hit.y && py <= hit.y + hit.height) {
                    tapAction = hit.action;
                    break;
                }
            }
        }
        onPositionChanged: function (mouse) {
            if (!pressed || (!moved && Math.abs(mouse.y - originY) < 6)) {
                return;
            }
            moved = true;
            root.backend.action("mobile:lyrics-drag:" + Math.max(0, mouse.y - originY) / root.stage.stageScale);
        }
        onReleased: {
            if (moved) {
                root.backend.action("mobile:lyrics-release");
            } else if (tapAction) {
                root.backend.action(tapAction);
            }
        }
        onCanceled: {
            root.backend.action("mobile:lyrics-drag:0");
            root.backend.action("mobile:lyrics-release");
        }
    }
}
