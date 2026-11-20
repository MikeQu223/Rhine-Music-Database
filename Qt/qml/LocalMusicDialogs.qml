import QtQuick
import QtQuick.Dialogs
import QtQuick.Window

// 本地文件选择共享组件
Item {
    id: dialogs
    property var hostWindow: Window.window
    required property var backend
    FolderDialog {
        id: localFolderDialog
        objectName: "localMusicFolderDialog"
        Binding on parentWindow {
            when: Qt.platform.os === "windows"
            value: dialogs.hostWindow
        }
        title: "导入本地音乐文件夹"
        onAccepted: backend.importLocal([selectedFolder])
    }
    FileDialog {
        id: localFileDialog
        objectName: "localMusicFileDialog"
        Binding on parentWindow {
            when: Qt.platform.os === "windows"
            value: dialogs.hostWindow
        }
        title: "导入本地音乐文件"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["音乐文件 (*.mp3 *.flac *.m4a *.mp4 *.aac *.ogg *.opus *.ape *.wav *.aiff *.aif *.wv *.wma *.mpc)"]
        onAccepted: backend.importLocal(selectedFiles)
    }
    Connections {
        target: backend
        function onLocalImportRequested(folder: bool) {
            if (folder) {
                localFolderDialog.open();
            } else {
                localFileDialog.open();
            }
        }
    }
}
