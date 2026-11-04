import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts

Item {
    id: root
    width: 640
    height: 104
    readonly property color gold: "#ffd18a"

    function timeText(ms) {
        const seconds = Math.max(0, Math.floor(ms / 1000));
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
    }

    // Bloom comes from a soft gradient around a narrow, bright core; no bitmap assets.
    component GlowLine: Item {
        implicitHeight: 2
        Rectangle {
            anchors.centerIn: parent
            width: parent.width + 12
            height: 20
            radius: 10
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: "#00ffbf68"
                }
                GradientStop {
                    position: 0.35
                    color: "#20ffbf68"
                }
                GradientStop {
                    position: 0.5
                    color: "#80ffbf68"
                }
                GradientStop {
                    position: 0.65
                    color: "#20ffbf68"
                }
                GradientStop {
                    position: 1
                    color: "#00ffbf68"
                }
            }
        }
        Rectangle {
            anchors.fill: parent
            color: "#fff2d1"
            radius: 1
        }
    }
    component GlowButton: Button {
        id: button
        implicitWidth: 72
        implicitHeight: 30
        font.family: rhineFontFamily
        font.pixelSize: 12
        hoverEnabled: true
        contentItem: Text {
            text: button.text
            font: button.font
            color: button.hovered || button.down ? "#fff5df" : root.gold
            style: Text.Raised
            styleColor: "#88000000"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            color: button.down ? "#38ffc470" : button.hovered ? "#20ffc470" : "transparent"
            border.color: "#66ffd18a"
        }
        HoverHandler {
            cursorShape: Qt.PointingHandCursor
        }
    }
    Rectangle {
        x: 5
        y: 12
        width: root.width - 10
        height: root.height - 16
        radius: 8
        color: "#10000000"
    }
    Rectangle {
        x: 8
        y: 13
        width: root.width - 16
        height: root.height - 20
        radius: 5
        color: "#18000000"
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 10
        color: "#55141718"
    }
    GlowLine {
        x: 10
        y: 10
        width: 30
        rotation: 0
    }
    GlowLine {
        x: root.width - 40
        y: root.height - 12
        width: 30
    }
    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 26
        anchors.rightMargin: 26
        anchors.topMargin: 16
        anchors.bottomMargin: 16
        spacing: 4
        RowLayout {
            spacing: 10
            Label {
                text: "RHINE / " + rhineMv.title
                font.family: rhineFontFamily
                font.pixelSize: 12
                font.letterSpacing: 0.5
                color: root.gold
                style: Text.Raised
                styleColor: "#88000000"
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            GlowButton {
                objectName: "desktopSettingsButton"
                implicitWidth: 52
                text: "设置"
                onClicked: rhineMv.showSettings()
            }
            GlowButton {
                objectName: "desktopPauseButton"
                text: rhineMv.playing ? "暂停" : "播放"
                onClicked: rhineMv.toggleMusic()
            }
            GlowButton {
                objectName: "desktopExitButton"
                text: "退出壁纸"
                onClicked: rhineMv.exitWallpaper()
            }
        }
        RowLayout {
            spacing: 14
            Label {
                text: root.timeText(progressBar.value * rhineMv.duration)
                color: root.gold
                font.pixelSize: 11
                Layout.preferredWidth: 38
            }
            Slider {
                id: progressBar
                objectName: "desktopProgress"
                Layout.fillWidth: true
                implicitHeight: 28
                from: 0
                to: 1
                enabled: rhineMv.seekable
                value: rhineMv.progress
                onPressedChanged: {
                    if (!pressed)
                        rhineMv.seekMusic(value);
                }
                background: Item {
                    x: progressBar.leftPadding
                    y: progressBar.topPadding + progressBar.availableHeight / 2
                    width: progressBar.availableWidth
                    height: 2
                    Rectangle {
                        anchors.fill: parent
                        color: "#50ffd18a"
                    }
                    GlowLine {
                        width: parent.width * progressBar.visualPosition
                        height: 2
                        visible: width > 0
                    }
                    Canvas {
                        id: wave
                        width: parent.width
                        height: 18
                        y: -16
                        property var displayed: []
                        onPaint: {
                            const ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            ctx.fillStyle = "#fff3d3";
                            ctx.shadowColor = "#ffc777";
                            ctx.shadowBlur = 5;
                            // Dots interpolate measured logarithmic FFT bands from the music decoder.
                            for (let x = 2; x < width; x += 5) {
                                const bin = x / Math.max(1, width) * Math.max(0, displayed.length - 1);
                                const i = Math.floor(bin);
                                const amount = (displayed[i] || 0) * (1 - (bin - i)) + (displayed[i + 1] || 0) * (bin - i);
                                const rise = 2 + 12 * amount;
                                ctx.beginPath();
                                ctx.arc(x, height - rise, 1.15, 0, Math.PI * 2);
                                ctx.fill();
                            }
                        }
                        FrameAnimation {
                            running: root.visible && rhineMv.playing
                            onTriggered: {
                                const target = rhineMv.spectrum;
                                for (let i = 0; i < target.length; ++i)
                                    wave.displayed[i] = (wave.displayed[i] || 0) + (target[i] - (wave.displayed[i] || 0)) * Math.min(1, frameTime * 14);
                                wave.requestPaint();
                            }
                        }
                    }
                }
                handle: Item {
                    x: progressBar.leftPadding + progressBar.visualPosition * (progressBar.availableWidth - width)
                    y: progressBar.topPadding + (progressBar.availableHeight - height) / 2
                    width: 10
                    height: 10
                    Rectangle {
                        anchors.centerIn: parent
                        width: 22
                        height: 22
                        radius: 11
                        color: "#18ffc060"
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 14
                        height: 14
                        radius: 7
                        color: "#40ffc060"
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "#fff3d3"
                        rotation: 45
                    }
                }
                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                }
            }
            Label {
                text: root.timeText(rhineMv.duration)
                color: root.gold
                font.pixelSize: 11
                Layout.preferredWidth: 38
            }
        }
    }
    Connections {
        target: rhineMv
        function onPlaybackChanged() {
            if (!progressBar.pressed)
                progressBar.value = rhineMv.progress;
            if (!rhineMv.playing) {
                wave.displayed = [];
                wave.requestPaint();
            }
        }
        function onSpectrumChanged() {
            if (wave.displayed.length !== rhineMv.spectrum.length)
                wave.displayed = rhineMv.spectrum.slice(0);
            if (!rhineMv.playing) {
                wave.displayed = [];
            }
            wave.requestPaint();
        }
    }
}
