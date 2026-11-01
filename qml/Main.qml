// WinRun 管理器 —— 界面
// 版式参考 macOS 设置：侧栏 + 大标题 + 分组列表 + 右侧按钮；浅色/深色跟随系统
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import WinRun

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
    readonly property string appName: "WinRun"
    readonly property string version: "v" + Qt.application.version
    readonly property var pageNames: [zh ? "应用" : "Apps", zh ? "Linux 程序" : "Linux Apps",
                                       zh ? "进程" : "Processes", zh ? "目录" : "Folders"]
    readonly property var pageKeys: ["apps", "linux", "procs", "dirs"]
    readonly property var pageTitles: [
        zh ? "应用" : "Applications",
        zh ? "Linux 程序" : "Linux Apps",
        zh ? "正在运行的进程" : "Running Processes",
        zh ? "安装目录" : "Install Folders"
    ]
    readonly property var pageSubtitles: [
        zh ? "前缀里登记过的 Windows 程序，可以运行、改设置、看日志。" : "Windows programs registered in this prefix.",
        zh ? "把 Linux 原生程序放进同一个前缀与网络里启动。" : "Start native Linux programs inside the same prefix.",
        zh ? "这个前缀里的 Windows 进程，卡死时强制结束。" : "Windows processes of this prefix.",
        zh ? "前缀里含 exe 的安装文件夹，可以直接生成应用配置。" : "Install folders containing executables."
    ]
    readonly property var searchHints: [
        zh ? "搜索应用" : "Search apps",
        zh ? "搜索程序" : "Search apps",
        zh ? "搜索进程名、PID 或命令行" : "Search name, PID or command",
        zh ? "搜索目录" : "Search folders"
    ]

    // ── 状态 ────────────────────────────────────────────────
    property int currentPage: 0
    property string appsPrefix: ""
    property string linuxPrefix: ""
    property string dirsPrefix: ""
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
    property var searchValues: ["", "", "", ""]
    readonly property var searchKeys: ["appsSearch", "linuxSearch", "procsSearch", "dirsSearch"]

    visible: true
    width: configureMode ? 640 : 1180
    height: configureMode ? 780 : 780
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
            if (paths.indexOf(dirsPrefix) < 0) dirsPrefix = appsPrefix
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

    Shortcut { sequence: "Ctrl+F"; onActivated: pageSearchField.forceActiveFocus() }
    Shortcut { sequence: "Ctrl+1"; onActivated: root.switchPage(0) }
    Shortcut { sequence: "Ctrl+2"; onActivated: root.switchPage(1) }
    Shortcut { sequence: "Ctrl+3"; onActivated: root.switchPage(2) }
    Shortcut { sequence: "Ctrl+4"; onActivated: root.switchPage(3) }

    function switchPage(index) {
        if (configureMode) return
        currentPage = index
        refreshCurrent()
    }

    function currentPrefix() {
        return currentPage === 0 ? appsPrefix : currentPage === 1 ? linuxPrefix
             : currentPage === 2 ? procsPrefix : dirsPrefix
    }

    function setPrefix(value) {
        if (currentPage === 0) appsPrefix = value
        else if (currentPage === 1) linuxPrefix = value
        else if (currentPage === 2) procsPrefix = value
        else dirsPrefix = value
    }

    function refreshCurrent() {
        backend.refresh_page(pageKeys[currentPage], currentPrefix())
    }

    function confirm(title, message, action) {
        pendingConfirm = action
        confirmTitle.text = title
        confirmMessage.text = message
        confirmPopup.open()
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

    // 前缀选择：一个带下拉菜单的按钮
    component PrefixPicker: Button {
        id: picker
        implicitHeight: 34
        implicitWidth: Math.min(300, labelText.implicitWidth + 54)
        ToolTip.visible: hovered
        ToolTip.delay: 600
        ToolTip.text: value
        property var model: backend.prefixes
        property string value: root.currentPrefix()
        background: Rectangle {
            radius: 8
            color: picker.hovered || picker.pressed ? c.rowHover : c.field
            border.width: 1
            border.color: picker.activeFocus ? c.accent : c.fieldLine
        }
        contentItem: Item {
            Text {
                id: labelText
                anchors.left: parent.left
                anchors.leftMargin: 11
                anchors.right: chevron.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: root.prefixLabel(picker.value)
                font.pixelSize: 13
                color: c.text
                elide: Text.ElideRight
            }
            Text {
                id: chevron
                anchors.right: parent.right
                anchors.rightMargin: 11
                anchors.verticalCenter: parent.verticalCenter
                text: "⌄"
                font.pixelSize: 13
                color: c.faint
            }
        }
        onClicked: prefixMenu.popup(picker, 0, picker.height + 6)
        Menu {
            id: prefixMenu
            width: Math.max(320, picker.width)
            padding: 4
            background: Rectangle { radius: 10; color: c.row; border.width: 1; border.color: c.line }
            Instantiator {
                model: picker.model
                delegate: MenuItem {
                    id: prefixItem
                    required property var modelData
                    required property int index
                    height: 32
                    contentItem: Text {
                        leftPadding: 8
                        text: root.prefixLabel(modelData.path)
                        color: prefixItem.highlighted ? "#ffffff" : c.text
                        font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideMiddle
                    }
                    background: Rectangle {
                        radius: 6
                        color: prefixItem.highlighted ? c.accent : "transparent"
                    }
                    onTriggered: {
                        root.setPrefix(modelData.path)
                        root.refreshCurrent()
                    }
                }
                onObjectAdded: (index, object) => prefixMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => prefixMenu.removeItem(object)
            }
        }
    }

    function pageSummary() {
        if (currentPage === 0) {
            var running = 0
            for (var i = 0; i < backend.apps.length; i++) if (backend.apps[i].running) running++
            return backend.apps.length + (zh ? " 个应用" : " apps") + (running > 0 ? (zh ? " · " + running + " 个运行中" : " · " + running + " running") : "")
        }
        if (currentPage === 1) return backend.linux_apps.length + (zh ? " 个程序" : " apps")
        if (currentPage === 2) return backend.procs.length + (zh ? " 个进程" : " processes")
        return backend.dirs.length + (zh ? " 个目录" : " folders")
    }

    function prefixLabel(path) {
        if (!path) return zh ? "没有前缀" : "No prefix"
        var pieces = path.replace(/\/+$/, "").split("/")
        return pieces[pieces.length - 1] || path
    }

    // ── 标题栏：左边红绿灯，中间页面名 ──────────────────────
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
                            if (root.configureMode) Qt.quit(); else root.hide()
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
            CaptionButton {
                kind: "close"
                onClicked: { if (root.configureMode) Qt.quit(); else root.hide() }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: c.line
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
            Layout.preferredWidth: 208
            Layout.fillHeight: true
            color: c.sidebar

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: 16
                anchors.bottomMargin: 14
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 1

                Item { implicitHeight: 8 }

                Repeater {
                    model: root.pageNames.length
                    delegate: AbstractButton {
                        id: navBtn
                        required property int index
                        Layout.fillWidth: true
                        implicitHeight: 32
                        background: Rectangle {
                            radius: 7
                            color: navBtn.index === root.currentPage
                                   ? (c.dark ? "#26282c" : "#e6e6ea")
                                   : (navBtn.hovered ? c.hover : "transparent")
                        }
                        contentItem: Text {
                            leftPadding: 9
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
                DirsPage {}
            }

            // 状态栏
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                color: c.sidebar
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: c.line }
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 8
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
        default property alias trailing: trailingRow.data
        spacing: 8
        PrefixPicker {}
        Item { Layout.fillWidth: true }
        RowLayout { id: trailingRow; spacing: 8 }
        WSearchField {
            id: pageSearchField
            Layout.preferredWidth: 220
            implicitHeight: 34
            placeholderText: root.searchHints[root.currentPage]
            text: root.searchValues[root.currentPage]
            onTextEdited: {
                var copy = root.searchValues.slice()
                copy[root.currentPage] = text
                root.searchValues = copy
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
        property string glyph: "◌"
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
            radius: 9
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

    // ── 页面：应用 ──────────────────────────────────────────
    component AppsPage: Item {
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            PageHeader {
                Layout.fillWidth: true
                WAccentButton {
                    text: root.zh ? "添加应用" : "Add App"
                    onClicked: backend.new_config(root.appsPrefix)
                }
            }

            PageToolbar {
                Layout.fillWidth: true
                WAccentButton {
                    visible: backend.update_available
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

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                GroupList {
                    id: appsList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: Math.min(Math.max(contentHeight, 1) + 2, parent.height)
                    model: {
                        var q = root.searchValues[0].toLowerCase()
                        var source = backend.apps
                        if (q === "") return source
                        var out = []
                        for (var i = 0; i < source.length; i++) {
                            var item = source[i]
                            var hay = (item.name + " " + item.detail + " " + item.path).toLowerCase()
                            if (hay.indexOf(q) >= 0) out.push(item)
                        }
                        return out
                    }
                    delegate: Rectangle {
                        width: appsList.width
                        height: 64
                        color: rowMouse.containsMouse ? c.rowHover : "transparent"

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
                            acceptedButtons: Qt.NoButton
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 12
                            spacing: 12

                            AppIcon {
                                source: modelData.icon && modelData.icon !== "winrun" ? modelData.icon : ""
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
                                    text: modelData.detail
                                    color: c.dim
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    Layout.fillWidth: true
                                }
                            }

                            RowLayout {
                                spacing: 6

                                WButton {
                                    visible: modelData.hasLog
                                    text: root.zh ? "日志" : "Log"
                                    onClicked: {
                                        root.currentLogAppId = modelData.appId
                                        root.logTitle = modelData.name
                                        logTextArea.text = backend.log_text(modelData.appId)
                                        logPopup.open()
                                    }
                                }
                                WDangerButton {
                                    visible: modelData.running
                                    text: root.zh ? "关闭" : "Close"
                                    onClicked: backend.close_app(modelData.appId, root.appsPrefix)
                                }
                                WAccentButton {
                                    visible: !modelData.running
                                    text: root.zh ? "运行" : "Run"
                                    ToolTip.visible: modelData.isSteam && hovered
                                    ToolTip.delay: 400
                                    ToolTip.text: root.zh ? "通过 Steam 启动" : "Start through Steam"
                                    onClicked: {
                                        if (modelData.isSteam && modelData.steamAppid)
                                            backend.run_steam_game(modelData.steamAppid, modelData.path, root.appsPrefix)
                                        else
                                            backend.run_path(modelData.path, root.appsPrefix, modelData.runner)
                                    }
                                }
                                WButton {
                                    visible: modelData.canConfig
                                    text: root.zh ? "设置" : "Settings"
                                    onClicked: backend.open_config(modelData.appId, root.appsPrefix)
                                }
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
                                    delegate: MenuItem {
                                        id: menuItem
                                        height: 32
                                        contentItem: Text {
                                            leftPadding: 8
                                            text: menuItem.text
                                            color: menuItem.highlighted ? "#ffffff" : c.text
                                            font.pixelSize: 13
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            radius: 6
                                            color: menuItem.highlighted ? c.accent : "transparent"
                                        }
                                    }
                                    MenuItem { text: root.zh ? "重命名" : "Rename"
                                        onTriggered: {
                                            renameField.text = modelData.name
                                            root.renameTarget = modelData.appId
                                            renamePopup.open()
                                        }
                                    }
                                    MenuItem { text: root.zh ? "导出到应用列表" : "Export to App List"
                                        onTriggered: backend.export_app(modelData.appId, root.appsPrefix)
                                    }
                                    MenuItem { text: root.zh ? "打开所在目录" : "Open Folder"
                                        onTriggered: {
                                            var p = modelData.path
                                            var cut = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
                                            backend.open_folder(cut > 0 ? p.substring(0, cut) : p)
                                        }
                                    }
                                    MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: c.line } }
                                    MenuItem { text: root.zh ? "删除配置" : "Delete Config"
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
                    glyph: "◫"
                    title: root.zh ? "还没有应用" : "No apps yet"
                    hint: root.zh ? "点“添加应用”，或在“目录”页从一个 exe 生成配置。"
                                  : "Add one, or create it from an executable in Folders."
                    actionText: root.zh ? "添加应用" : "Add App"
                    action: function () { backend.new_config(root.appsPrefix) }
                    visible: appsList.count === 0
                }
            }
        }
    }

    // ── 页面：Linux 程序 ────────────────────────────────────
    component LinuxPage: Item {
        function launchCustom() {
            var cmd = customCmd.text.trim()
            if (cmd === "") return
            customCmd.text = ""
            backend.launch_linux(root.linuxPrefix, cmd)
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            PageHeader { Layout.fillWidth: true }

            PageToolbar {
                Layout.fillWidth: true
                WField {
                    id: customCmd
                    Layout.preferredWidth: 240
                    implicitHeight: 32
                    placeholderText: root.zh ? "自定义命令，如 steam" : "Custom command, e.g. steam"
                    onAccepted: launchCustom()
                }
                WAccentButton {
                    implicitHeight: 32
                    text: root.zh ? "运行命令" : "Run"
                    onClicked: launchCustom()
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
                    model: {
                        var q = root.searchValues[1].toLowerCase()
                        var source = backend.linux_apps
                        if (q === "") return source
                        var out = []
                        for (var i = 0; i < source.length; i++) {
                            var item = source[i]
                            var hay = (item.name + " " + item.id + " " + item.path).toLowerCase()
                            if (hay.indexOf(q) >= 0) out.push(item)
                        }
                        return out
                    }
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
                                    text: modelData.path
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
                    glyph: "⌗"
                    title: root.zh ? "没有可启动的程序" : "No launchable apps"
                    hint: root.zh ? "系统里的 .desktop 程序会出现在这里。" : "Applications from .desktop files show up here."
                    visible: linuxList.count === 0
                }
            }
        }
    }

    // ── 页面：进程 ──────────────────────────────────────────
    component ProcsPage: Item {
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            PageHeader { Layout.fillWidth: true }

            PageToolbar {
                Layout.fillWidth: true
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
                    model: {
                        var q = root.searchValues[2].toLowerCase()
                        var source = backend.procs
                        if (q === "") return source
                        var out = []
                        for (var i = 0; i < source.length; i++) {
                            var item = source[i]
                            var hay = (item.title + " " + item.command).toLowerCase()
                            if (hay.indexOf(q) >= 0) out.push(item)
                        }
                        return out
                    }
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
                    glyph: "◔"
                    title: root.zh ? "没有运行中的进程" : "Nothing running"
                    hint: root.zh ? "这个前缀里的 Windows 程序都没在跑。" : "No Windows programs are running in this prefix."
                    visible: procsList.count === 0
                }
            }
        }
    }

    // ── 页面：目录 ──────────────────────────────────────────
    component DirsPage: Item {
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            PageHeader { Layout.fillWidth: true }
            PageToolbar { Layout.fillWidth: true }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                GroupList {
                    id: dirsList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: Math.min(Math.max(contentHeight, 1) + 2, parent.height)
                    model: {
                        var q = root.searchValues[3].toLowerCase()
                        var source = backend.dirs
                        if (q === "") return source
                        var out = []
                        for (var i = 0; i < source.length; i++) {
                            var item = source[i]
                            var hay = (item.name + " " + item.detail + " " + item.path).toLowerCase()
                            if (hay.indexOf(q) >= 0) out.push(item)
                        }
                        return out
                    }
                    delegate: Rectangle {
                        width: dirsList.width
                        height: 62
                        color: dirsMouse.containsMouse ? c.rowHover : "transparent"
                        Rectangle {
                            anchors.bottom: parent.bottom
                            x: 62
                            width: parent.width - 62
                            height: 1
                            color: c.line
                            visible: index < dirsList.count - 1
                        }
                        MouseArea { id: dirsMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 12
                            spacing: 12
                            Rectangle {
                                width: 36; height: 36; radius: 9
                                color: c.group
                                border.width: 1
                                border.color: c.line
                                Text {
                                    anchors.centerIn: parent
                                    text: "▤"
                                    font.pixelSize: 16
                                    color: c.faint
                                }
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
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    Layout.fillWidth: true
                                }
                            }
                            RowLayout {
                                spacing: 6
                                WAccentButton {
                                    text: root.zh ? "查看 exe" : "Executables"
                                    onClicked: backend.show_dir_exes(root.dirsPrefix, modelData.path)
                                }
                                WButton {
                                    text: root.zh ? "打开" : "Open"
                                    onClicked: backend.open_folder(modelData.path)
                                }
                                WDangerButton {
                                    visible: modelData.canDelete
                                    text: root.zh ? "删除" : "Delete"
                                    onClicked: root.confirm(root.zh ? "删除安装目录" : "Delete Folder",
                                        (root.zh ? "将永久删除以下目录及其中所有文件：\n\n" : "This deletes the folder and everything inside:\n\n")
                                        + modelData.path
                                        + (root.zh ? "\n\n不会运行 Windows 卸载程序，可能留下注册表和配置残留。"
                                                   : "\n\nThis does not run the Windows uninstaller."),
                                        function () { backend.delete_install_dir(modelData.path) })
                                }
                            }
                        }
                    }
                }
                EmptyState {
                    glyph: "▤"
                    title: root.zh ? "没有找到安装目录" : "No install folders"
                    hint: root.zh ? "前缀里还没有含 exe 的目录。" : "No folder in this prefix contains executables."
                    visible: dirsList.count === 0
                }
            }
        }
    }

    // ── 弹层：确认 ──────────────────────────────────────────
    Popup {
        id: confirmPopup
        modal: true
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

    // ── 弹层：目录里的 exe ──────────────────────────────────
    Popup {
        id: exesPopup
        modal: true
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
                                backend.config_from_exe(root.dirsPrefix, modelData.path)
                                exesPopup.close()
                            }
                        }
                        WButton {
                            text: root.zh ? "运行" : "Run"
                            onClicked: backend.run_path(modelData.path, root.dirsPrefix, "")
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
        closePolicy: Popup.CloseOnEscape
        width: 600
        // 弹层挂在 Overlay 上，而 Overlay 不含标题栏（48px），高度要按剩余空间算
        readonly property real available: root.height - 48
        x: Math.round((root.width - width) / 2)
        y: Math.max(8, Math.round((available - height) / 2))
        height: Math.min(root.configureMode ? 700 : 720, available - 24)
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

                    Rectangle {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        radius: 9
                        color: c.accentSoft
                        Text {
                            anchors.centerIn: parent
                            text: (cfg.name || cfg.exe || "?").replace(/^.*[\\/]/, "").charAt(0).toUpperCase()
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            color: c.accent
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
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: formCol.implicitHeight + 32
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                ColumnLayout {
                    id: formCol
                    x: 20
                    y: 16
                    width: parent.width - 40
                    spacing: 14

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
