import QtQuick

Item {
    id: panel
    anchors.fill: parent
    property bool expanded: true
    // 收起时告诉 C++ 别再重建详情长文本。收起只把 Flickable 的 visible 关掉，
    // Text 仍然会为新的 text 重新布局——只有真正停掉重建才省得下来。
    onExpandedChanged: profiler.detailsEnabled = expanded
    Component.onCompleted: profiler.detailsEnabled = expanded
    Rectangle {
        id: card
        objectName: "performanceCard"
        visible: profiler.visible
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 12
        width: 366
        height: content.height + 24
        radius: 8
        color: "#ed151b20"
        border.color: "#54616b"
        // 阻止覆盖区域的滚轮和点击穿透到音乐场景。
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: function (wheel) {
                wheel.accepted = true;
            }
        }
        Column {
            id: content
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 9
            Text {
                objectName: "performanceHeadline"
                text: profiler.headline
                color: "#8fe3bb"
                font.pixelSize: 21
                font.bold: true
                // 不再写 `Accessible.name: text`：Text 的可访问名本来就取 text，
                // 显式绑一次只是让每次刷新多触发一遍无障碍更新。
            }
            Flickable {
                visible: panel.expanded
                width: parent.width
                height: Math.min(diagnosticContent.height, Math.max(80, panel.height - 210))
                contentHeight: diagnosticContent.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                Column {
                    id: diagnosticContent
                    width: parent.width
                    spacing: 9
                    Text {
                        objectName: "performanceTransitionDetails"
                        width: parent.width
                        visible: text.length > 0
                        text: profiler.transitionDetails
                        color: "#8fe3bb"
                        font.family: rhineFontFamily
                        font.pixelSize: 12
                        lineHeight: 1.35
                        wrapMode: Text.Wrap
                    }
                    Text {
                        width: parent.width
                        text: profiler.details
                        color: "#e1e6eb"
                        font.family: rhineFontFamily
                        font.pixelSize: 12
                        lineHeight: 1.35
                        wrapMode: Text.Wrap
                    }
                }
            }
            Row {
                spacing: 6
                Rectangle {
                    width: 140
                    height: 30
                    radius: 4
                    color: profiler.recording ? "#9f3830" : "#314f47"
                    Text {
                        anchors.centerIn: parent
                        text: profiler.recordingAction
                        color: "white"
                        font.pixelSize: 12
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: "收集或导出性能诊断"
                    Accessible.onPressAction: profiler.toggleRecording()
                    MouseArea {
                        objectName: "performanceRecordButton"
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: profiler.toggleRecording()
                    }
                }
                Rectangle {
                    width: 82
                    height: 30
                    radius: 4
                    color: "#303b43"
                    Text {
                        anchors.centerIn: parent
                        text: "诊断目录"
                        color: "white"
                        font.pixelSize: 12
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: "打开诊断目录"
                    Accessible.onPressAction: profiler.openReportFolder()
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: profiler.openReportFolder()
                    }
                }
                Rectangle {
                    width: 50
                    height: 30
                    radius: 4
                    color: "#303b43"
                    Text {
                        anchors.centerIn: parent
                        text: panel.expanded ? "精简" : "展开"
                        color: "white"
                        font.pixelSize: 12
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: "展开或精简性能面板"
                    Accessible.onPressAction: panel.expanded = !panel.expanded
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.expanded = !panel.expanded
                    }
                }
                Rectangle {
                    width: 50
                    height: 30
                    radius: 4
                    color: "#303b43"
                    Text {
                        anchors.centerIn: parent
                        text: "关闭"
                        color: "white"
                        font.pixelSize: 12
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: "关闭性能面板"
                    Accessible.onPressAction: profiler.toggleVisible()
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: profiler.toggleVisible()
                    }
                }
            }
        }
    }
}
