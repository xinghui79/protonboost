// ProtonBoost 管理器 —— 界面
// 版式参考 macOS 设置：侧栏（前缀 + 视图）+ 大标题 + 分组列表 + 右侧检查器
// 修改本文件后直接 cargo build 即可，build.rs 会保证重新链接
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import ProtonBoost

ApplicationWindow {
    id: root

    // ── 设计变量 ────────────────────────────────────────────
    // 主色是墨：主按钮、标题都用它；暖琥珀只在焦点、运行中这类地方点一下。
    readonly property QtObject c: QtObject {
        readonly property bool dark: Qt.styleHints.colorScheme === Qt.Dark
        readonly property color ink: dark ? "#f4f4f6" : "#16181c"
        readonly property color inkText: dark ? "#17181a" : "#ffffff"
        readonly property color accent: dark ? "#f0ae56" : "#b86a15"
        readonly property color accentSoft: dark ? "#2b2419" : "#fbf0df"
        readonly property color window: dark ? "#131417" : "#fdfdfd"
        readonly property color sidebar: dark ? "#0f1012" : "#f3f3f5"
        readonly property color row: dark ? "#1a1b1e" : "#ffffff"
        readonly property color group: dark ? "#191a1d" : "#f7f7f8"
        readonly property color rowHover: dark ? "#212226" : "#f5f5f7"
        readonly property color rowActive: dark ? "#26282c" : "#ececee"
        readonly property color line: dark ? "#2a2c30" : "#e5e5e8"
        readonly property color field: dark ? "#1e2023" : "#ffffff"
        readonly property color fieldLine: dark ? "#33363b" : "#d8d9dd"
        readonly property color text: dark ? "#f3f4f6" : "#16181c"
        readonly property color dim: dark ? "#a1a5ac" : "#6a6e75"
        readonly property color faint: dark ? "#6d7178" : "#9aa0a6"
        readonly property color danger: dark ? "#ff6961" : "#c7362f"
        readonly property color hover: dark ? "#14ffffff" : "#0d000000"
        readonly property color press: dark ? "#24ffffff" : "#1a000000"
    }

    readonly property bool zh: backend.zh
    readonly property bool configureMode: backend.startup_exe() !== ""

    // ── 文案 ────────────────────────────────────────────────
    readonly property string appName: "ProtonBoost"
    readonly property string version: "v" + Qt.application.version
    readonly property var pageNames: [zh ? "应用" : "Apps", zh ? "Linux 程序" : "Linux Apps",
                                      zh ? "进程" : "Processes"]
    readonly property var pageKeys: ["apps", "linux", "procs"]
    readonly property var pageTitles: [
        zh ? "应用" : "Applications",
        zh ? "Linux 程序" : "Linux Apps",
        zh ? "正在运行的进程" : "Running Processes"
    ]
    readonly property var pageSubtitles: [
        zh ? "前缀里登记过的 Windows 程序，可以运行、改设置、看日志。" : "Windows programs registered in this prefix.",
        zh ? "把 Linux 原生程序放进同一个前缀与网络里启动。" : "Start native Linux programs inside the same prefix.",
        zh ? "这个前缀里的 Windows 进程，卡死时强制结束。" : "Windows processes of this prefix."
    ]
    readonly property var searchHints: [
        zh ? "搜索应用" : "Search apps",
        zh ? "搜索程序" : "Search apps",
        zh ? "搜索进程名、PID 或命令行" : "Search name, PID or command"
    ]

    // ── 状态 ────────────────────────────────────────────────
    property int currentPage: 0
    property string appsPrefix: ""
    property string linuxPrefix: ""
    property string procsPrefix: ""
    property var runnersModel: []
    property var resolutionsModel: []
    property var fpsModel: []
    property var editEntry: ({})
    property var pendingConfirm: null
    property string exesTitle: ""
    property string renameTarget: ""
    property string currentLogAppId: ""
    property string logTitle: ""
    property var searchValues: ["", "", ""]
    /// 自增一次 = 请求当前页把焦点交给搜索框（组件内部 id 外面看不见，只能这样通知）
    property int searchFocusTick: 0

    /// 侧栏前缀组：应用/Linux 用前缀列表，进程页用「前缀 · 游戏」的进程分组
    readonly property var sidebarPrefixes: {
        var source = currentPage === 2 ? backend.processPrefixes : backend.prefixes
        var out = []
        for (var i = 0; i < source.length; i++) out.push(source[i])
        return out
    }
    readonly property bool anyPopup: configDialog.visible || confirmPopup.visible
        || renamePopup.visible || logPopup.visible || exesPopup.visible || dirsPopup.visible

    visible: true
    width: configureMode ? 640 : 1180
    height: 780
    minimumWidth: configureMode ? 580 : 980
    minimumHeight: configureMode ? 640 : 620
    color: c.window
    flags: Qt.Window | Qt.FramelessWindowHint
    title: configureMode ? (zh ? "运行设置" : "Run Settings") : appName + " · " + pageTitles[currentPage]

    Backend {
        id: backend
        onPrefixesChanged: {
            var paths = []
            for (var i = 0; i < backend.prefixes.length; i++) paths.push(backend.prefixes[i].path)
            if (paths.indexOf(appsPrefix) < 0) appsPrefix = paths.length ? paths[0] : ""
            if (paths.indexOf(linuxPrefix) < 0) linuxPrefix = appsPrefix
        }
        onProcessPrefixesChanged: {
            var paths = []
            for (var i = 0; i < backend.processPrefixes.length; i++) paths.push(backend.processPrefixes[i].path)
            if (paths.indexOf(procsPrefix) < 0) procsPrefix = paths.length ? paths[0] : ""
        }
        onUiEventsChanged: {
            var events = backend.uiEvents
            if (!events || events === "") return
            backend.clear_ui_events()
            var names = events.split(",")
            for (var i = 0; i < names.length; i++) {
                if (names[i] === "toggle") {
                    if (configureMode) {
                        root.show(); root.raise()
                    } else if (root.visible) {
                        root.hide()
                    } else {
                        root.show(); root.raise(); refreshCurrent()
                    }
                } else if (names[i] === "config") {
                    editEntry = backend.config_entry
                    runnersModel = backend.config_runners
                    resolutionsModel = backend.config_resolutions
                    fpsModel = backend.config_fps
                    configDialog.openFor(backend.config_entry)
                } else if (names[i] === "exes") {
                    exesTitle = backend.exes_title
                    exesList.model = backend.exes_items
                    exesPopup.open()
                }
            }
        }
    }

    Timer {
        interval: 250
        running: true
        repeat: true
        onTriggered: backend.poll()
    }

    Component.onCompleted: {
        if (configureMode) {
            backend.configure_exe(backend.startup_exe())
        } else {
            backend.reload_prefixes()
            var initial = backend.initial_page()
            for (var i = 0; i < root.pageKeys.length; i++) {
                if (root.pageKeys[i] === initial) root.currentPage = i
            }
            Qt.callLater(refreshCurrent)
            backend.check_updates()
        }
    }

    Shortcut { sequence: "Ctrl+F"; onActivated: root.searchFocusTick++ }
    Shortcut { sequence: "Ctrl+R"; onActivated: root.refreshCurrent() }
    Shortcut { sequence: "Ctrl+Q"; onActivated: backend.quit_app() }
    Shortcut { sequence: "Ctrl+W"; onActivated: root.closeWindow() }
    Shortcut { sequence: "Ctrl+1"; onActivated: root.switchPage(0) }
    Shortcut { sequence: "Ctrl+2"; onActivated: root.switchPage(1) }
    Shortcut { sequence: "Ctrl+3"; onActivated: root.switchPage(2) }
    Shortcut {
        sequence: "Esc"
        enabled: !root.configureMode && !root.anyPopup
        onActivated: {
            // 第一次按清搜索，再按一次收起检查器
            if (root.searchValues[root.currentPage] !== "") root.clearSearch()
            else if (root.currentPage === 0) appsPage.clearSelection()
        }
    }

    function switchPage(index) {
        if (configureMode) return
        currentPage = index
        refreshCurrent()
    }

    function currentPrefix() {
        return currentPage === 0 ? appsPrefix : currentPage === 1 ? linuxPrefix : procsPrefix
    }

    function setPrefix(value) {
        if (currentPage === 0) appsPrefix = value
        else if (currentPage === 1) linuxPrefix = value
        else procsPrefix = value
    }

    function refreshCurrent() {
        backend.refresh_page(pageKeys[currentPage], currentPrefix())
    }

    function clearSearch() {
        var copy = searchValues.slice()
        copy[currentPage] = ""
        searchValues = copy
    }

    function confirm(title, message, action) {
        pendingConfirm = action
        confirmTitle.text = title
        confirmMessage.text = message
        confirmPopup.open()
    }

    function prefixLabel(path) {
        if (!path) return zh ? "没有前缀" : "No prefix"
        var pieces = path.replace(/\/+$/, "").split("/")
        return pieces[pieces.length - 1] || path
    }

    function prefixItemLabel(item) {
        if (!item) return ""
        var raw = item.label ? item.label : item.path
        // 进程组的 label 有时是「游戏名 · /path」，只有纯路径才缩成目录名
        if (raw.charAt(0) !== "/") return raw
        var name = prefixLabel(raw)
        // 两个不同位置的前缀可能同名（比如都叫 proton），撞名时带上上一级
        var list = sidebarPrefixes
        var same = 0
        for (var i = 0; i < list.length; i++) {
            var other = list[i].label ? list[i].label : list[i].path
            if (prefixLabel(other) === name) same++
        }
        if (same < 2) return name
        var parts = raw.replace(/\/+$/, "").split("/")
        return parts.length > 1 ? parts[parts.length - 2] + "/" + name : name
    }

    function shortPath(path) {
        if (!path) return "—"
        var parts = path.replace(/\/+$/, "").split("/")
        if (parts.length < 2) return path
        return parts[parts.length - 2] + "/" + parts[parts.length - 1]
    }

    function kindLabel(item) {
        if (!item) return "—"
        if (item.isSteam) return "Steam"
        if (item.kind === "shortcut") return zh ? "快捷方式" : "Shortcut"
        if (item.kind === "saved-config") return zh ? "已配置" : "Configured"
        return item.kind
    }

    function pageSummary() {
        if (currentPage === 0) {
            var running = 0
            for (var i = 0; i < backend.apps.length; i++) if (backend.apps[i].running) running++
            return backend.apps.length + (zh ? " 个应用" : " apps")
                 + (running > 0 ? (zh ? " · " + running + " 个运行中" : " · " + running + " running") : "")
        }
        if (currentPage === 1) return backend.linux_apps.length + (zh ? " 个程序" : " apps")
        return backend.procs.length + (zh ? " 个进程" : " processes")
    }

    // ── 基础控件 ────────────────────────────────────────────
    component WButton: Button {
        id: wb
        implicitHeight: 30
        padding: 12
        hoverEnabled: true
        background: Rectangle {
            radius: 7
            color: wb.pressed ? c.press : (wb.hovered ? c.hover : "transparent")
            border.width: wb.outlined ? 1 : 0
            border.color: c.fieldLine
        }
        contentItem: Text {
            text: wb.text
            font.pixelSize: 13
            color: wb.enabled ? c.text : c.faint
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        /// 描边样式（默认是纯文字按钮）
        property bool outlined: false
    }

    component WAccentButton: Button {
        id: wab
        implicitHeight: 30
        padding: 14
        background: Rectangle {
            radius: 7
            color: !wab.enabled ? c.line : (wab.pressed || wab.hovered ? Qt.lighter(c.ink, c.dark ? 0.92 : 1.6) : c.ink)
        }
        contentItem: Text {
            text: wab.text
            font.pixelSize: 13
            font.weight: Font.Medium
            color: c.inkText
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    /// 实心按钮 + 下拉箭头（箭头是画出来的，避免 ⌄ 在不同字体里忽高忽低）
    component WMenuButton: Button {
        id: menuBtn
        implicitHeight: 30
        leftPadding: 14
        rightPadding: 12
        background: Rectangle {
            radius: 7
            color: !menuBtn.enabled ? c.line
                 : (menuBtn.pressed || menuBtn.hovered ? Qt.lighter(c.ink, c.dark ? 0.92 : 1.6) : c.ink)
        }
        contentItem: RowLayout {
            spacing: 7
            Text {
                Layout.alignment: Qt.AlignVCenter
                text: menuBtn.text
                font.pixelSize: 13
                font.weight: Font.Medium
                color: c.inkText
            }
            Item {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 9
                implicitHeight: 6
                Canvas {
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = c.inkText
                        ctx.lineWidth = 1.5
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"
                        ctx.beginPath()
                        ctx.moveTo(0.75, 1)
                        ctx.lineTo(4.5, 4.6)
                        ctx.lineTo(8.25, 1)
                        ctx.stroke()
                    }
                }
            }
        }
    }

    component WDangerButton: Button {
        id: wdb
        implicitHeight: 30
        padding: 12
        background: Rectangle {
            radius: 7
            color: wdb.hovered || wdb.pressed ? c.danger : "transparent"
        }
        contentItem: Text {
            text: wdb.text
            font.pixelSize: 13
            color: wdb.hovered || wdb.pressed ? "#ffffff" : c.danger
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component WIconButton: Button {
        id: wib
        property string glyph: "⋯"
        property int glyphSize: 14
        implicitWidth: 30
        implicitHeight: 30
        background: Rectangle {
            radius: 7
            color: wib.pressed ? c.press : (wib.hovered ? c.hover : "transparent")
        }
        contentItem: Text {
            text: wib.glyph
            font.pixelSize: wib.glyphSize
            color: c.dim
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        ToolTip.visible: hovered && ToolTip.text !== ""
        ToolTip.delay: 500
    }

    component WField: TextField {
        id: wf
        implicitHeight: 34
        opacity: enabled ? 1 : 0.5
        leftPadding: 11
        rightPadding: 11
        color: c.text
        placeholderTextColor: c.faint
        font.pixelSize: 13
        selectByMouse: true
        selectionColor: c.accent
        background: Rectangle {
            radius: 8
            color: c.field
            border.width: 1
            border.color: wf.activeFocus ? c.accent : c.fieldLine
        }
    }

    // 只读的路径展示：点一下就去选文件/目录
    component WPathField: AbstractButton {
        id: pathField
        property string value: ""
        implicitHeight: 32
        background: Rectangle {
            radius: 7
            color: c.field
            border.width: 1
            border.color: pathField.hovered ? c.fieldLine : c.line
        }
        contentItem: Text {
            leftPadding: 10
            rightPadding: 8
            text: pathField.value
            color: c.text
            font.pixelSize: 12
            elide: Text.ElideMiddle
            verticalAlignment: Text.AlignVCenter
        }
        ToolTip.visible: hovered
        ToolTip.delay: 600
        ToolTip.text: pathField.value
    }

    component WSearchField: TextField {
        id: ws
        implicitHeight: 34
        leftPadding: 32
        rightPadding: 11
        color: c.text
        placeholderTextColor: c.faint
        font.pixelSize: 13
        selectByMouse: true
        selectionColor: c.accent
        background: Rectangle {
            radius: 8
            color: c.field
            border.width: 1
            border.color: ws.activeFocus ? c.accent : c.fieldLine
            Text {
                x: 11
                anchors.verticalCenter: parent.verticalCenter
                text: "⌕"
                font.pixelSize: 15
                color: c.faint
            }
        }
    }

    component WComboBox: ComboBox {
        id: wcb
        implicitHeight: 34
        font.pixelSize: 13
        editable: true
        opacity: enabled ? 1 : 0.5
        background: Rectangle {
            radius: 8
            color: c.field
            border.width: 1
            border.color: wcb.activeFocus ? c.accent : c.fieldLine
        }
        contentItem: TextInput {
            text: wcb.editText
            font.pixelSize: 13
            color: c.text
            selectionColor: c.accent
            verticalAlignment: Text.AlignVCenter
            leftPadding: 11
            rightPadding: wcb.indicator.width + 8
            selectByMouse: true
            onTextEdited: wcb.editText = text
            onAccepted: wcb.activate()
        }
        indicator: Canvas {
            x: wcb.width - width - 11
            y: (wcb.height - height) / 2
            width: 9
            height: 5
            onPaint: {
                var ctx = getContext("2d")
                ctx.strokeStyle = c.faint
                ctx.lineWidth = 1.5
                ctx.beginPath()
                ctx.moveTo(0, 0)
                ctx.lineTo(4.5, 4.5)
                ctx.lineTo(9, 0)
                ctx.stroke()
            }
        }
        delegate: ItemDelegate {
            id: wcbItem
            required property var modelData
            required property int index
            width: wcb.width - 8
            height: 32
            contentItem: Text {
                leftPadding: 8
                text: wcb.textRole !== "" && wcbItem.modelData ? wcbItem.modelData[wcb.textRole] : wcbItem.modelData
                color: wcbItem.highlighted ? "#ffffff" : c.text
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideMiddle
            }
            highlighted: wcb.highlightedIndex === wcbItem.index
            background: Rectangle {
                radius: 6
                color: wcbItem.highlighted ? c.accent : "transparent"
            }
        }
        popup: Popup {
            y: wcb.height + 6
            x: 0
            width: wcb.width
            padding: 4
            background: Rectangle {
                radius: 10
                color: c.row
                border.width: 1
                border.color: c.line
            }
            contentItem: ListView {
                clip: true
                implicitHeight: Math.min(contentHeight, 300)
                model: wcb.popup.visible ? wcb.delegateModel : null
                currentIndex: wcb.highlightedIndex
            }
        }
        function activate() {
            if (typeof currentValue !== "undefined" && currentValue !== null) activated(currentIndex)
        }
    }

    component WCheckBox: CheckBox {
        id: wcbx
        implicitHeight: 26
        spacing: 9
        indicator: Rectangle {
            implicitWidth: 18
            implicitHeight: 18
            x: wcbx.leftPadding
            y: (wcbx.height - height) / 2
            radius: 5
            color: wcbx.checked ? (wcbx.enabled ? c.accent : c.faint) : "transparent"
            border.width: 1
            border.color: wcbx.checked ? (wcbx.enabled ? c.accent : c.faint) : c.fieldLine
            Text {
                anchors.centerIn: parent
                visible: wcbx.checked
                text: "✓"
                color: "#ffffff"
                font.pixelSize: 11
                font.bold: true
            }
        }
        contentItem: Text {
            text: wcbx.text
            leftPadding: wcbx.indicator.width + wcbx.spacing
            font.pixelSize: 13
            color: wcbx.enabled ? c.text : c.faint
            verticalAlignment: Text.AlignVCenter
        }
    }

    // 菜单项样式统一（弹层里的下拉都用它）
    component WMenuItem: MenuItem {
        id: wmi
        height: 32
        contentItem: Text {
            leftPadding: 8
            text: wmi.text
            color: wmi.highlighted ? "#ffffff" : c.text
            font.pixelSize: 13
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 6
            color: wmi.highlighted ? c.accent : "transparent"
        }
    }

    // ── 标题栏：左边红绿灯，中间窗口名，右边 Windows 式按钮 ──
    header: Rectangle {
        height: 48
        color: root.configureMode ? c.window : c.sidebar

        MouseArea {
            anchors.fill: parent
            onPressed: root.startSystemMove()
            onDoubleClicked: root.toggleMaximized()
        }

        Row {
            id: trafficLights
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            component TrafficLight: Rectangle {
                id: light
                property color base: "#ff5f57"
                property string action: "close"
                width: 12
                height: 12
                radius: 6
                color: lightArea.containsMouse ? Qt.lighter(light.base, 1.18) : light.base
                border.width: 0.5
                border.color: "#00000033"
                MouseArea {
                    id: lightArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        if (light.action === "close") {
                            root.closeWindow()
                        } else if (light.action === "min") {
                            root.showMinimized()
                        } else {
                            root.toggleMaximized()
                        }
                    }
                }
            }

            TrafficLight { base: "#ff5f57"; action: "close" }
            TrafficLight { base: "#febc2e"; action: "min" }
            TrafficLight { base: "#28c840"; action: "max" }
        }

        Text {
            anchors.centerIn: parent
            text: root.configureMode ? (root.zh ? "运行设置" : "Run Settings") : root.appName
            font.pixelSize: 13
            font.weight: Font.DemiBold
            color: c.text
            opacity: 0.8
        }

        // Windows 式的窗口按钮：最小化 / 最大化 / 关闭，贴右上角整高
        Row {
            id: captionButtons
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom

            component CaptionButton: AbstractButton {
                id: cap
                property string kind: "min"
                width: 46
                height: captionButtons.height
                hoverEnabled: true
                background: Rectangle {
                    color: cap.kind === "close" && cap.hovered ? "#c42b1c"
                         : (cap.pressed ? c.press : (cap.hovered ? c.hover : "transparent"))
                }
                contentItem: Item {
                    readonly property color stroke: cap.kind === "close" && cap.hovered ? "#ffffff" : c.text
                    Rectangle {
                        visible: cap.kind === "min"
                        anchors.centerIn: parent
                        width: 10
                        height: 1
                        color: parent.stroke
                    }
                    Rectangle {
                        visible: cap.kind === "max"
                        anchors.centerIn: parent
                        width: 9
                        height: 9
                        color: "transparent"
                        border.width: 1
                        border.color: parent.stroke
                    }
                    Item {
                        visible: cap.kind === "close"
                        anchors.centerIn: parent
                        width: 10
                        height: 10
                        Rectangle {
                            anchors.centerIn: parent
                            width: 11
                            height: 1
                            color: parent.parent.stroke
                            rotation: 45
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 11
                            height: 1
                            color: parent.parent.stroke
                            rotation: -45
                        }
                    }
                }
            }

            CaptionButton { kind: "min"; onClicked: root.showMinimized() }
            CaptionButton { kind: "max"; onClicked: root.toggleMaximized() }
            CaptionButton { kind: "close"; onClicked: root.closeWindow() }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: c.line
        }
    }

    // 合成器发来的关闭请求（比如桌面的 Super+Q、窗口管理器的关闭按钮）：
    // 有托盘就收进去，别把进程直接杀掉——退出走托盘右键菜单。
    onClosing: function (close) {
        if (!root.configureMode && backend.tray_available) {
            close.accepted = false
            root.hide()
        }
    }

    function closeWindow() {
        if (root.configureMode || !backend.tray_available) {
            backend.quit_app()
        } else {
            root.hide()
        }
    }

    function toggleMaximized() {
        if (root.visibility === Window.Maximized) root.showNormal()
        else root.showMaximized()
    }

    // ── 侧栏 + 内容 ─────────────────────────────────────────
    RowLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            visible: !root.configureMode
            Layout.preferredWidth: 216
            Layout.fillHeight: true
            color: c.sidebar

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: 14
                anchors.bottomMargin: 12
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 1

                // 前缀：换页面时跟着换（进程页是「前缀 · 游戏」）
                Repeater {
                    model: root.sidebarPrefixes
                    delegate: AbstractButton {
                        id: prefBtn
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        implicitHeight: 30
                        readonly property bool active: modelData.path === root.currentPrefix()
                        background: Rectangle {
                            radius: 7
                            color: prefBtn.active ? c.rowActive : (prefBtn.hovered ? c.hover : "transparent")
                        }
                        contentItem: RowLayout {
                            spacing: 8
                            Text {
                                Layout.leftMargin: 12
                                Layout.fillWidth: true
                                Layout.rightMargin: 4
                                text: root.prefixItemLabel(prefBtn.modelData)
                                color: prefBtn.active ? c.text : c.dim
                                font.pixelSize: 13
                                font.weight: prefBtn.active ? Font.DemiBold : Font.Normal
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                            }

                            // 当前前缀的独立网络开关（改 .protonboost.conf，下次启动生效）
                            Item {
                                id: netToggle
                                visible: prefBtn.active
                                Layout.rightMargin: 5
                                implicitWidth: 18
                                implicitHeight: 18
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 5
                                    color: prefBtn.modelData.netns ? c.accent
                                         : (netArea.containsMouse ? c.hover : "transparent")
                                    border.width: 1
                                    border.color: prefBtn.modelData.netns ? "transparent" : c.line
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 6
                                    height: 6
                                    radius: 3
                                    color: prefBtn.modelData.netns ? c.sidebar : c.faint
                                }
                                MouseArea {
                                    id: netArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: backend.set_prefix_netns(prefBtn.modelData.path, !prefBtn.modelData.netns)
                                }
                                ToolTip.visible: netArea.containsMouse
                                ToolTip.delay: 500
                                ToolTip.text: prefBtn.modelData.netns
                                    ? (root.zh ? "独立网络：开（点击关闭）" : "Isolated network: on")
                                    : (root.zh ? "独立网络：关（点击开启）" : "Isolated network: off")
                            }
                        }
                        ToolTip.visible: hovered
                        ToolTip.delay: 700
                        ToolTip.text: modelData.path + "\n" + (root.zh ? "右键打开这个前缀的 drive_c"
                                                                      : "Right-click to open its drive_c")
                        onClicked: {
                            root.setPrefix(modelData.path)
                            root.refreshCurrent()
                        }
                        // 右键：直接在文件管理器里打开前缀（里面 pfx/drive_c 就是 C 盘）
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onTapped: backend.open_folder(modelData.path)
                        }
                    }
                }

                Item { implicitHeight: 10 }
                Rectangle {
                    Layout.leftMargin: 9
                    Layout.rightMargin: 9
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: c.line
                    opacity: 0.75
                }
                Item { implicitHeight: 8 }

                // 视图：应用 / Linux 程序 / 进程
                Repeater {
                    model: root.pageNames.length
                    delegate: AbstractButton {
                        id: navBtn
                        required property int index
                        Layout.fillWidth: true
                        implicitHeight: 30
                        background: Rectangle {
                            radius: 7
                            color: navBtn.index === root.currentPage
                                   ? c.rowActive
                                   : (navBtn.hovered ? c.hover : "transparent")
                        }
                        contentItem: Text {
                            leftPadding: 12
                            text: root.pageNames[navBtn.index]
                            color: navBtn.index === root.currentPage ? c.text
                                 : (navBtn.hovered ? c.text : c.dim)
                            font.pixelSize: 13
                            font.weight: navBtn.index === root.currentPage ? Font.DemiBold : Font.Normal
                            verticalAlignment: Text.AlignVCenter
                        }
                        onClicked: root.switchPage(navBtn.index)
                    }
                }

                Item { Layout.fillHeight: true }

                Text {
                    Layout.leftMargin: 9
                    text: root.version
                    font.pixelSize: 11
                    color: c.faint
                }
            }
        }

        Rectangle {
            visible: !root.configureMode
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: c.line
        }

        // 页面区
        ColumnLayout {
            visible: !root.configureMode
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            StackLayout {
                id: pageStack
                currentIndex: root.currentPage
                Layout.fillWidth: true
                Layout.fillHeight: true

                AppsPage {}
                LinuxPage {}
                ProcsPage {}
            }

            // 状态栏：状态 + 网络开关 + 当前页数量
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                color: c.sidebar
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: c.line }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 10
                    Rectangle {
                        width: 6
                        height: 6
                        radius: 3
                        color: c.accent
                        opacity: 0.8
                    }
                    Text {
                        Layout.fillWidth: true
                        text: backend.status
                        color: c.dim
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                    Text {
                        text: root.pageSummary()
                        color: c.faint
                        font.pixelSize: 12
                    }
                }
            }
        }
    }

    // ── 页面骨架 ────────────────────────────────────────────
    component PageHeader: Item {
        implicitHeight: headLayout.implicitHeight
        default property alias actions: actionsRow.data
        ColumnLayout {
            id: headLayout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text {
                    text: root.pageTitles[root.currentPage]
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    color: c.text
                    font.letterSpacing: -0.4
                }
                Item { Layout.fillWidth: true }
                RowLayout { id: actionsRow; spacing: 8 }
            }
            Text {
                text: root.pageSubtitles[root.currentPage]
                font.pixelSize: 13
                color: c.dim
                lineHeight: 1.25
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
    }

    component PageToolbar: RowLayout {
        id: toolbar
        /// 这个工具条属于哪一页（0 应用 / 1 Linux / 2 进程）
        property int page: 0
        signal submitted()
        default property alias trailing: trailingRow.data
        spacing: 8
        RowLayout { id: trailingRow; spacing: 8 }
        Item { Layout.fillWidth: true }
        WSearchField {
            id: pageSearchField
            Layout.preferredWidth: 220
            implicitHeight: 32
            placeholderText: root.searchHints[toolbar.page]
            text: root.searchValues[toolbar.page]
            onTextEdited: {
                var copy = root.searchValues.slice()
                copy[toolbar.page] = text
                root.searchValues = copy
            }
            onAccepted: toolbar.submitted()
        }
        Connections {
            target: root
            function onSearchFocusTickChanged() {
                if (root.currentPage === toolbar.page) pageSearchField.forceActiveFocus()
            }
        }
    }

    // 设置分组：标题 + 一块浅底卡片
    component SettingsCard: Rectangle {
        id: card
        property string title: ""
        default property alias content: inner.data
        Layout.fillWidth: true
        implicitHeight: inner.implicitHeight + 28
        radius: 10
        color: c.group
        border.width: 1
        border.color: c.line

        ColumnLayout {
            id: inner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 14
            spacing: 10

            Text {
                text: card.title
                font.pixelSize: 11
                font.letterSpacing: 0.6
                color: c.faint
            }
        }
    }

    // 分组列表：一个圆角容器装所有行
    component GroupList: ListView {
        id: group
        clip: true
        spacing: 0
        width: parent ? parent.width : 0
        visible: count > 0

        Rectangle {
            z: -1
            width: group.width
            height: group.height
            radius: 12
            color: c.row
            border.width: 1
            border.color: c.line
        }

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    }

    component EmptyState: ColumnLayout {
        property string title: ""
        property string hint: ""
        property var action: null
        property string actionText: ""
        anchors.centerIn: parent
        spacing: 6
        visible: false
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: 52
            implicitHeight: 52
            radius: 26
            color: "transparent"
            border.width: 1
            border.color: c.line
            Rectangle {
                anchors.centerIn: parent
                width: 18
                height: 18
                radius: 5
                color: c.rowHover
                border.width: 1
                border.color: c.line
            }
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: parent.title
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: c.dim
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: parent.hint
            font.pixelSize: 12
            color: c.faint
            horizontalAlignment: Text.AlignHCenter
            Layout.maximumWidth: 320
            wrapMode: Text.WordWrap
        }
        WButton {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 6
            visible: parent.action !== null
            text: parent.actionText
            onClicked: if (parent.action) parent.action()
        }
    }

    // 行里的图标：有图就用，没有就给个占位
    component AppIcon: Item {
        property string source: ""
        property int size: 38
        implicitWidth: size
        implicitHeight: size
        Rectangle {
            anchors.fill: parent
            radius: Math.round(size * 0.24)
            color: c.group
            border.width: 1
            border.color: c.line
            visible: img.status !== Image.Ready
            Text {
                anchors.centerIn: parent
                text: "⊞"
                font.pixelSize: size * 0.45
                color: c.faint
            }
        }
        Image {
            id: img
            anchors.fill: parent
            source: parent.source ? (parent.source.indexOf("/") === 0 ? "file://" + parent.source : parent.source) : ""
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            visible: status === Image.Ready
        }
    }

    // 检查器里的一条键值
    component DetailRow: ColumnLayout {
        id: detailRow
        property string label: ""
        property string value: "—"
        property string hint: ""
        spacing: 2
        Text {
            text: detailRow.label
            font.pixelSize: 11
            color: c.faint
        }
        Text {
            id: detailValue
            Layout.fillWidth: true
            text: detailRow.value
            font.pixelSize: 12
            color: c.text
            wrapMode: Text.WrapAnywhere
            HoverHandler { id: detailHover }
        }
        ToolTip.visible: detailHover.hovered && detailRow.hint !== ""
        ToolTip.delay: 700
        ToolTip.text: detailRow.hint
    }

    // ── 页面：应用 ──────────────────────────────────────────
    component AppsPage: Item {
        id: appsPage
        property int selectedIndex: -1
        /// 选中的是「哪一个应用」而不是「第几行」：刷新列表后选中不会跳到别人身上
        property string selectedId: ""
        property var rows: []

        function select(index) {
            if (index < 0 || index >= rows.length) { clearSelection(); return }
            selectedIndex = index
            selectedId = rows[index].appId
        }
        function clearSelection() {
            selectedIndex = -1
            selectedId = ""
        }
        function rebuild() {
            var q = root.searchValues[0].toLowerCase()
            var source = backend.apps
            var out = []
            for (var i = 0; i < source.length; i++) {
                var item = source[i]
                if (q === "") { out.push(item); continue }
                var hay = (item.name + " " + item.detail + " " + item.meta + " " + item.path).toLowerCase()
                if (hay.indexOf(q) >= 0) out.push(item)
            }
            rows = out
            if (selectedId !== "") {
                var found = -1
                for (var j = 0; j < out.length; j++) {
                    if (out[j].appId === selectedId) { found = j; break }
                }
                selectedIndex = found
                if (found < 0) selectedId = ""
            } else if (selectedIndex >= out.length) {
                selectedIndex = -1
            }
        }
        function moveSelection(step) {
            if (rows.length === 0) return
            var next = (selectedIndex < 0 ? (step > 0 ? 0 : rows.length - 1) : selectedIndex + step)
            if (next < 0) next = 0
            if (next > rows.length - 1) next = rows.length - 1
            select(next)
            appsList.positionViewAtIndex(next, ListView.Contain)
        }
        function runItem(item) {
            if (!item) return
            if (item.isSteam && item.steamAppid)
                backend.run_steam_game(item.steamAppid, item.path, root.appsPrefix)
            else
                backend.run_path(item.path, root.appsPrefix, item.runner)
        }
        function openLog(item) {
            if (!item) return
            root.currentLogAppId = item.appId
            root.logTitle = item.name
            logTextArea.text = backend.log_text(item.appId)
            logPopup.open()
        }
        function openFolder(item) {
            if (!item) return
            var p = item.path
            var cut = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
            backend.open_folder(cut > 0 ? p.substring(0, cut) : p)
        }

        readonly property var selectedApp: (selectedIndex >= 0 && selectedIndex < rows.length)
                                             ? rows[selectedIndex] : null
        readonly property string selectedLog: selectedApp && selectedApp.hasLog
                                              ? backend.log_tail(selectedApp.appId, 10) : ""

        Component.onCompleted: { rebuild(); appsList.forceActiveFocus() }
        onVisibleChanged: if (visible) { rebuild(); appsList.forceActiveFocus() }
        Connections { target: backend; function onAppsChanged() { appsPage.rebuild() } }
        Connections { target: root; function onSearchValuesChanged() { appsPage.rebuild() } }

        RowLayout {
            anchors.fill: parent
            spacing: 0

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 24
                spacing: 16

                PageHeader { Layout.fillWidth: true }

                PageToolbar {
                    Layout.fillWidth: true
                    page: 0
                    onSubmitted: appsList.forceActiveFocus()

                    WMenuButton {
                        id: addBtn
                        implicitHeight: 32
                        text: root.zh ? "添加应用" : "Add App"
                        onClicked: addMenu.popup(addBtn, 0, addBtn.height + 4)
                        Menu {
                            id: addMenu
                            width: 220
                            padding: 4
                            background: Rectangle { radius: 10; color: c.row; border.width: 1; border.color: c.line }
                            WMenuItem {
                                text: root.zh ? "添加 exe 文件…" : "Add an .exe…"
                                onTriggered: addExeDialog.open()
                            }
                            WMenuItem {
                                text: root.zh ? "直接运行 exe…（安装包用）" : "Run an .exe… (installers)"
                                onTriggered: runExeDialog.open()
                            }
                            MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: c.line } }
                            WMenuItem {
                                text: root.zh ? "从安装目录挑选…" : "Pick from a folder…"
                                onTriggered: {
                                    backend.refresh_page("dirs", root.appsPrefix)
                                    dirsPopup.open()
                                }
                            }
                        }
                    }
                    WAccentButton {
                        visible: backend.update_available && backend.runner_count > 0
                        text: root.zh ? "更新运行器" : "Update Runners"
                        ToolTip.visible: hovered
                        ToolTip.delay: 300
                        ToolTip.text: backend.update_details
                        onClicked: root.confirm(root.zh ? "更新运行器" : "Update Runners",
                            (root.zh ? "以下运行器有新版本可用，是否立即更新？\n\n" : "Updates available:\n\n")
                            + backend.update_details,
                            function () { backend.update_runners_now() })
                    }
                }

                // 一个 Proton/Wine 都没有时，程序根本跑不起来，得先把话说清楚并给出下载入口
                Rectangle {
                    visible: backend.runner_count === 0
                    Layout.fillWidth: true
                    implicitHeight: 48
                    radius: 10
                    color: c.accentSoft
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 10
                        spacing: 10
                        Text {
                            Layout.fillWidth: true
                            text: root.zh
                                  ? "没有找到 Proton / Wine 运行器，程序启动不了。可以先下载一个 WE-Proton（约 345 MB，自带 wintun，加速器必需）。"
                                  : "No Proton / Wine runner found. Download WE-Proton to get started (~345 MB, wintun included)."
                            color: c.accent
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                        WButton {
                            outlined: true
                            implicitHeight: 28
                            text: root.zh ? "下载运行器" : "Download Runner"
                            onClicked: root.confirm(
                                root.zh ? "下载运行器" : "Download Runner",
                                (root.zh ? "会下载 " : "Will download ")
                                + (backend.update_details !== "" ? backend.update_details : "WE-Proton")
                                + (root.zh
                                   ? "\n\nGitHub 直连失败会自动换镜像重试；也可设 PROTONBOOST_GH_MIRROR 指定加速镜像。\n解压到 ~/.local/share/Steam/compatibilitytools.d/，占约 1.6 GB。需要几分钟，期间界面照常可用。"
                                   : "\n\nIf GitHub is unreachable, a mirror is tried automatically; set PROTONBOOST_GH_MIRROR to choose one.\nInstalled into ~/.local/share/Steam/compatibilitytools.d/ (~1.6 GB)."),
                                function () { backend.update_runners_now() })
                        }
                    }
                }

                // 独立网络开着、又没有覆盖层辅助库时提醒一句：
                // Steam 覆盖层在命名空间里找不到宿主客户端（会悄悄失效）
                Rectangle {
                    visible: backend.netns && !backend.overlay_ready
                    Layout.fillWidth: true
                    implicitHeight: 40
                    radius: 10
                    color: c.group
                    border.width: 1
                    border.color: c.line
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 10
                        spacing: 10
                        Text {
                            Layout.fillWidth: true
                            text: root.zh
                                  ? "独立网络里 Steam 覆盖层可能失效：辅助库没准备好（构建时缺 C 编译器，装上 gcc 后重新编译本程序即可）。"
                                  : "The Steam overlay may not work inside the isolated network: the helper library is missing (built without a C compiler; install gcc and rebuild)."
                            color: c.dim
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    GroupList {
                        id: appsList
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: Math.min(Math.max(contentHeight, 1) + 2, parent.height)
                        model: appsPage.rows
                        focus: true
                        currentIndex: appsPage.selectedIndex >= 0 ? appsPage.selectedIndex : -1
                        Keys.onDownPressed: function (event) { appsPage.moveSelection(1); event.accepted = true }
                        Keys.onUpPressed: function (event) { appsPage.moveSelection(-1); event.accepted = true }
                        Keys.onReturnPressed: function (event) {
                            appsPage.runItem(appsPage.selectedApp)
                            event.accepted = true
                        }

                        delegate: Rectangle {
                            id: appRow
                            width: appsList.width
                            height: 62
                            readonly property bool active: appsPage.selectedIndex === index
                            color: active ? c.rowActive : (rowMouse.containsMouse ? c.rowHover : "transparent")

                            Rectangle {
                                anchors.bottom: parent.bottom
                                x: 62
                                width: parent.width - 62
                                height: 1
                                color: c.line
                                visible: index < appsList.count - 1
                            }

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    appsPage.select(index)
                                    appsList.forceActiveFocus()
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 12
                                spacing: 12

                                AppIcon {
                                    source: modelData.icon && modelData.icon !== "protonboost" ? modelData.icon : ""
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    RowLayout {
                                        spacing: 6
                                        Text {
                                            text: modelData.name
                                            color: c.text
                                            font.pixelSize: 14
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: parent.width - 70
                                        }
                                        Rectangle {
                                            visible: modelData.running
                                            radius: 4
                                            color: c.accentSoft
                                            implicitWidth: runningLabel.implicitWidth + 10
                                            implicitHeight: 16
                                            Text {
                                                id: runningLabel
                                                anchors.centerIn: parent
                                                text: root.zh ? "运行中" : "Running"
                                                font.pixelSize: 10
                                                color: c.accent
                                            }
                                        }
                                    }
                                    Text {
                                        text: modelData.detail + (modelData.meta ? " · " + modelData.meta : "")
                                        color: c.dim
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }

                                WAccentButton {
                                    visible: !modelData.running
                                    text: root.zh ? "运行" : "Run"
                                    ToolTip.visible: modelData.isSteam && hovered
                                    ToolTip.delay: 400
                                    ToolTip.text: root.zh ? "通过 Steam 启动" : "Start through Steam"
                                    onClicked: appsPage.runItem(modelData)
                                }
                                WDangerButton {
                                    visible: modelData.running
                                    text: root.zh ? "关闭" : "Close"
                                    onClicked: backend.close_app(modelData.appId, root.appsPrefix)
                                }

                                WIconButton {
                                    id: moreBtn
                                    glyph: "⋯"
                                    onClicked: appMenu.popup(moreBtn, -160, moreBtn.height + 4)
                                    Menu {
                                        id: appMenu
                                        width: 190
                                        padding: 4
                                        background: Rectangle { radius: 10; color: c.row; border.width: 1; border.color: c.line }
                                        WMenuItem {
                                            text: root.zh ? "查看详情" : "Show Details"
                                            onTriggered: {
                                                appsPage.select(index)
                                                appsList.forceActiveFocus()
                                            }
                                        }
                                        WMenuItem {
                                            visible: modelData.hasLog
                                            text: root.zh ? "运行日志" : "Run Log"
                                            onTriggered: appsPage.openLog(modelData)
                                        }
                                        WMenuItem {
                                            visible: modelData.canConfig
                                            text: root.zh ? "运行设置" : "Run Settings"
                                            onTriggered: backend.open_config(modelData.appId, root.appsPrefix)
                                        }
                                        WMenuItem {
                                            text: root.zh ? "重命名" : "Rename"
                                            onTriggered: {
                                                renameField.text = modelData.name
                                                root.renameTarget = modelData.appId
                                                renamePopup.open()
                                            }
                                        }
                                        WMenuItem {
                                            text: root.zh ? "导出到应用列表" : "Export to App List"
                                            onTriggered: backend.export_app(modelData.appId, root.appsPrefix)
                                        }
                                        WMenuItem {
                                            text: root.zh ? "打开所在目录" : "Open Folder"
                                            onTriggered: appsPage.openFolder(modelData)
                                        }
                                        MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: c.line } }
                                        WMenuItem {
                                            text: root.zh ? "删除配置" : "Delete Config"
                                            onTriggered: root.confirm(root.zh ? "删除配置" : "Delete Config",
                                                root.zh ? "删除这个应用保存的配置？" : "Delete this app's saved settings?",
                                                function () { backend.delete_app(modelData.appId, root.appsPrefix) })
                                        }
                                    }
                                }
                            }
                        }
                    }

                    EmptyState {
                        title: root.zh ? "还没有应用" : "No apps yet"
                        hint: root.zh ? "点“添加应用”，挑一个 exe，或者从安装目录里选。"
                                      : "Add one from an .exe, or pick it from an install folder."
                        actionText: root.zh ? "选择 exe 文件" : "Choose an .exe"
                        action: function () { addExeDialog.open() }
                        visible: appsList.count === 0
                    }
                }
            }

            // 检查器：选中一行才出现
            Rectangle {
                visible: appsPage.selectedIndex >= 0
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                color: c.line
            }

            DetailPane {
                visible: appsPage.selectedIndex >= 0
                Layout.preferredWidth: 320
                Layout.fillHeight: true
                app: appsPage.selectedApp
                logTail: appsPage.selectedLog
            }
        }
    }

    // 右侧检查器
    component DetailPane: Rectangle {
        id: pane
        property var app: null
        property string logTail: ""
        color: c.window

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 14

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                AppIcon {
                    size: 52
                    source: pane.app && pane.app.icon && pane.app.icon !== "protonboost" ? pane.app.icon : ""
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 3
                    Text {
                        Layout.fillWidth: true
                        text: pane.app ? pane.app.name : ""
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        color: c.text
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: pane.app
                              ? (pane.app.detail + (pane.app.meta ? " · " + pane.app.meta : ""))
                              : ""
                        font.pixelSize: 12
                        color: c.dim
                        elide: Text.ElideRight
                    }
                }
                WIconButton {
                    glyph: "✕"
                    ToolTip.text: root.zh ? "收起" : "Hide"
                    onClicked: appsPage.clearSelection()
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: c.line }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 12

                DetailRow {
                    Layout.fillWidth: true
                    label: root.zh ? "路径" : "Path"
                    value: pane.app ? (pane.app.winPath || pane.app.path) : ""
                    hint: pane.app ? pane.app.path : ""
                }
                DetailRow {
                    Layout.fillWidth: true
                    label: root.zh ? "运行器" : "Runner"
                    value: pane.app ? root.shortPath(pane.app.runner) : ""
                }
                DetailRow {
                    Layout.fillWidth: true
                    label: root.zh ? "类型" : "Kind"
                    value: root.kindLabel(pane.app)
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: c.line }

            Text {
                Layout.fillWidth: true
                text: root.zh ? "最近日志" : "Recent log"
                font.pixelSize: 11
                color: c.faint
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 80
                radius: 8
                color: c.group
                border.width: 1
                border.color: c.line

                Text {
                    anchors.centerIn: parent
                    visible: pane.logTail === ""
                    text: root.zh ? "还没有运行日志" : "No log yet"
                    font.pixelSize: 12
                    color: c.faint
                }

                Flickable {
                    anchors.fill: parent
                    anchors.margins: 9
                    visible: pane.logTail !== ""
                    clip: true
                    // 日志行不折行（折了反而更难读），宽了就横向拖
                    contentWidth: Math.max(width, tailText.implicitWidth)
                    contentHeight: tailText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                    Text {
                        id: tailText
                        text: pane.logTail
                        font.family: "monospace"
                        font.pixelSize: 11
                        lineHeight: 1.25
                        color: c.dim
                        wrapMode: Text.NoWrap
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                WAccentButton {
                    visible: pane.app && !pane.app.running
                    text: root.zh ? "运行" : "Run"
                    onClicked: appsPage.runItem(pane.app)
                }
                WDangerButton {
                    visible: pane.app && pane.app.running
                    text: root.zh ? "关闭" : "Close"
                    onClicked: backend.close_app(pane.app.appId, root.appsPrefix)
                }
                WButton {
                    visible: pane.app && pane.app.canConfig
                    outlined: true
                    text: root.zh ? "设置" : "Settings"
                    onClicked: backend.open_config(pane.app.appId, root.appsPrefix)
                }
                Item { Layout.fillWidth: true }
                WButton {
                    text: root.zh ? "目录" : "Folder"
                    onClicked: appsPage.openFolder(pane.app)
                }
                WButton {
                    text: root.zh ? "日志" : "Log"
                    onClicked: appsPage.openLog(pane.app)
                }
            }
        }
    }

    // ── 页面：Linux 程序 ────────────────────────────────────
    component LinuxPage: Item {
        id: linuxPage
        property var rows: []

        function rebuild() {
            var q = root.searchValues[1].toLowerCase()
            var source = backend.linux_apps
            var out = []
            for (var i = 0; i < source.length; i++) {
                var item = source[i]
                if (q === "") { out.push(item); continue }
                var hay = (item.name + " " + item.id + " " + item.path).toLowerCase()
                if (hay.indexOf(q) >= 0) out.push(item)
            }
            rows = out
        }
        function launchCustom() {
            var cmd = customCmd.text.trim()
            if (cmd === "") return
            customCmd.text = ""
            backend.launch_linux(root.linuxPrefix, cmd)
        }

        Component.onCompleted: rebuild()
        onVisibleChanged: if (visible) rebuild()
        Connections { target: backend; function onLinux_appsChanged() { linuxPage.rebuild() } }
        Connections { target: root; function onSearchValuesChanged() { linuxPage.rebuild() } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            PageHeader { Layout.fillWidth: true }

            PageToolbar {
                Layout.fillWidth: true
                page: 1
                onSubmitted: customCmd.forceActiveFocus()
                WField {
                    id: customCmd
                    Layout.preferredWidth: 240
                    implicitHeight: 32
                    placeholderText: root.zh ? "自定义命令，如 steam" : "Custom command, e.g. steam"
                    onAccepted: linuxPage.launchCustom()
                }
                WAccentButton {
                    implicitHeight: 32
                    text: root.zh ? "运行命令" : "Run"
                    onClicked: linuxPage.launchCustom()
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                GroupList {
                    id: linuxList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: Math.min(Math.max(contentHeight, 1) + 2, parent.height)
                    model: linuxPage.rows

                    delegate: Rectangle {
                        width: linuxList.width
                        height: 62
                        color: linuxMouse.containsMouse ? c.rowHover : "transparent"
                        Rectangle {
                            anchors.bottom: parent.bottom
                            x: 62
                            width: parent.width - 62
                            height: 1
                            color: c.line
                            visible: index < linuxList.count - 1
                        }
                        MouseArea { id: linuxMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 12
                            spacing: 12
                            AppIcon { source: modelData.icon ? modelData.icon : ""; size: 36 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    text: modelData.name
                                    color: c.text
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: modelData.id
                                    color: c.dim
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    Layout.fillWidth: true
                                }
                            }
                            WAccentButton {
                                text: root.zh ? "运行" : "Run"
                                onClicked: backend.launch_desktop(root.linuxPrefix, modelData.path, modelData.name)
                            }
                        }
                    }
                }

                EmptyState {
                    title: root.zh ? "没有可启动的程序" : "No launchable apps"
                    hint: root.zh ? "系统里的 .desktop 程序会出现在这里。" : "Applications from .desktop files show up here."
                    visible: linuxList.count === 0
                }
            }
        }
    }

    // ── 页面：进程 ──────────────────────────────────────────
    component ProcsPage: Item {
        id: procsPage
        property var rows: []

        function rebuild() {
            var q = root.searchValues[2].toLowerCase()
            var source = backend.procs
            var out = []
            for (var i = 0; i < source.length; i++) {
                var item = source[i]
                if (q === "") { out.push(item); continue }
                var hay = (item.title + " " + item.command).toLowerCase()
                if (hay.indexOf(q) >= 0) out.push(item)
            }
            rows = out
        }

        Component.onCompleted: rebuild()
        onVisibleChanged: if (visible) rebuild()
        Connections { target: backend; function onProcsChanged() { procsPage.rebuild() } }
        Connections { target: root; function onSearchValuesChanged() { procsPage.rebuild() } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            PageHeader { Layout.fillWidth: true }

            PageToolbar {
                Layout.fillWidth: true
                page: 2
                WButton {
                    outlined: true
                    text: root.zh ? "刷新" : "Refresh"
                    onClicked: root.refreshCurrent()
                }
                WDangerButton {
                    text: root.zh ? "结束全部进程" : "Close All"
                    onClicked: backend.kill_all_processes(root.procsPrefix)
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                GroupList {
                    id: procsList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: Math.min(Math.max(contentHeight, 1) + 2, parent.height)
                    model: procsPage.rows

                    delegate: Rectangle {
                        width: procsList.width
                        height: 58
                        color: procsMouse.containsMouse ? c.rowHover : "transparent"
                        Rectangle {
                            anchors.bottom: parent.bottom
                            x: 14
                            width: parent.width - 14
                            height: 1
                            color: c.line
                            visible: index < procsList.count - 1
                        }
                        MouseArea { id: procsMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 12
                            spacing: 12
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    text: modelData.title
                                    color: c.text
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: modelData.command
                                    color: c.dim
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    Layout.fillWidth: true
                                }
                            }
                            WDangerButton {
                                text: root.zh ? "强制结束" : "Force Close"
                                onClicked: backend.kill_proc(modelData.pid, true)
                            }
                        }
                    }
                }

                EmptyState {
                    title: root.zh ? "没有运行中的进程" : "Nothing running"
                    hint: root.zh ? "这个前缀里的 Windows 程序都没在跑。" : "No Windows programs are running in this prefix."
                    visible: procsList.count === 0
                }
            }
        }
    }

    // ── 弹层：确认 ──────────────────────────────────────────
    Popup {
        id: confirmPopup
        modal: true
        Overlay.modal: Rectangle { color: c.dark ? "#99000000" : "#40000000" }
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 460
        padding: 22
        background: Rectangle { radius: 14; color: c.row; border.width: 1; border.color: c.line }
        contentItem: ColumnLayout {
            spacing: 14
            Text {
                id: confirmTitle
                color: c.text
                font.pixelSize: 15
                font.weight: Font.DemiBold
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
            Text {
                id: confirmMessage
                color: c.dim
                font.pixelSize: 13
                lineHeight: 1.3
                wrapMode: Text.WrapAnywhere
                Layout.fillWidth: true
            }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton { text: root.zh ? "取消" : "Cancel"; onClicked: confirmPopup.close() }
                WDangerButton {
                    text: root.zh ? "确定" : "OK"
                    onClicked: {
                        var action = root.pendingConfirm
                        confirmPopup.close()
                        if (action) action()
                    }
                }
            }
        }
    }

    // ── 弹层：重命名 ────────────────────────────────────────
    Popup {
        id: renamePopup
        modal: true
        Overlay.modal: Rectangle { color: c.dark ? "#99000000" : "#40000000" }
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 400
        padding: 22
        background: Rectangle { radius: 14; color: c.row; border.width: 1; border.color: c.line }
        contentItem: ColumnLayout {
            spacing: 12
            Text { text: root.zh ? "重命名" : "Rename"; font.pixelSize: 15; font.weight: Font.DemiBold; color: c.text }
            Text { text: root.zh ? "显示名称" : "Display name"; font.pixelSize: 12; color: c.dim }
            WField { id: renameField; Layout.fillWidth: true; onAccepted: renamePopup.save() }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton { text: root.zh ? "取消" : "Cancel"; onClicked: renamePopup.close() }
                WAccentButton { text: root.zh ? "保存" : "Save"; onClicked: renamePopup.save() }
            }
        }
        function save() {
            var name = renameField.text.trim()
            var target = root.renameTarget
            close()
            if (name !== "" && target !== "") backend.rename_app(target, root.appsPrefix, name)
        }
    }

    // ── 弹层：日志 ──────────────────────────────────────────
    Popup {
        id: logPopup
        modal: true
        Overlay.modal: Rectangle { color: c.dark ? "#99000000" : "#40000000" }
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 880
        height: 620
        padding: 20
        background: Rectangle { radius: 14; color: c.row; border.width: 1; border.color: c.line }
        contentItem: ColumnLayout {
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: (root.zh ? "运行日志" : "Run Log") + " · " + root.logTitle
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    color: c.text
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                WIconButton { glyph: "✕"; onClicked: logPopup.close() }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 10
                color: c.group
                border.width: 1
                border.color: c.line
                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 10
                    TextArea {
                        id: logTextArea
                        readOnly: true
                        wrapMode: TextArea.NoWrap
                        font.family: "monospace"
                        font.pixelSize: 12
                        color: c.text
                        background: null
                    }
                }
            }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton {
                    text: root.zh ? "刷新" : "Refresh"
                    onClicked: logTextArea.text = backend.log_text(root.currentLogAppId)
                }
                WButton {
                    text: root.zh ? "打开日志目录" : "Open Log Folder"
                    onClicked: backend.open_folder(backend.log_dir(root.currentLogAppId))
                }
                WAccentButton { text: root.zh ? "完成" : "Done"; onClicked: logPopup.close() }
            }
        }
    }

    // ── 弹层：挑一个安装目录 ────────────────────────────────
    Popup {
        id: dirsPopup
        modal: true
        Overlay.modal: Rectangle { color: c.dark ? "#99000000" : "#40000000" }
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 660
        height: 540
        padding: 20
        background: Rectangle { radius: 14; color: c.row; border.width: 1; border.color: c.line }
        contentItem: ColumnLayout {
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: root.zh ? "从安装目录挑选" : "Pick from a folder"
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        color: c.text
                    }
                    Text {
                        text: root.zh ? "选一个文件夹，再从里面的 exe 里挑要加的程序。"
                                      : "Choose a folder, then pick the executable inside it."
                        font.pixelSize: 12
                        color: c.dim
                    }
                }
                WIconButton { glyph: "✕"; onClicked: dirsPopup.close() }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 10
                color: c.group
                border.width: 1
                border.color: c.line
                clip: true

                ListView {
                    id: dirsPicker
                    anchors.fill: parent
                    anchors.margins: 4
                    clip: true
                    model: backend.dirs
                    delegate: AbstractButton {
                        id: dirItem
                        width: dirsPicker.width
                        height: 54
                        background: Rectangle {
                            radius: 8
                            color: dirItem.hovered ? c.rowHover : "transparent"
                        }
                        contentItem: RowLayout {
                            spacing: 12
                            Rectangle {
                                Layout.leftMargin: 8
                                width: 32
                                height: 32
                                radius: 8
                                color: c.row
                                border.width: 1
                                border.color: c.line
                                Text { anchors.centerIn: parent; text: "▤"; font.pixelSize: 14; color: c.faint }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    text: modelData.name
                                    color: c.text
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: modelData.detail
                                    color: c.dim
                                    font.pixelSize: 11
                                    elide: Text.ElideMiddle
                                    Layout.fillWidth: true
                                }
                            }
                            Text {
                                Layout.rightMargin: 10
                                text: "›"
                                font.pixelSize: 15
                                color: c.faint
                            }
                        }
                        onClicked: {
                            backend.show_dir_exes(root.appsPrefix, modelData.path)
                            dirsPopup.close()
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: backend.dirs.length === 0
                    text: root.zh ? "这个前缀里还没有含 exe 的目录" : "No folder in this prefix contains executables"
                    font.pixelSize: 12
                    color: c.faint
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                WButton {
                    outlined: true
                    text: root.zh ? "刷新" : "Refresh"
                    onClicked: backend.refresh_page("dirs", root.appsPrefix)
                }
                Item { Layout.fillWidth: true }
                WButton { text: root.zh ? "取消" : "Cancel"; onClicked: dirsPopup.close() }
            }
        }
    }

    // ── 弹层：目录里的 exe ──────────────────────────────────
    Popup {
        id: exesPopup
        modal: true
        Overlay.modal: Rectangle { color: c.dark ? "#99000000" : "#40000000" }
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 720
        height: 560
        padding: 20
        background: Rectangle { radius: 14; color: c.row; border.width: 1; border.color: c.line }
        contentItem: ColumnLayout {
            spacing: 12
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: root.exesTitle
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: c.text
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
                WIconButton { glyph: "✕"; onClicked: exesPopup.close() }
            }
            ListView {
                id: exesList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 6
                delegate: Rectangle {
                    width: exesList.width
                    height: 54
                    radius: 10
                    color: exeMouse.containsMouse ? c.rowHover : c.group
                    MouseArea { id: exeMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 10
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text { text: modelData.name; color: c.text; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                            Text { text: modelData.detail; color: c.dim; font.pixelSize: 11; elide: Text.ElideMiddle; Layout.fillWidth: true }
                        }
                        WAccentButton {
                            text: root.zh ? "加入应用" : "Add"
                            onClicked: {
                                backend.config_from_exe(root.appsPrefix, modelData.path)
                                exesPopup.close()
                            }
                        }
                        WButton {
                            text: root.zh ? "运行" : "Run"
                            onClicked: backend.run_path(modelData.path, root.appsPrefix, "")
                        }
                    }
                }
                ScrollBar.vertical: ScrollBar {}
            }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton { text: root.zh ? "关闭" : "Close"; onClicked: exesPopup.close() }
            }
        }
    }

    // 「添加应用 → 添加 exe 文件」：走运行设置，存进应用列表
    FileDialog {
        id: addExeDialog
        nameFilters: ["Windows 程序 (*.exe)"]
        onAccepted: backend.config_from_exe(root.appsPrefix, selectedFile.toString().replace("file://", ""))
    }

    // 「添加应用 → 直接运行 exe」：装个安装包用，跑完不往列表里塞条目
    FileDialog {
        id: runExeDialog
        nameFilters: ["Windows 程序 (*.exe)"]
        onAccepted: backend.run_path(selectedFile.toString().replace("file://", ""), root.appsPrefix, "")
    }

    // ── 弹层：运行设置 ──────────────────────────────────────
    QtObject {
        id: cfg
        property string file: ""
        property string name: ""
        property string exe: ""
        property string prefix: ""
        property string runner: ""
        property string programArgs: ""
        property bool gamescope: false
        property bool fullscreen: true
        property string res: ""
        property string fps: ""
        property bool fsr: false
        property string args: ""
        property bool mangohud: false
        property bool wayland: false
        property string envVars: ""
        property string steamAppid: ""
    }

    Popup {
        id: configDialog
        modal: true
        Overlay.modal: Rectangle { color: c.dark ? "#99000000" : "#40000000" }
        closePolicy: Popup.CloseOnEscape
        width: 600
        // 弹层挂在 Overlay 上，而 Overlay 不含标题栏（48px），高度要按剩余空间算
        readonly property real available: root.height - 48
        x: Math.round((root.width - width) / 2)
        y: Math.max(8, Math.round((available - height) / 2))
        height: Math.min(root.configureMode ? 724 : 720, available - 8)
        padding: 0
        background: Rectangle { radius: 14; color: c.row; border.width: 1; border.color: c.line }

        function openFor(entry) {
            cfg.exe = entry.exe || ""
            cfg.prefix = entry.prefix || root.appsPrefix
            cfg.runner = entry.runner || ""
            cfg.programArgs = entry.programArgs || ""
            cfg.gamescope = entry.gamescope === true
            cfg.fullscreen = entry.gamescopeFullscreen !== false
            cfg.res = entry.gamescopeRes || ""
            cfg.fps = entry.gamescopeFps || ""
            cfg.fsr = entry.gamescopeFsr === true
            cfg.args = entry.gamescopeArgs || ""
            cfg.mangohud = entry.mangohud === true
            cfg.wayland = entry.wayland === true
            cfg.envVars = entry.envVars || ""
            cfg.file = entry.file || ""
            cfg.name = entry.name || entry.displayName || ""
            cfg.steamAppid = entry.steamAppid || ""
            open()
            Qt.callLater(function () {
                if (cfgRunner) cfgRunner.editText = cfg.runner
                if (cfgRes) cfgRes.editText = cfg.res
                if (cfgFps) cfgFps.editText = cfg.fps
            })
        }
        function collect() {
            return {
                file: cfg.file, name: cfg.name, exe: cfg.exe, prefix: cfg.prefix,
                runner: cfg.runner, programArgs: cfg.programArgs,
                gamescope: cfg.gamescope, gamescopeFullscreen: cfg.fullscreen,
                gamescopeRes: cfg.res, gamescopeFps: cfg.fps, gamescopeFsr: cfg.fsr,
                gamescopeArgs: cfg.args, mangohud: cfg.mangohud,
                wayland: cfg.wayland && !cfg.gamescope, envVars: cfg.envVars,
                steamAppid: cfg.steamAppid, displayName: cfg.name
            }
        }
        function saved() {
            var entry = collect()
            close()
            backend.save_config(entry)
        }
        function cancelled() {
            close()
            if (root.configureMode) Qt.quit()
        }

        contentItem: ColumnLayout {
            spacing: 0

            // ── 头部：这是哪个程序 ──
            Item {
                Layout.fillWidth: true
                implicitHeight: 68

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 20
                    anchors.rightMargin: 12
                    spacing: 12

                    // 程序自己的图标；提不出来才退回首字母
                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: 10
                        color: c.accentSoft
                        clip: true
                        Text {
                            anchors.centerIn: parent
                            visible: cfgIcon.status !== Image.Ready
                            text: (cfg.name || cfg.exe || "?").replace(/^.*[\\/]/, "").charAt(0).toUpperCase()
                            font.pixelSize: 17
                            font.weight: Font.DemiBold
                            color: c.accent
                        }
                        Image {
                            id: cfgIcon
                            anchors.fill: parent
                            anchors.margins: 4
                            source: backend.config_icon ? "file://" + backend.config_icon : ""
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            mipmap: true
                            visible: status === Image.Ready
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Text {
                            Layout.fillWidth: true
                            text: cfg.name !== "" ? cfg.name : (root.zh ? "运行设置" : "Run Settings")
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            color: c.text
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: cfg.exe
                            font.pixelSize: 11
                            color: c.dim
                            elide: Text.ElideMiddle
                        }
                    }

                    WIconButton { glyph: "✕"; onClicked: configDialog.cancelled() }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: c.line }
            }

            // ── 中间：三组设置 ──
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                implicitHeight: 200

                Flickable {
                id: cfgFlick
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: formCol.implicitHeight + 28
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                ColumnLayout {
                    id: formCol
                    x: 20
                    y: 12
                    width: parent.width - 40
                    spacing: 12

                    SettingsCard {
                        title: root.zh ? "常规" : "GENERAL"

                        GridLayout {
                            columns: 2
                            columnSpacing: 10
                            rowSpacing: 8
                            Layout.fillWidth: true
                            Layout.topMargin: 2

                            Text { text: root.zh ? "程序" : "Program"; color: c.dim; font.pixelSize: 12; Layout.preferredWidth: 62 }
                            RowLayout {
                                spacing: 6
                                Layout.fillWidth: true
                                WPathField {
                                    Layout.fillWidth: true
                                    value: cfg.exe
                                    onClicked: exeDialog.open()
                                }
                                WButton { outlined: true; implicitHeight: 32; text: root.zh ? "选择" : "Browse"; onClicked: exeDialog.open() }
                            }

                            Text { text: root.zh ? "名称" : "Name"; color: c.dim; font.pixelSize: 12 }
                            WField {
                                implicitHeight: 32
                                Layout.fillWidth: true
                                text: cfg.name
                                placeholderText: root.zh ? "留空用文件名" : "Defaults to file name"
                                onTextEdited: cfg.name = text
                            }

                            Text { text: root.zh ? "前置环境" : "Prefix"; color: c.dim; font.pixelSize: 12 }
                            RowLayout {
                                spacing: 6
                                Layout.fillWidth: true
                                WPathField {
                                    Layout.fillWidth: true
                                    value: cfg.prefix
                                    onClicked: prefixDialog.open()
                                }
                                WButton { outlined: true; implicitHeight: 32; text: root.zh ? "选择" : "Browse"; onClicked: prefixDialog.open() }
                            }

                            Text { text: root.zh ? "运行器" : "Runner"; color: c.dim; font.pixelSize: 12 }
                            WComboBox {
                                id: cfgRunner
                                implicitHeight: 32
                                Layout.fillWidth: true
                                model: root.runnersModel
                                textRole: "label"
                                onEditTextChanged: cfg.runner = editText
                                onActivated: cfg.runner = editText
                            }

                            Text { text: root.zh ? "启动参数" : "Arguments"; color: c.dim; font.pixelSize: 12 }
                            WField {
                                id: cfgArgs
                                implicitHeight: 32
                                Layout.fillWidth: true
                                placeholderText: root.zh ? "追加在程序后面，如 -dx11" : "Appended to the program path"
                                text: cfg.programArgs
                                onTextEdited: cfg.programArgs = text
                            }
                        }

                        Text {
                            visible: root.runnersModel.length === 0
                            Layout.fillWidth: true
                            text: root.zh
                                  ? "没有找到 Proton / Wine，保存后也启动不了；先在应用页下载一个 WE-Proton。"
                                  : "No Proton / Wine found — download WE-Proton from the Apps page first."
                            color: c.danger
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                        }
                    }

                    SettingsCard {
                        title: "GAMESCOPE"

                        Text {
                            Layout.fillWidth: true
                            Layout.topMargin: 2
                            text: root.zh ? "兼容性不好、或者想全屏缩放时用，游戏会跑在它自己的小窗口里。"
                                          : "Wrap the program in gamescope for scaling or compatibility."
                            color: c.dim
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }

                        RowLayout {
                            spacing: 18
                            WCheckBox {
                                id: cfgGamescope
                                text: root.zh ? "启用" : "Enable"
                                checked: cfg.gamescope
                                onToggled: cfg.gamescope = checked
                            }
                            WCheckBox {
                                id: cfgFullscreen
                                text: root.zh ? "全屏" : "Fullscreen"
                                checked: cfg.fullscreen
                                enabled: cfgGamescope.checked
                                onToggled: cfg.fullscreen = checked
                            }
                            WCheckBox {
                                id: cfgFsr
                                text: "FSR"
                                checked: cfg.fsr
                                enabled: cfgGamescope.checked
                                onToggled: cfg.fsr = checked
                            }
                        }

                        GridLayout {
                            columns: 2
                            columnSpacing: 10
                            rowSpacing: 8
                            Layout.fillWidth: true

                            Text { text: root.zh ? "分辨率" : "Resolution"; color: c.dim; font.pixelSize: 12; Layout.preferredWidth: 62 }
                            WComboBox {
                                id: cfgRes
                                implicitHeight: 32
                                Layout.fillWidth: true
                                model: root.resolutionsModel
                                textRole: "value"
                                enabled: cfgGamescope.checked
                                onEditTextChanged: cfg.res = editText
                                onActivated: cfg.res = editText
                            }

                            Text { text: root.zh ? "帧率上限" : "FPS limit"; color: c.dim; font.pixelSize: 12 }
                            WComboBox {
                                id: cfgFps
                                implicitHeight: 32
                                Layout.fillWidth: true
                                model: root.fpsModel
                                textRole: "value"
                                enabled: cfgGamescope.checked
                                onEditTextChanged: cfg.fps = editText
                                onActivated: cfg.fps = editText
                            }

                            Text { text: root.zh ? "额外参数" : "Extra args"; color: c.dim; font.pixelSize: 12 }
                            WField {
                                implicitHeight: 32
                                Layout.fillWidth: true
                                text: cfg.args
                                enabled: cfgGamescope.checked
                                onTextEdited: cfg.args = text
                            }
                        }
                    }

                    SettingsCard {
                        title: root.zh ? "其他" : "OTHER"

                        WCheckBox {
                            id: cfgMangohud
                            Layout.topMargin: 2
                            text: root.zh ? "MangoHud（显示帧率与占用）" : "MangoHud (FPS and usage)"
                            checked: cfg.mangohud
                            onToggled: cfg.mangohud = checked
                        }

                        WCheckBox {
                            id: cfgWayland
                            text: root.zh ? "以 Wayland 运行" : "Run on Wayland"
                            checked: cfg.wayland
                            enabled: !cfgGamescope.checked
                            onToggled: cfg.wayland = checked
                        }

                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: 27
                            text: root.zh ? "用 Wine 的 Wayland 驱动；开了 Gamescope 就不生效。"
                                          : "Use Wine's Wayland driver; ignored with Gamescope."
                            color: c.faint
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                        }

                        GridLayout {
                            columns: 2
                            columnSpacing: 10
                            Layout.fillWidth: true
                            Text { text: root.zh ? "环境变量" : "Env vars"; color: c.dim; font.pixelSize: 12; Layout.preferredWidth: 62 }
                            WField {
                                id: cfgEnv
                                implicitHeight: 32
                                Layout.fillWidth: true
                                placeholderText: "KEY=VALUE KEY2=VALUE2"
                                text: cfg.envVars
                                onTextEdited: cfg.envVars = text
                            }
                        }
                    }
                }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 34
                    visible: cfgFlick.contentY + cfgFlick.height < cfgFlick.contentHeight - 4
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: c.row }
                    }
                }
            }

            // ── 底部按钮 ──
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: c.line }
            Item {
                Layout.fillWidth: true
                implicitHeight: 62
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 20
                    anchors.rightMargin: 20
                    spacing: 8
                    WButton {
                        visible: root.configureMode
                        outlined: true
                        text: root.zh ? "保存并运行" : "Save & Run"
                        onClicked: {
                            var entry = configDialog.collect()
                            configDialog.close()
                            backend.save_config(entry)
                            backend.run_path(entry.exe, entry.prefix, entry.runner)
                        }
                    }
                    Item { Layout.fillWidth: true }
                    WButton { text: root.zh ? "取消" : "Cancel"; onClicked: configDialog.cancelled() }
                    WAccentButton { text: root.zh ? "保存" : "Save"; onClicked: configDialog.saved() }
                }
            }
        }
    }

    FileDialog {
        id: exeDialog
        nameFilters: ["Windows 程序 (*.exe)"]
        onAccepted: cfg.exe = selectedFile.toString().replace("file://", "")
    }
    FolderDialog {
        id: prefixDialog
        onAccepted: cfg.prefix = selectedFolder.toString().replace("file://", "")
    }
}
