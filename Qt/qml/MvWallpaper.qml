import QtQuick
import QtQuick.Window
import QtMultimedia

Window {
    title: "RHINE MV Desktop"
    visible: false
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus | Qt.WindowTransparentForInput
    color: "#101110"
    VideoOutput {
        id: video
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
        endOfStreamPolicy: VideoOutput.KeepLastFrame
        Component.onCompleted: rhineMv.attachWallpaperVideo(videoSink)
    }
    MvDesktopControls {
        x: rhineMv.desktopControlRect.x
        y: rhineMv.desktopControlRect.y
        transformOrigin: Item.TopLeft
        scale: rhineMv.desktopControlRect.height / 104
        width: scale > 0 ? rhineMv.desktopControlRect.width / scale : 640
        height: 104
    }
    Connections {
        target: rhineMv
        function onVideoCleared() {
            video.clearOutput();
        }
    }
}
