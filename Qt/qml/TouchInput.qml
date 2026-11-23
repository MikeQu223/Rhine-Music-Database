import QtQuick

// 触摸拖动 → 滚轮：列表与弹层的滚动在桌面吃滚轮事件，触摸端把拖动换算成同一条通路，
// 不给场景另开一套手势语义。
// iOS 只在弹层与详情里接管（主场景与系统返回手势冲突）；其余平台全程接管——主场景的
// 列表在桌面同样吃滚轮，拖动就是它的滑动。
// 封面查看页（viewer）例外：那里单指拖动是球面旋转、双指捏合是缩放，滚轮语义不适用，
// 所以 viewer 打开时整个 handler 让位（缩放与平移见 Overlay.qml 的 PinchHandler）。
Item {
    id: root
    required property var stage
    required property var backend
    width: stage.width
    height: stage.height

    function discoverGroupAt(stageX, stageY) {
        const zones = root.backend.state.discoverSwipeZones || [];
        for (let index = zones.length - 1; index >= 0; --index) {
            const zone = zones[index];
            const area = root.stage.hitArea(zone);
            if (stageX >= area.x && stageX <= area.x + area.width && stageY >= area.y && stageY <= area.y + area.height) {
                return zone.group || "";
            }
        }
        return "";
    }

    function discoverDesignDelta(pixels) {
        const unit = root.backend.state.compactUnit || 1;
        return pixels / Math.max(0.0001, root.stage.stageScale * unit);
    }

    // Android 全程接管；iOS 非紧凑布局仍由这里处理弹层与详情。
    // 紧凑布局交给下面的原 IOSInput 手势，避免同一拖动触发两次滚轮。
    DragHandler {
        target: null
        acceptedDevices: PointerDevice.TouchScreen
        enabled: (root.stage.ios ? (!!root.backend.state.modal || root.backend.state.mode === "detail") : (root.stage.android || !root.stage.compactLayout)) && !root.backend.state.viewer && !(root.stage.ios && root.stage.compactLayout) && !(root.stage.compactLayout && root.backend.state.modal === "discover")
        xAxis.enabled: false
        property real previousY: 0
        onActiveChanged: previousY = 0
        onTranslationChanged: {
            if (active) {
                const delta = translation.y - previousY;
                previousY = translation.y;
                root.backend.wheelInput(centroid.scenePosition.x / root.stage.stageScale, centroid.scenePosition.y / root.stage.stageScale, delta / root.stage.stageScale, 0);
            }
        }
    }

    // 以下为原 IOSInput.qml 的紧凑布局手势，只在非 Android 的紧凑布局下启用。

    // 触摸拖动：弹窗与歌曲详情整页滚动，资料库主界面只有列表区域响应。
    DragHandler {
        target: null
        acceptedDevices: PointerDevice.TouchScreen
        enabled: root.stage.compactLayout && !root.stage.android && !(root.stage.compactLayout && root.backend.state.lyricsMode && !root.backend.state.modal) && root.backend.state.modal !== "discover" && (!!root.backend.state.modal || root.backend.state.mode === "detail")
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

    // 发现页使用稳定输入面统一处理点击和轴锁定滑动；横向拖动不会穿透成卡片点击。
    MouseArea {
        id: discoverInput
        visible: root.stage.compactLayout && root.backend.state.modal === "discover" && !root.backend.state.viewer
        x: 0
        y: 130 * (root.backend.state.compactUnit || 1) * root.stage.stageScale
        width: root.stage.width
        height: Math.max(0, ((root.backend.state.playerBounds || {}).y || 0) * root.stage.stageScale - y)
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor

        property real originX: 0
        property real originY: 0
        property real previousX: 0
        property real previousY: 0
        property real pressX: 0
        property real pressY: 0
        property string axisLock: "none"
        property string scrollGroup: ""
        property string pressedAction: ""

        onPressed: function (mouse) {
            root.stage.focusInputLayer();
            originX = mouse.x;
            originY = mouse.y;
            previousX = mouse.x;
            previousY = mouse.y;
            pressX = mouse.x / root.stage.stageScale;
            pressY = (y + mouse.y) / root.stage.stageScale;
            axisLock = "none";
            scrollGroup = root.discoverGroupAt(pressX, pressY);
            pressedAction = "";
            for (let index = root.backend.hits.length - 1; index >= 0; --index) {
                const hit = root.backend.hits[index];
                const area = root.stage.hitArea(hit);
                if (pressX >= area.x && pressX <= area.x + area.width && pressY >= area.y && pressY <= area.y + area.height) {
                    pressedAction = hit.action;
                    break;
                }
            }
        }

        onPositionChanged: function (mouse) {
            if (!pressed) {
                return;
            }
            const dx = mouse.x - originX;
            const dy = mouse.y - originY;
            if (axisLock === "none" && Math.max(Math.abs(dx), Math.abs(dy)) > 6) {
                axisLock = Math.abs(dx) > Math.abs(dy) && scrollGroup !== "" ? "x" : "y";
            }
            if (axisLock === "x") {
                const delta = mouse.x - previousX;
                previousX = mouse.x;
                previousY = mouse.y;
                if (delta !== 0) {
                    const action = "mobile:discover-scroll:" + scrollGroup + ":" +
                        root.discoverDesignDelta(delta).toFixed(3);
                    root.backend.action(action);
                }
            } else if (axisLock === "y") {
                const delta = mouse.y - previousY;
                previousX = mouse.x;
                previousY = mouse.y;
                if (delta !== 0) {
                    root.backend.wheelInput(pressX, pressY, delta, 0);
                }
            }
        }

        onReleased: {
            if (axisLock === "none" && pressedAction !== "") {
                root.backend.action(pressedAction);
            }
            axisLock = "none";
            scrollGroup = "";
            pressedAction = "";
        }

        onCanceled: {
            axisLock = "none";
            scrollGroup = "";
            pressedAction = "";
        }

        onWheel: function (wheel) {
            const stageX = wheel.x / root.stage.stageScale;
            const stageY = (y + wheel.y) / root.stage.stageScale;
            const group = root.discoverGroupAt(stageX, stageY);
            const dx = wheel.pixelDelta.x || wheel.angleDelta.x / 8;
            const dy = wheel.pixelDelta.y || wheel.angleDelta.y / 8;
            if (group !== "" && Math.abs(dx) > Math.abs(dy)) {
                const delta = dx;
                if (delta !== 0) {
                    const action = "mobile:discover-scroll:" + group + ":" +
                        root.discoverDesignDelta(delta).toFixed(3);
                    root.backend.action(action);
                }
            } else {
                root.backend.wheelInput(stageX, stageY, wheel.pixelDelta.y, wheel.angleDelta.y);
            }
            wheel.accepted = true;
        }
    }

    // 场景和列表各自接收从本区域开始的拖动，跨区后不切换手势所有者。
    Item {
        visible: !root.stage.android && root.stage.compactLayout && root.backend.state.mode === "archive" && !root.backend.state.modal
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
        visible: !root.stage.android && root.stage.compactLayout && root.backend.state.mode === "archive" && !root.backend.state.modal
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
        visible: !root.stage.android && root.stage.compactLayout && ((root.backend.state.lyricsMode && (root.backend.state.playerModeProgress || 0) > .001) || root.backend.state.commentsMode) && !root.backend.state.modal
        y: (root.backend.state.lyricsContentTop || 0) * root.stage.stageScale
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
        visible: !root.stage.android && root.stage.compactLayout && (root.backend.state.lyricsMode || root.backend.state.commentsMode) && !root.backend.state.modal
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
            const prefix = root.backend.state.commentsMode ? "mobile:comments-drag:" : "mobile:lyrics-drag:";
            root.backend.action(prefix + Math.max(0, mouse.y - originY) / root.stage.stageScale);
        }
        onReleased: {
            if (moved) {
                root.backend.action(root.backend.state.commentsMode ? "mobile:comments-release" : "mobile:lyrics-release");
            } else if (tapAction) {
                root.backend.action(tapAction);
            }
        }
        onCanceled: {
            root.backend.action(root.backend.state.commentsMode ? "mobile:comments-drag:0" : "mobile:lyrics-drag:0");
            root.backend.action(root.backend.state.commentsMode ? "mobile:comments-release" : "mobile:lyrics-release");
        }
    }
}
