import QtQuick
import QtQuick.Window
import Rhine.Native 1.0

// UI 叠加层：HUD、透明输入层、表单、搜索框、窗口边框与性能面板。
// FG 下这一层按显示帧率重新叠加在真实帧和插值帧之上（插值帧只对 3D 有意义），
// 所以它必须与 Scene3D.qml 彻底分离。默认路径下仍由 Main.qml 的 Window 直接承载，
// 层级、坐标与交互保持与拆分前完全一致。
//
// 与原 Main.qml 的差异只有两类，且都不改变行为：
//   1. 原来读 root.stageScale / root.stageWidth / root.height / root.visibility 的地方，
//      改成自身属性或宿主注入（见下面的 stageScale/stageWidth/hostWindow/frameless）。
//   2. 原来被 Main.qml 用 id 直接引用的 inputLayer / accountField / captchaField，
//      现在在组件内部，宿主改为调用 focusInputLayer() / clearCredentials()。
Item {
    id: overlay
    objectName: "overlayRoot"

    // 舞台换算：原来是 Window 上的 root.stageScale 与 root.stageWidth。
    // 默认由 Main.qml 注入；不注入时按自身尺寸回退，这样 FG 宿主只设置尺寸
    // 也能得到同一套舞台坐标。height 为 0 时避免除零（离屏窗口创建到设尺寸之间会短暂为 0）。
    property real stageScale: height > 0 ? height / 1080 : 1
    property real stageWidth: width / stageScale

    // 受控呈现使用原生 QWindow；默认路径由 Main.qml 注入 QML Window。
    readonly property bool controlledHost: typeof rhineHostWindow !== "undefined" && rhineHostWindow !== null
    readonly property bool windows: Qt.platform.os === "windows"
    readonly property bool controlledMetalHost: Qt.platform.os === "osx" && controlledHost
    property Window hostWindow: null
    readonly property var chromeHostWindow: windows && controlledHost ? rhineHostWindow : hostWindow
    property bool frameless: controlledHost && Qt.platform.os === "windows"
    readonly property bool ios: Qt.platform.os === "ios"
    readonly property bool android: Qt.platform.os === "android"

    // 手指比鼠标指针粗：Android 上把每个命中矩形四周各外扩 touchHitPadding 个舞台像素。
    // 舞台坐标按 1080 高归一化，16 在常见手机上约 1~1.5 mm；按手感调这一个值即可。
    // 桌面/iOS 取 0，hitArea() 逐值返回原来的矩形，交互行为完全不变。
    readonly property real touchHitPadding: android ? 16 : 0

    function hitArea(hit) {
        const pad = overlay.touchHitPadding;
        return Qt.rect(hit.x - pad, hit.y - pad, hit.width + 2 * pad, hit.height + 2 * pad);
    }

    // 原 Main.qml 直接引用组件内部的 id，拆层后改为函数调用，效果等价。
    function focusInputLayer() {
        inputLayer.forceActiveFocus();
    }
    // 离屏窗口失去焦点后按当前面板恢复，不能把输入框焦点一律交回快捷键层。
    function restoreInputFocus() {
        if (!windows) {
            focusInputLayer();
            return;
        }
        if (searchInput.visible && searchInput.enabled) {
            searchInput.forceActiveFocus();
        } else if (formFields.visible && accountField.enabled) {
            accountField.forceActiveFocus();
        } else {
            inputLayer.forceActiveFocus();
        }
    }
    function clearCredentials() {
        accountField.text = "";
        captchaField.text = "";
    }

    Connections {
        target: rhine
        function onClearCredentials() {
            overlay.clearCredentials();
        }
    }
    Loader {
        active: overlay.windows ? overlay.controlledHost : overlay.controlledMetalHost
        sourceComponent: LocalMusicDialogs {
            hostWindow: overlay.windows ? overlay.chromeHostWindow : Window.window
            backend: rhine
        }
    }
    Hud {
        anchors.fill: parent
        engine: rhine
    }
    // 透明 QML 输入层使用原舞台坐标；可见画面由同一份字形和材质绘制。
    MouseArea {
        id: inputLayer
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        focus: true
        onPressed: function (mouse) {
            forceActiveFocus();
            rhine.pointer("pointerdown", mouse.x / overlay.stageScale, mouse.y / overlay.stageScale);
        }
        onPositionChanged: function (mouse) {
            rhine.pointer("pointermove", mouse.x / overlay.stageScale, mouse.y / overlay.stageScale);
        }
        onReleased: function (mouse) {
            rhine.pointer("pointerup", mouse.x / overlay.stageScale, mouse.y / overlay.stageScale);
        }
        onExited: rhine.pointer("pointerleave", 0, 0)
        onCanceled: rhine.pointer("pointercancel", 0, 0)
        onWheel: function (wheel) {
            rhine.wheelInput(wheel.x / overlay.stageScale, wheel.y / overlay.stageScale, wheel.pixelDelta.y, wheel.angleDelta.y);
            wheel.accepted = true;
        }
        Keys.onPressed: function (event) {
            event.accepted = rhine.keyEvent(event.key, event.modifiers, event.text);
        }
    }
    // 阻止事件进入资料库
    MouseArea {
        objectName: "playerBarInputShield"
        property var region: rhine.state.playerBounds
        visible: !!region
        x: region ? region.x * overlay.stageScale : 0
        y: region ? region.y * overlay.stageScale : 0
        width: region ? region.width * overlay.stageScale : 0
        height: region ? region.height * overlay.stageScale : 0
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        cursorShape: Qt.ArrowCursor
        onEntered: {
            rhine.pointer("pointercancel", 0, 0);
            rhine.pointer("pointerleave", 0, 0);
        }
        onPressed: inputLayer.forceActiveFocus()
        onWheel: function (wheel) {
            wheel.accepted = true;
        }
    }
    // ── 键盘快捷键（原来放在 Main.qml 的 Window 里，两条路径现在共用这一份） ──
    //
    // 为什么 context 要跟着宿主变：
    //   · 默认路径有真实 QQuickWindow，Qt.WindowShortcut 与拆分前语义完全一致；
    //   · FG 路径的离屏 QQuickRenderControl 窗口没有平台窗口、永远不会被激活
    //     （实测 window.isActive() 恒为 false，requestActivate() 也无效），Qt 的
    //     快捷键地图(QShortcutMap)就匹配不到 WindowShortcut。此时必须显式声明
    //     Qt.ApplicationShortcut（"任一应用窗口激活即生效"，而真实按键本来就只能
    //     由有焦点的 FgShell 窗口收到）。
    //
    // 另一条重要的实测结论：QML Shortcut 只在"平台事件路径"里被处理
    // （QGuiApplicationPrivate::processKeyEvent → shortcutMap.tryShortcut）。
    // FgShell::eventFilter() 里那种 QCoreApplication::sendEvent(离屏窗口, key) 的
    // 直接投递完全不经过快捷键地图，任何 context 都不会触发——所以 FG 的快捷键
    // 绝不能靠"转发事件"实现，只能靠这里的 context 声明。
    readonly property int shortcutContext: {
        if (windows) {
            return controlledHost ? Qt.ApplicationShortcut : Qt.WindowShortcut;
        }
        return hostWindow === null ? Qt.ApplicationShortcut : Qt.WindowShortcut;
    }
    Shortcut {
        sequences: [StandardKey.Quit]
        context: overlay.shortcutContext
        onActivated: Qt.quit()
    }
    Shortcut {
        sequences: Qt.platform.os === "osx" ? [StandardKey.FullScreen, "F11"] : ["F11"]
        context: overlay.shortcutContext
        onActivated: rhine.toggleFullscreen()
    }
    Shortcut {
        sequence: "F10"
        context: overlay.shortcutContext
        onActivated: profiler.toggleVisible()
    }
    Item {
        id: controls
        width: overlay.stageWidth
        height: 1080
        scale: overlay.stageScale
        transformOrigin: Item.TopLeft
        Repeater {
            model: rhine.hits
            delegate: Item {
                required property var modelData
                property rect area: overlay.hitArea(modelData)
                x: area.x
                y: area.y + (rhine.state.modal && !modelData.fixed ? rhine.state.modalOffset || 0 : 0)
                width: area.width
                height: area.height
                Accessible.role: Accessible.Button
                Accessible.name: modelData.label
                Accessible.onPressAction: rhine.action(modelData.action)
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: rhine.pointer("pointerleave", 0, 0)
                    onPressed: {
                        inputLayer.forceActiveFocus();
                        if (!overlay.ios) {
                            rhine.action(modelData.action);
                        }
                    }
                    onClicked: {
                        if (overlay.ios) {
                            rhine.action(modelData.action);
                        }
                    }
                    onWheel: function (wheel) {
                        var p = mapToItem(inputLayer, wheel.x, wheel.y);
                        rhine.wheelInput(p.x / overlay.stageScale, p.y / overlay.stageScale, wheel.pixelDelta.y, wheel.angleDelta.y);
                        wheel.accepted = true;
                    }
                }
            }
        }
        // 检索与个人库
        MouseArea {
            id: searchScrollArea
            visible: rhine.state.modal === "search" || rhine.state.modal === "saved"
            enabled: visible
            x: rhine.state.searchListX || 0
            y: (rhine.state.searchListY || 0) + (rhine.state.modalOffset || 0)
            width: rhine.state.searchListWidth || 0
            height: rhine.state.searchListHeight || 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            property real dragOriginY: 0
            property real lastDragY: 0
            property bool dragged: false
            onEntered: rhine.pointer("pointerleave", 0, 0)
            onPressed: {
                if (rhine.state.closing) {
                    return;
                }
                dragOriginY = mouse.y;
                lastDragY = mouse.y;
                dragged = false;
            }
            onPositionChanged: function (mouse) {
                if (!pressed || rhine.state.closing) {
                    return;
                }
                if (Math.abs(mouse.y - dragOriginY) > 6) {
                    dragged = true;
                }
                if (dragged) {
                    // 拖拽距离先换算成窗口像素，再沿用手势层的滚轮换算。
                    var p = mapToItem(inputLayer, mouse.x, mouse.y);
                    var previous = mapToItem(inputLayer, mouse.x, lastDragY);
                    var delta = p.y - previous.y;
                    if (delta !== 0) {
                        rhine.wheelInput(p.x / overlay.stageScale, p.y / overlay.stageScale, delta, 0);
                        lastDragY = mouse.y;
                    }
                }
            }
            onReleased: {
                if (rhine.state.closing || dragged) {
                    return;
                }
                var px = (rhine.state.searchListX || 0) + mouse.x;
                var py = (rhine.state.searchListY || 0) + mouse.y;
                for (var index = 0; index < rhine.hits.length; ++index) {
                    var hit = rhine.hits[index];
                    var area = overlay.hitArea(hit);
                    var inside = px >= area.x && px <= area.x + area.width && py >= area.y && py <= area.y + area.height;
                    var scrollable = hit.action.indexOf("music:result:") === 0 || hit.action.indexOf("music:expand:") === 0;
                    if (inside && scrollable) {
                        rhine.action(hit.action);
                        break;
                    }
                }
            }
            onWheel: function (wheel) {
                var p = mapToItem(inputLayer, wheel.x, wheel.y);
                rhine.wheelInput(p.x / overlay.stageScale, p.y / overlay.stageScale, wheel.pixelDelta.y, wheel.angleDelta.y);
                wheel.accepted = true;
            }
        }
    }
    TouchInput {
        stage: overlay
        backend: rhine
    }
    // 验证码只在输入组件和单次登录请求中短暂存在，提交后立即清空。
    Item {
        id: formFields
        visible: rhine.state.modal === "playlist-form" || (rhine.state.modal === "login" && rhine.state.loginMethod === "phone")
        x: (rhine.state.inputX || 0) * overlay.stageScale
        y: (rhine.state.modalOffset || 0) * overlay.stageScale
        width: (rhine.state.inputWidth || 0) * overlay.stageScale
        height: overlay.height
        opacity: rhine.state.modalOpacity || 0
        onVisibleChanged: {
            accountField.text = "";
            captchaField.text = "";
            if (visible) {
                accountField.forceActiveFocus();
            }
        }
        function submit() {
            if (rhine.state.modal === "login" && rhine.state.loginBusy) {
                return;
            }
            rhine.submitForm(accountField.text, captchaField.text);
            captchaField.text = "";
        }
        Rectangle {
            x: 0
            y: 430 * overlay.stageScale
            width: rhine.state.modal === "login" ? parent.width - 180 * overlay.stageScale : parent.width
            height: 55 * overlay.stageScale
            color: rhine.state.dark ? "#30312b" : "#d9d8ce"
        }
        TextInput {
            id: accountField
            objectName: "accountField"
            x: 14 * overlay.stageScale
            y: 430 * overlay.stageScale
            width: parent.width - (rhine.state.modal === "login" ? 208 : 28) * overlay.stageScale
            height: 55 * overlay.stageScale
            verticalAlignment: TextInput.AlignVCenter
            color: rhine.state.dark ? "#eeeeeb" : "#161914"
            font.pixelSize: 19 * overlay.stageScale
            cursorVisible: activeFocus && !rhine.performance.idle
            maximumLength: rhine.state.modal === "login" ? 11 : 100
            enabled: rhine.state.modal !== "login" || !rhine.state.loginBusy
            inputMethodHints: rhine.state.modal === "login" ? Qt.ImhDigitsOnly : Qt.ImhNone
            Accessible.name: rhine.state.modal === "playlist-form" ? "歌单名称" : "手机号码"
            Keys.onReturnPressed: {
                if (rhine.state.modal !== "login") {
                    formFields.submit();
                } else {
                    captchaField.forceActiveFocus();
                }
            }
            Keys.onEscapePressed: rhine.action("close-modal")
        }
        Rectangle {
            visible: rhine.state.modal === "login"
            x: parent.width - width
            y: 430 * overlay.stageScale
            width: 170 * overlay.stageScale
            height: 55 * overlay.stageScale
            enabled: !rhine.state.loginBusy && rhine.state.smsRetrySeconds === 0 && accountField.text.length === 11
            color: "#777b60"
            opacity: enabled ? 1 : 0.5
            Text {
                anchors.centerIn: parent
                text: rhine.state.smsRetrySeconds > 0 ? rhine.state.smsRetrySeconds + " 秒后重发" : "发送验证码"
                color: "#f0eee5"
                font.pixelSize: 14 * overlay.stageScale
            }
            Accessible.role: Accessible.Button
            Accessible.name: "发送短信验证码"
            Accessible.onPressAction: {
                if (enabled) {
                    rhine.sendLoginCode(accountField.text);
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: rhine.sendLoginCode(accountField.text)
            }
        }
        Rectangle {
            visible: rhine.state.modal === "login"
            x: 0
            y: 541 * overlay.stageScale
            width: parent.width
            height: 55 * overlay.stageScale
            color: rhine.state.dark ? "#30312b" : "#d9d8ce"
        }
        TextInput {
            id: captchaField
            objectName: "captchaField"
            visible: rhine.state.modal === "login"
            x: 14 * overlay.stageScale
            y: 541 * overlay.stageScale
            width: parent.width - 28 * overlay.stageScale
            height: 55 * overlay.stageScale
            verticalAlignment: TextInput.AlignVCenter
            color: rhine.state.dark ? "#eeeeeb" : "#161914"
            font.pixelSize: 19 * overlay.stageScale
            cursorVisible: activeFocus && !rhine.performance.idle
            maximumLength: 8
            enabled: !rhine.state.loginBusy
            inputMethodHints: Qt.ImhDigitsOnly | Qt.ImhSensitiveData
            Accessible.name: "短信验证码"
            Keys.onReturnPressed: formFields.submit()
            Keys.onEscapePressed: rhine.action("close-modal")
        }
        Rectangle {
            x: parent.width - width
            y: (rhine.state.modal === "login" ? 611 : 530) * overlay.stageScale
            enabled: rhine.state.modal !== "login" || !rhine.state.loginBusy
            width: 170 * overlay.stageScale
            height: 36 * overlay.stageScale
            color: "#777b60"
            opacity: enabled ? 1 : 0.5
            Text {
                anchors.centerIn: parent
                text: rhine.state.modal === "login" ? "登录 →" : "保存 →"
                color: "#f0eee5"
                font.pixelSize: 14 * overlay.stageScale
            }
            Accessible.role: Accessible.Button
            Accessible.name: "提交表单"
            Accessible.onPressAction: formFields.submit()
            MouseArea {
                anchors.fill: parent
                onClicked: formFields.submit()
            }
        }
    }
    Repeater {
        model: overlay.ios ? ["seek"] : ["seek", "volume"]
        delegate: MouseArea {
            required property string modelData
            property var region: rhine.state[modelData]
            visible: !!region
            enabled: visible && !rhine.state.closing
            x: region ? region.x * overlay.stageScale : 0
            // 播放栏固定在窗口下沿，不随弹窗入场偏移。竖向多留一点触摸余量；
            // 横向保持原样，否则 adjustPlayer 用 mouse.x/width 算出的比例会偏。
            y: region ? (region.y - overlay.touchHitPadding) * overlay.stageScale : 0
            width: region ? region.width * overlay.stageScale : 0
            height: region ? (region.height + 2 * overlay.touchHitPadding) * overlay.stageScale : 0
            cursorShape: Qt.PointingHandCursor
            onPressed: function (mouse) {
                rhine.adjustPlayer(modelData, mouse.x, width);
            }
            onPositionChanged: function (mouse) {
                if (pressed) {
                    rhine.adjustPlayer(modelData, mouse.x, width);
                }
            }
        }
    }
    Rectangle {
        visible: searchInput.visible
        x: searchInput.x
        y: searchInput.y
        width: searchInput.width
        height: searchInput.height
        color: rhine.state.dark ? "#ffffff" : "#141613"
        // 检索条背景由原生面板绘制；其他弹窗仍使用原来的轻遮罩。
        opacity: (rhine.state.modal === "search" || rhine.state.modal === "saved") ? 0 : (rhine.state.modalOpacity || 0) * 0.045
    }
    TextInput {
        id: searchInput
        objectName: "musicSearchInput"
        verticalAlignment: TextInput.AlignVCenter
        leftPadding: 18 * overlay.stageScale
        rightPadding: 14 * overlay.stageScale
        renderType: Text.NativeRendering
        visible: rhine.state.modal === "search" || rhine.state.modal === "saved"
        enabled: !rhine.state.closing
        x: (rhine.state.inputX || 0) * overlay.stageScale
        y: ((rhine.state.inputY || 302) + (rhine.state.modalOffset || 0)) * overlay.stageScale
        width: (rhine.state.inputWidth || 0) * overlay.stageScale
        height: 54 * overlay.stageScale
        font.family: rhineFontFamily
        font.pixelSize: 22 * overlay.stageScale
        color: (rhine.state.modal === "search" || rhine.state.modal === "saved") ? (rhine.state.dark ? "#e9e7da" : "#222a25") : (rhine.state.dark ? "#ebebeb" : "#141613")
        opacity: rhine.state.modalOpacity || 0
        clip: true
        cursorVisible: activeFocus && !rhine.performance.idle
        selectByMouse: true
        Accessible.name: rhine.state.localMusic ? "检索本地歌曲、歌手、专辑或文件夹" : "搜索歌曲、歌手、专辑或歌单"
        onTextEdited: rhine.query(text)
        onVisibleChanged: {
            if (visible) {
                text = rhine.state.query || "";
                forceActiveFocus();
            } else {
                inputLayer.forceActiveFocus();
            }
        }
        Keys.onEscapePressed: rhine.action("close-modal")
        Keys.onReturnPressed: function (event) {
            rhine.searchAccepted(text, event.modifiers);
        }
        Text {
            anchors.fill: parent
            visible: searchInput.text.length === 0 && !searchInput.preeditText
            text: rhine.state.localMusic ? "检索本地歌曲、歌手、专辑或文件夹" : "搜索歌曲、歌手、专辑或歌单"
            font: searchInput.font
            leftPadding: searchInput.leftPadding
            verticalAlignment: Text.AlignVCenter
            color: (rhine.state.modal === "search" || rhine.state.modal === "saved") ? (rhine.state.dark ? "#a2aa9d" : "#626b60") : "#777777"
        }
    }
    // 通用设置文本输入：位置由 Schema 行控制区提供，原生面板只负责背景与命中。
    Rectangle {
        id: settingEditBackground
        visible: rhine.state.editingSetting === true
        x: (rhine.state.editingSettingX || 0) * overlay.stageScale
        y: ((rhine.state.editingSettingY || 0) + (rhine.state.modalOffset || 0)) * overlay.stageScale
        width: (rhine.state.editingSettingWidth || 0) * overlay.stageScale
        height: (rhine.state.editingSettingHeight || 0) * overlay.stageScale
        color: rhine.state.dark ? "#2b332c" : "#e5e7da"
        border.width: 1 * overlay.stageScale
        border.color: rhine.state.dark ? "#4a554b" : "#aab0a0"
    }
    TextInput {
        id: settingEditInput
        objectName: "musicSettingEditInput"
        visible: rhine.state.editingSetting === true
        x: settingEditBackground.x + 12 * overlay.stageScale
        y: settingEditBackground.y
        width: Math.max(0, settingEditBackground.width - 24 * overlay.stageScale)
        height: settingEditBackground.height
        verticalAlignment: TextInput.AlignVCenter
        font.family: rhineFontFamily
        font.pixelSize: 16 * overlay.stageScale
        color: rhine.state.dark ? "#e9e7da" : "#222a25"
        clip: true
        selectByMouse: true
        cursorVisible: activeFocus && !rhine.performance.idle
        Accessible.name: "设置文本"
        onTextEdited: rhine.settingEditText(text)
        onVisibleChanged: {
            if (visible) {
                text = rhine.state.editingSettingValue || "";
                forceActiveFocus();
            } else {
                inputLayer.forceActiveFocus();
            }
        }
        Keys.onReturnPressed: rhine.settingEditAccepted()
        Keys.onEscapePressed: rhine.settingEditCancel()
    }
    // 两条呈现路径共用真实宿主的窗口按钮、拖动与边缘缩放。
    Loader {
        id: chromeLoader
        anchors.fill: parent
        z: 999
        active: overlay.chromeHostWindow !== null
        sourceComponent: WindowChrome {
            window: overlay.hostWindow
            nativeWindow: overlay.windows ? overlay.chromeHostWindow : null
            onMinimizeRequested: rhine.minimizeWindow()
            enabled: overlay.frameless
            visible: enabled && overlay.chromeHostWindow.visibility !== Window.FullScreen
            dark: rhine.state.dark === true
        }
    }
    PerformancePanel {
        z: 1000
    }
}
