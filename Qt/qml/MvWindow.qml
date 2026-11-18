import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtMultimedia

ApplicationWindow {
    id: root
    width: 960
    height: 790
    minimumWidth: 620
    minimumHeight: 480
    visible: false
    flags: Qt.Window | (Qt.platform.os === "windows" ? Qt.FramelessWindowHint : 0) | Qt.WindowTitleHint | Qt.WindowSystemMenuHint | Qt.WindowMinMaxButtonsHint | Qt.WindowCloseButtonHint | Qt.WindowFullscreenButtonHint | (rhineMv.pinned ? Qt.WindowStaysOnTopHint : 0) | (root.locked ? Qt.WindowTransparentForInput : 0)
    readonly property bool locked: rhineMv.locked && !rhineMv.wallpaper
    onLockedChanged: {
        revealControls();
        if (locked)
            Qt.callLater(positionUnlock);
    }
    onXChanged: {
        if (locked)
            Qt.callLater(positionUnlock);
    }
    onYChanged: {
        if (locked)
            Qt.callLater(positionUnlock);
    }
    onWidthChanged: {
        if (locked)
            Qt.callLater(positionUnlock);
    }
    onHeightChanged: {
        if (locked)
            Qt.callLater(positionUnlock);
    }
    property bool controlsReady: false
    readonly property bool dark: rhine.state.dark === true
    readonly property bool fullscreen: visibility === Window.FullScreen
    property bool controlsVisible: true
    readonly property bool customChrome: Qt.platform.os === "windows" && !fullscreen
    readonly property int chromeHeight: customChrome ? 32 : 0
    // Same palette as NativeHudModal and SettingsCard.
    readonly property color panelColor: dark ? "#262626" : "#edebe4"
    readonly property color ink: dark ? "#ebebeb" : "#141613"
    readonly property color muted: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
    readonly property color line: Qt.rgba(ink.r, ink.g, ink.b, 0.25)
    readonly property color faint: Qt.rgba(ink.r, ink.g, ink.b, 0.12)
    readonly property color gold: "#d5a348"
    readonly property color buttonTint: dark ? Qt.rgba(0.55, 0.59, 0.46, 0.13) : Qt.rgba(0.44, 0.49, 0.36, 0.10)
    readonly property color hoverTint: dark ? Qt.rgba(0.55, 0.59, 0.46, 0.24) : Qt.rgba(0.44, 0.49, 0.36, 0.18)
    Component.onCompleted: controlsReady = true
    title: "MV · " + (rhineMv.title || "RHINE MUSIC DATABASE")
    color: panelColor
    font.family: rhineFontFamily
    font.pixelSize: 14
    palette.window: panelColor
    palette.windowText: ink
    palette.base: panelColor
    palette.text: ink
    palette.button: buttonTint
    palette.buttonText: ink
    palette.highlight: gold
    onClosing: function (close) {
        close.accepted = false;
        if (rhineMv.wallpaperActive)
            root.hide();
        else
            rhineMv.enabled = false;
    }
    onFullscreenChanged: revealControls()
    onVisibleChanged: {
        revealControls();
        if (locked)
            Qt.callLater(positionUnlock);
    }
    onActiveChanged: {
        if (active)
            revealControls();
    }

    function revealControls() {
        controlsVisible = true;
        if (fullscreen && visible)
            controlsTimer.restart();
        else
            controlsTimer.stop();
    }
    function positionUnlock() {
        if (!locked || !unlockSurface)
            return;
        const point = rhineMv.relativeUnlock ? lockButton.mapToItem(null, 0, 0) : lockButton.mapToGlobal(Qt.point(0, 0));
        unlockSurface.x = Math.round(point.x);
        unlockSurface.y = Math.round(point.y);
    }

    Timer {
        id: controlsTimer
        interval: 2500
        onTriggered: {
            if (root.locked || versionBox.popup.visible || opacityControl.pressed || activityPress.pressed)
                restart();
            else
                root.controlsVisible = false;
        }
    }

    component TerminalButton: Button {
        id: control
        implicitWidth: Math.max(64, implicitContentWidth + 24)
        implicitHeight: 34
        padding: 8
        hoverEnabled: true
        font.family: root.font.family
        font.pixelSize: 13
        contentItem: Text {
            text: control.text
            font: control.font
            color: control.enabled ? root.ink : root.muted
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            color: control.down || control.hovered ? root.hoverTint : root.buttonTint
            border.width: 1
            border.color: control.visualFocus ? root.gold : "transparent"
        }
        HoverHandler {
            cursorShape: Qt.PointingHandCursor
        }
    }
    component TerminalCombo: ComboBox {
        id: comboControl
        Layout.fillWidth: true
        implicitHeight: 34
        padding: 0
        ToolTip.visible: hovered
        ToolTip.text: displayText
        contentItem: Text {
            text: comboControl.displayText
            font: comboControl.font
            color: root.ink
            verticalAlignment: Text.AlignVCenter
            leftPadding: 12
            rightPadding: 30
            elide: Text.ElideRight
        }
        indicator: Text {
            x: comboControl.width - width - 12
            y: (comboControl.height - height) / 2
            text: comboControl.popup.visible ? "▴" : "▾"
            color: root.muted
            font.pixelSize: 12
        }
        background: Rectangle {
            color: root.dark ? Qt.rgba(1, 1, 1, 0.05) : Qt.rgba(0, 0, 0, 0.04)
            border.color: comboControl.visualFocus ? root.gold : root.line
        }
        delegate: ItemDelegate {
            id: option
            required property var modelData
            required property int index
            width: comboControl.width - 4
            height: 36
            text: modelData
            highlighted: comboControl.highlightedIndex === index
            ToolTip.visible: hovered
            ToolTip.text: text
            contentItem: Text {
                text: option.text
                font: comboControl.font
                color: root.ink
                leftPadding: 12
                rightPadding: 12
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            background: Rectangle {
                color: option.highlighted ? root.buttonTint : "transparent"
                Rectangle {
                    width: 2
                    height: parent.height
                    color: root.gold
                    visible: option.index === comboControl.currentIndex
                }
            }
        }
        popup: Popup {
            y: comboControl.height + 4
            width: comboControl.width
            padding: 2
            implicitHeight: Math.min(contentItem.implicitHeight + 4, 220)
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: comboControl.popup.visible ? comboControl.delegateModel : null
                currentIndex: comboControl.highlightedIndex
                boundsBehavior: Flickable.StopAtBounds
                ScrollIndicator.vertical: ScrollIndicator {}
            }
            background: Rectangle {
                color: root.panelColor
                border.color: root.line
            }
        }
    }
    component SectionLabel: Label {
        color: root.muted
        font.pixelSize: 10
        font.letterSpacing: 0.8
    }
    Shortcut {
        sequence: "F11"
        onActivated: rhineMv.toggleFullscreen()
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.fullscreen
        onActivated: rhineMv.toggleFullscreen()
    }

    header: ToolBar {
        id: terminalHeader
        opacity: !root.fullscreen || root.controlsVisible ? 1 : 0
        enabled: !root.locked && (!root.fullscreen || root.controlsVisible)
        z: 3
        implicitHeight: root.fullscreen ? 88 : root.chromeHeight + 104
        padding: 0
        background: Rectangle {
            color: root.panelColor
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: root.line
            }
        }
        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 28
            anchors.rightMargin: 28
            anchors.topMargin: root.chromeHeight + 12
            anchors.bottomMargin: 14
            spacing: 6
            SectionLabel {
                visible: !root.fullscreen
                text: "RHINE LAB / MUSIC DATABASE / VIDEO TERMINAL"
            }
            RowLayout {
                spacing: 10
                Label {
                    text: "MUSIC VIDEO"
                    color: root.ink
                    font.pixelSize: root.fullscreen || root.width < 820 ? 20 : 26
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1
                    Layout.fillWidth: true
                }
                TerminalButton {
                    visible: !rhineMv.wallpaper
                    implicitWidth: 34
                    Accessible.name: rhineMv.pinned ? "取消置顶" : "置顶 MV 窗口"
                    ToolTip.visible: hovered
                    ToolTip.text: Accessible.name
                    onClicked: rhineMv.pinned = !rhineMv.pinned
                    contentItem: Item {
                        Canvas {
                            id: pinIcon
                            readonly property color glyphColor: rhineMv.pinned ? root.gold : root.ink
                            onGlyphColorChanged: requestPaint()
                            width: 18
                            height: 20
                            anchors.centerIn: parent
                            onPaint: {
                                const ctx = getContext("2d");
                                ctx.clearRect(0, 0, width, height);
                                ctx.save();
                                ctx.translate(9, 9);
                                ctx.rotate(rhineMv.pinned ? 0 : -0.4);
                                ctx.strokeStyle = glyphColor;
                                ctx.lineWidth = 1.4;
                                ctx.beginPath();
                                ctx.moveTo(-4, -6);
                                ctx.lineTo(4, -6);
                                ctx.moveTo(-2, -5);
                                ctx.lineTo(-2, 0);
                                ctx.lineTo(-5, 3);
                                ctx.lineTo(5, 3);
                                ctx.lineTo(2, 0);
                                ctx.lineTo(2, -5);
                                ctx.moveTo(0, 3);
                                ctx.lineTo(0, 8);
                                ctx.stroke();
                                ctx.restore();
                            }
                            Connections {
                                target: rhineMv
                                function onChanged() {
                                    pinIcon.requestPaint();
                                }
                            }
                        }
                    }
                }
                TerminalButton {
                    id: lockButton
                    visible: !rhineMv.wallpaper
                    text: root.locked ? "解锁" : "锁定"
                    onClicked: rhineMv.locked = !rhineMv.locked
                }
                TerminalButton {
                    visible: rhineMv.wallpaperSupported
                    text: rhineMv.wallpaper ? "返回窗口" : "桌面壁纸"
                    onClicked: rhineMv.wallpaper = !rhineMv.wallpaper
                }
                TerminalButton {
                    enabled: !rhineMv.wallpaper
                    text: root.fullscreen ? "退出全屏" : root.width < 820 ? "⛶" : "全屏 / F11"
                    onClicked: rhineMv.toggleFullscreen()
                }
                TerminalButton {
                    text: rhineMv.wallpaperActive ? "隐藏设置" : root.width < 820 ? "×" : "关闭 MV"
                    onClicked: {
                        if (rhineMv.wallpaperActive)
                            root.hide();
                        else
                            rhineMv.enabled = false;
                    }
                }
            }
            Label {
                text: "关联影像 / " + (rhineMv.title || "静音跟随音乐播放")
                color: root.muted
                font.pixelSize: 13
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
        WindowChrome {
            parent: terminalHeader
            anchors.fill: undefined
            x: 0
            y: 0
            width: root.width
            height: root.height
            z: 100
            visible: root.customChrome
            enabled: !root.locked
            window: root
            dark: root.dark
            onMinimizeRequested: root.showMinimized()
        }
        Rectangle {
            parent: terminalHeader
            width: root.width
            height: root.height
            color: "transparent"
            border.color: root.line
            visible: root.customChrome
            z: 99
        }
    }

    Item {
        id: videoViewport
        anchors.fill: parent
        // Fullscreen controls overlay the video, so hiding them never resizes the picture.
        anchors.topMargin: root.fullscreen ? -terminalHeader.height : 0
        anchors.bottomMargin: root.fullscreen ? -terminalFooter.height : 0
        HoverHandler {
            property point lastPosition: Qt.point(-1, -1)
            enabled: root.fullscreen
            blocking: false
            onPointChanged: {
                if (point.scenePosition.x !== lastPosition.x || point.scenePosition.y !== lastPosition.y) {
                    lastPosition = point.scenePosition;
                    root.revealControls();
                }
            }
        }
        TapHandler {
            id: activityPress
            enabled: root.fullscreen
            acceptedButtons: Qt.AllButtons
            onPressedChanged: root.revealControls()
        }
        Rectangle {
            anchors.fill: parent
            color: rhineMv.ready ? "#111211" : root.panelColor
        }
        VideoOutput {
            id: video
            anchors.fill: parent
            visible: rhineMv.ready && !rhineMv.wallpaperActive
            fillMode: VideoOutput.PreserveAspectFit
            endOfStreamPolicy: VideoOutput.KeepLastFrame
            Component.onCompleted: rhineMv.attachVideo(videoSink)
        }
        Connections {
            target: rhineMv
            function onChanged() {
                // ComboBox selects its first row when a new model arrives; restore the actual selection afterwards.
                Qt.callLater(function () {
                    versionBox.currentIndex = rhineMv.versionIndex;
                });
            }
            function onScreensChanged() {
                Qt.callLater(function () {
                    screenBox.currentIndex = rhineMv.screenIndex;
                });
            }
        }
        Connections {
            target: rhineMv
            function onVideoCleared() {
                video.clearOutput();
            }
        }
        Column {
            anchors.centerIn: parent
            width: Math.min(500, parent.width - 56)
            spacing: 18
            visible: !rhineMv.ready || rhineMv.wallpaperActive
            Label {
                text: rhineMv.wallpaperActive && rhineMv.ready ? "DESKTOP VIDEO" : "VIDEO STANDBY"
                color: root.ink
                font.pixelSize: 22
                font.weight: Font.DemiBold
                font.letterSpacing: 1.5
                anchors.horizontalCenter: parent.horizontalCenter
            }
            Label {
                width: parent.width
                text: rhineMv.wallpaperActive && rhineMv.ready ? "MV 正在桌面同步播放。关闭此窗口后壁纸继续，可从桌面控制条打开设置" : rhineMv.status
                color: root.muted
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
            TerminalButton {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "重新查找 MV"
                onClicked: rhineMv.retry()
            }
        }
    }

    footer: Rectangle {
        id: terminalFooter
        opacity: !root.fullscreen || root.controlsVisible ? 1 : 0
        enabled: !root.locked && (!root.fullscreen || root.controlsVisible)
        z: 2
        color: root.panelColor
        implicitHeight: controls.implicitHeight + 28
        Rectangle {
            width: parent.width
            height: 1
            color: root.line
        }
        ColumnLayout {
            id: controls
            anchors.fill: parent
            anchors.leftMargin: 28
            anchors.rightMargin: 28
            anchors.topMargin: 14
            anchors.bottomMargin: 14
            spacing: 10
            RowLayout {
                spacing: 24
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    SectionLabel {
                        text: "01 / VIDEO VERSION / 视频版本"
                    }
                    TerminalCombo {
                        id: versionBox
                        model: rhineMv.versionLabels
                        enabled: count > 0
                        displayText: rhineMv.versionIndex >= 0 ? currentText : (rhineMv.versionStatus || "请选择视频版本")
                        currentIndex: rhineMv.versionIndex
                        onActivated: rhineMv.versionIndex = currentIndex
                    }
                }
                ColumnLayout {
                    Layout.preferredWidth: 218
                    Layout.minimumWidth: 218
                    Layout.maximumWidth: 218
                    spacing: 6
                    SectionLabel {
                        text: "02 / OPACITY / 透明度"
                    }
                    RowLayout {
                        spacing: 12
                        Slider {
                            id: opacityControl
                            Layout.fillWidth: true
                            implicitHeight: 34
                            from: 0.2
                            to: 1.0
                            stepSize: 0.05
                            value: rhineMv.opacity
                            onValueChanged: {
                                if (root.controlsReady && Math.abs(value - rhineMv.opacity) > 0.001) {
                                    rhineMv.opacity = value;
                                }
                            }
                            background: Rectangle {
                                x: opacityControl.leftPadding
                                y: opacityControl.topPadding + (opacityControl.availableHeight - height) / 2
                                width: opacityControl.availableWidth
                                height: 3
                                color: root.faint
                                Rectangle {
                                    width: parent.width * opacityControl.visualPosition
                                    height: parent.height
                                    color: root.gold
                                }
                            }
                            handle: Rectangle {
                                x: opacityControl.leftPadding + opacityControl.visualPosition * (opacityControl.availableWidth - width)
                                y: opacityControl.topPadding + (opacityControl.availableHeight - height) / 2
                                width: 8
                                height: 18
                                color: root.ink
                                border.color: opacityControl.visualFocus ? root.gold : root.ink
                            }
                        }
                        Label {
                            Layout.preferredWidth: 42
                            text: Math.round(rhineMv.opacity * 100) + "%"
                            color: root.ink
                            font.pixelSize: 13
                        }
                    }
                }
            }
            RowLayout {
                visible: rhineMv.wallpaper
                spacing: 16
                SectionLabel {
                    text: "03 / DESKTOP DISPLAY / 壁纸显示器"
                }
                TerminalCombo {
                    id: screenBox
                    model: rhineMv.screenLabels
                    currentIndex: rhineMv.screenIndex
                    onActivated: rhineMv.screenIndex = currentIndex
                }
            }
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: root.faint
            }
            RowLayout {
                spacing: 8
                Label {
                    Layout.fillWidth: true
                    text: (rhineMv.presentationStatus ? rhineMv.presentationStatus + " · " : "") + rhineMv.status + (rhineMv.versionStatus ? " · " + rhineMv.versionStatus : "")
                    color: root.muted
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
                Label {
                    text: "画面偏移 " + (rhineMv.offset / 1000).toFixed(1) + "s"
                    color: root.muted
                    font.pixelSize: 12
                }
                TerminalButton {
                    text: "刷新版本"
                    onClicked: rhineMv.retry()
                }
                TerminalButton {
                    text: "−0.5s"
                    onClicked: rhineMv.adjustOffset(-500)
                }
                TerminalButton {
                    text: "+0.5s"
                    onClicked: rhineMv.adjustOffset(500)
                }
                TerminalButton {
                    text: "归零"
                    onClicked: rhineMv.resetOffset()
                }
            }
        }
    }
    // The video surface passes clicks through; only this same-position unlock affordance accepts input.
    Window {
        id: unlockSurface
        title: "MV · 解锁"
        screen: root.screen
        transientParent: rhineMv.relativeUnlock ? null : root
        Component.onCompleted: rhineMv.registerUnlockWindow(unlockSurface)
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | (rhineMv.pinned ? Qt.WindowStaysOnTopHint : 0)
        visible: root.locked && root.visible && root.visibility !== Window.Minimized && rhineMv.enabled
        onVisibleChanged: {
            if (visible)
                Qt.callLater(root.positionUnlock);
        }
        width: lockButton.width
        height: lockButton.height
        color: root.panelColor
        TerminalButton {
            anchors.fill: parent
            text: "解锁"
            Accessible.name: "解锁 MV 窗口"
            onClicked: rhineMv.locked = false
            background: Rectangle {
                color: root.buttonTint
                border.color: root.gold
            }
        }
    }
}
