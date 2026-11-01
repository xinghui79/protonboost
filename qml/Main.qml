// WinRun 管理器主窗口：自绘标题栏 + 侧栏 + 四页面 + 状态栏 + 弹层
// 修改本文件后直接 cargo build 即可，build.rs 会保证重新链接
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import WinRun

ApplicationWindow {
    id: root

    // ── 主题 ────────────────────────────────────────────────
    readonly property QtObject c: QtObject {
        readonly property color accent: "#6366f1"
        readonly property color accentHover: "#737af2"
        readonly property bool dark: Qt.styleHints.colorScheme === Qt.Dark
        readonly property color windowBg: dark ? "#1e1f24" : "#f5f5f7"
        readonly property color sidebarBg: dark ? "#232429" : "#ececed"
        readonly property color cardBg: dark ? "#2b2c33" : "#ffffff"
        readonly property color cardBgHover: dark ? "#33343c" : "#fafafa"
        readonly property color cardBorder: dark ? "#3a3b43" : "#e2e2e5"
        readonly property color fieldBg: dark ? "#26272d" : "#ffffff"
        readonly property color fieldBorder: dark ? "#3d3e46" : "#d8d8dc"
        readonly property color text: dark ? "#f2f2f4" : "#1d1d1f"
        readonly property color textDim: dark ? "#9a9aa2" : "#6e6e73"
        readonly property color hover: dark ? "#14ffffff" : "#0a000000"
        readonly property color danger: "#e5484d"
        readonly property color separator: dark ? "#14ffffff" : "#14000000"
    }

    // ── 文案 ────────────────────────────────────────────────
    readonly property bool zh: backend.zh
    readonly property string tTitle: zh ? "WinRun 管理器" : "WinRun Manager"
    readonly property var pageNames: [zh ? "应用" : "Apps", zh ? "Linux 程序" : "Linux Apps",
                                       zh ? "进程" : "Processes", zh ? "目录" : "Folders"]
    readonly property int pageCount: 4
    readonly property var pageKeys: ["apps", "linux", "procs", "dirs"]
    readonly property var searchHints: [
        zh ? "搜索应用（Ctrl+F）" : "Search apps (Ctrl+F)",
        zh ? "搜索 Linux 程序 (Ctrl+F)" : "Search Linux apps (Ctrl+F)",
        zh ? "搜索进程名、PID 或命令行（Ctrl+F）" : "Search name, PID or command line (Ctrl+F)",
        zh ? "搜索目录（Ctrl+F）" : "Search folders (Ctrl+F)"
    ]
    readonly property var pageDescs: [
        "",
        zh ? "在当前前置环境里启动 Linux 原生程序；前置环境开了独立网络时会与加速器同网络"
           : "Launch native Linux apps in the selected prefix; joins the independent network when enabled",
        zh ? "强制结束运行中的 Windows 程序进程，程序卡死时用。"
           : "Force close running Windows program processes.",
        zh ? "前缀里 Windows 程序的安装文件夹；选中里面的 exe 可以创建应用配置。"
           : "Install folders inside the prefix; pick an exe to create an app config."
    ]

    // ── 状态 ────────────────────────────────────────────────
    property int currentPage: 0
    property string appsPrefix: ""
    property string linuxPrefix: ""
    property string dirsPrefix: ""
    property string procsPrefix: ""
    property bool configureMode: backend.startup_exe() !== ""
    property var runnersModel: []
    property var resolutionsModel: []
    property var fpsModel: []
    property var editEntry: ({})
    property var pendingConfirm: null
    property string exesTitle: ""
    property string renameTarget: ""
    property string currentLogAppId: ""
    property string appsSearch: ""
    property string linuxSearch: ""
    property string procsSearch: ""
    property string dirsSearch: ""
    readonly property var searchKeys: ["appsSearch", "linuxSearch", "procsSearch", "dirsSearch"]

    visible: true
    width: configureMode ? 620 : 1120
    height: configureMode ? 720 : 740
    minimumWidth: configureMode ? 560 : 880
    minimumHeight: configureMode ? 620 : 560
    color: c.windowBg
    flags: Qt.Window | Qt.FramelessWindowHint
    title: tTitle

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
                        root.show()
                        root.raise()
                    } else if (root.visible) {
                        root.hide()
                    } else {
                        root.show()
                        root.raise()
                        refreshCurrent()
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

    Shortcut {
        sequence: "Ctrl+F"
        onActivated: pageSearch.focus = true
    }

    function refreshCurrent() {
        var prefix = currentPage === 0 ? appsPrefix : currentPage === 1 ? linuxPrefix
                   : currentPage === 2 ? procsPrefix : dirsPrefix
        backend.refresh_page(pageKeys[currentPage], prefix)
    }

    function refreshAll() {
        backend.refresh_page("apps", appsPrefix)
        backend.refresh_page("linux", linuxPrefix)
        backend.refresh_page("procs", procsPrefix)
        backend.refresh_page("dirs", dirsPrefix)
    }

    function confirm(title, message, action) {
        pendingConfirm = action
        confirmTitle.text = title
        confirmMessage.text = message
        confirmPopup.open()
    }

    // ── 通用控件 ────────────────────────────────────────────
    component WButton: Button {
        id: wb
        implicitHeight: 32
        padding: 12
        background: Rectangle {
            radius: 7
            color: wb.pressed ? c.separator : (wb.hovered ? c.hover : "transparent")
            border.width: 1
            border.color: c.fieldBorder
        }
        contentItem: Text {
            text: wb.text
            font.pixelSize: 12
            color: wb.enabled ? c.text : c.textDim
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component WAccentButton: Button {
        id: wab
        implicitHeight: 32
        padding: 14
        background: Rectangle {
            radius: 7
            color: !wab.enabled ? c.textDim : (wab.pressed || wab.hovered ? c.accentHover : c.accent)
        }
        contentItem: Text {
            text: wab.text
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: "#ffffff"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component WDangerButton: Button {
        id: wdb
        implicitHeight: 32
        padding: 12
        background: Rectangle {
            radius: 7
            color: wdb.hovered || wdb.pressed ? c.danger : "transparent"
            border.width: 1
            border.color: wdb.hovered || wdb.pressed ? c.danger : c.fieldBorder
        }
        contentItem: Text {
            text: wdb.text
            font.pixelSize: 12
            color: wdb.hovered || wdb.pressed ? "#ffffff" : c.danger
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component WCheckBox: CheckBox {
        id: wcbx
        implicitHeight: 26
        spacing: 8
        indicator: Rectangle {
            implicitWidth: 18
            implicitHeight: 18
            x: wcbx.leftPadding
            y: (wcbx.height - height) / 2
            radius: 5
            color: wcbx.checked ? (wcbx.enabled ? c.accent : c.textDim) : "transparent"
            border.width: 1
            border.color: wcbx.checked ? (wcbx.enabled ? c.accent : c.textDim) : c.fieldBorder
            Text {
                anchors.centerIn: parent
                visible: wcbx.checked
                text: "✓"
                color: "#ffffff"
                font.pixelSize: 11
                font.weight: Font.Bold
            }
        }
        contentItem: Text {
            text: wcbx.text
            leftPadding: wcbx.indicator.width + wcbx.spacing
            font.pixelSize: 12
            color: wcbx.enabled ? c.text : c.textDim
            verticalAlignment: Text.AlignVCenter
        }
    }

    component WField: TextField {
        id: wf
        implicitHeight: 34
        opacity: enabled ? 1 : 0.55
        color: c.text
        placeholderTextColor: c.textDim
        selectByMouse: true
        background: Rectangle {
            radius: 7
            color: c.fieldBg
            border.width: 1
            border.color: wf.activeFocus ? c.accent : c.fieldBorder
        }
    }

    component WComboBox: ComboBox {
        id: wcb
        implicitHeight: 34
        font.pixelSize: 12
        opacity: enabled ? 1 : 0.55
        editable: true
        background: Rectangle {
            radius: 7
            color: c.fieldBg
            border.width: 1
            border.color: wcb.activeFocus ? c.accent : c.fieldBorder
        }
        contentItem: TextInput {
            text: wcb.editText
            font.pixelSize: 12
            color: c.text
            selectionColor: c.accent
            verticalAlignment: Text.AlignVCenter
            leftPadding: 10
            rightPadding: wcb.indicator.width + 6
            selectByMouse: true
            onTextEdited: wcb.editText = text
            onAccepted: wcb.activate()
        }
        indicator: Canvas {
            x: wcb.width - width - 10
            y: (wcb.height - height) / 2
            width: 10
            height: 6
            onPaint: {
                var ctx = getContext("2d")
                ctx.strokeStyle = c.textDim
                ctx.lineWidth = 1.6
                ctx.beginPath()
                ctx.moveTo(0, 0)
                ctx.lineTo(5, 5)
                ctx.lineTo(10, 0)
                ctx.stroke()
            }
        }
        delegate: ItemDelegate {
            id: wcbItem
            required property var modelData
            required property int index
            width: wcb.width
            contentItem: Text {
                text: wcb.textRole !== "" && wcbItem.modelData ? wcbItem.modelData[wcb.textRole] : wcbItem.modelData
                color: wcbItem.highlighted ? "#ffffff" : c.text
                font.pixelSize: 12
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideMiddle
            }
            highlighted: wcb.highlightedIndex === wcbItem.index
            background: Rectangle { color: wcbItem.highlighted ? c.accent : "transparent"; radius: 6 }
        }
        popup: Popup {
            y: wcb.height + 4
            width: wcb.width
            padding: 4
            background: Rectangle {
                radius: 10
                color: c.cardBg
                border.width: 1
                border.color: c.cardBorder
            }
            contentItem: ListView {
                clip: true
                implicitHeight: Math.min(contentHeight, 320)
                model: wcb.popup.visible ? wcb.delegateModel : null
                currentIndex: wcb.highlightedIndex
            }
        }
        function activate() {
            // 可编辑组合框确认输入：视图是 {value:{...}} 时取对应字段
            if (typeof currentValue !== "undefined" && currentValue !== null) {
                activated(currentIndex)
            }
        }
    }

    component PrefixSelector: RowLayout {
        id: ps
        property string page: "apps"
        spacing: 8
        WComboBox {
            id: combo
            Layout.fillWidth: true
            model: ps.page === "procs" ? backend.processPrefixes : backend.prefixes
            textRole: ps.page === "procs" ? "label" : "path"
            Component.onCompleted: {
                if (ps.page === "procs") {
                    if (backend.processPrefixes.length) {
                        editText = backend.processPrefixes[0].label
                        root.procsPrefix = backend.processPrefixes[0].path
                    }
                } else if (backend.prefixes.length) {
                    editText = backend.prefixes[0].path
                    if (ps.page === "apps") root.appsPrefix = editText
                    else if (ps.page === "linux") root.linuxPrefix = editText
                    else root.dirsPrefix = editText
                }
            }
            onAccepted: apply()
            onActivated: apply()
            function apply() {
                if (ps.page === "procs") {
                    for (var i = 0; i < backend.processPrefixes.length; i++) {
                        if (backend.processPrefixes[i].label === editText) root.procsPrefix = backend.processPrefixes[i].path
                    }
                } else if (ps.page === "apps") {
                    root.appsPrefix = editText
                } else if (ps.page === "linux") {
                    root.linuxPrefix = editText
                } else {
                    root.dirsPrefix = editText
                }
                root.refreshCurrent()
            }
        }
        Button {
            implicitWidth: 32
            implicitHeight: 32
            background: Rectangle { radius: 7; color: parent.hovered ? c.hover : "transparent" }
            contentItem: Text { text: "⌂"; color: c.textDim; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            ToolTip.visible: hovered
            ToolTip.delay: 500
            ToolTip.text: zh ? "打开前置环境目录" : "Open Prefix Folder"
            onClicked: backend.open_folder(ps.page === "procs" ? root.procsPrefix
                                          : ps.page === "apps" ? root.appsPrefix
                                          : ps.page === "linux" ? root.linuxPrefix : root.dirsPrefix)
        }
        Button {
            implicitWidth: 32
            implicitHeight: 32
            visible: ps.page !== "procs"
            background: Rectangle { radius: 7; color: parent.hovered ? c.hover : "transparent" }
            contentItem: Text { text: "✕"; color: c.danger; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            ToolTip.visible: hovered
            ToolTip.delay: 500
            ToolTip.text: zh ? "删除前置环境" : "Delete Prefix"
            onClicked: {
                var path = ps.page === "apps" ? root.appsPrefix : ps.page === "linux" ? root.linuxPrefix : root.dirsPrefix
                root.confirm(zh ? "删除前置环境" : "Delete Prefix",
                    (zh ? "将永久删除以下前置环境及其中所有文件：\n\n"
                        : "This will permanently delete this prefix and all files inside:\n\n") + path
                    + (zh ? "\n\n请确认该前置环境内没有需要保留的存档、配置或用户数据。是否继续？"
                          : "\n\nMake sure there are no saves or user data you want to keep. Continue?"),
                    function () { backend.delete_prefix(path) })
            }
        }
    }

    // ── 标题栏 ──────────────────────────────────────────────
    header: ToolBar {
        background: Rectangle {
            color: c.sidebarBg
            MouseArea {
                anchors.fill: parent
                onPressed: root.startSystemMove()
                onDoubleClicked: root.toggleMaximized()
            }
        }
        contentItem: RowLayout {
            spacing: 8
            Item { Layout.preferredWidth: 6 }
            Label {
                text: tTitle
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: c.text
            }
            Item { Layout.fillWidth: true }
            component WinButton: AbstractButton {
                id: winBtn
                property string glyph: ""
                property color hoverColor: c.hover
                implicitWidth: 34
                implicitHeight: 26
                background: Rectangle {
                    radius: 6
                    color: winBtn.pressed ? c.separator : (winBtn.hovered ? winBtn.hoverColor : "transparent")
                }
                contentItem: Text {
                    text: winBtn.glyph
                    font.pixelSize: 11
                    color: winBtn.hovered && winBtn.hoverColor === c.danger ? "#ffffff" : c.textDim
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            WinButton { glyph: "—"; onClicked: root.showMinimized() }
            WinButton { glyph: "▢"; onClicked: root.toggleMaximized() }
            WinButton {
                glyph: "✕"
                hoverColor: c.danger
                onClicked: {
                    if (configureMode) Qt.quit()
                    else root.hide()
                }
            }
            Item { Layout.preferredWidth: 8 }
        }
    }

    function toggleMaximized() {
        if (root.visibility === Window.Maximized) root.showNormal()
        else root.showMaximized()
    }

    // ── 主体 ────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        visible: !configureMode

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // 侧栏
            Rectangle {
                Layout.preferredWidth: 190
                Layout.fillHeight: true
                color: c.sidebarBg

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 14
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 4

                    Repeater {
                        model: root.pageCount
                        delegate: AbstractButton {
                            id: navBtn
                            required property int index
                            Layout.fillWidth: true
                            implicitHeight: 36
                            background: Rectangle {
                                radius: 8
                                color: navBtn.index === root.currentPage
                                       ? c.accent : (navBtn.hovered ? c.hover : "transparent")
                            }
                            contentItem: Text {
                                leftPadding: 12
                                text: root.pageNames[navBtn.index]
                                color: navBtn.index === root.currentPage ? "#ffffff" : c.text
                                font.pixelSize: 13
                                font.weight: navBtn.index === root.currentPage ? Font.DemiBold : Font.Normal
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: {
                                root.currentPage = navBtn.index
                                root.refreshCurrent()
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }

            Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: c.separator }

            // 页面区
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
        }

        // 状态栏
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            color: c.sidebarBg
            Label {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: backend.status
                color: c.textDim
                font.pixelSize: 12
                elide: Text.ElideMiddle
            }
        }
    }

    // ── 页面公共骨架：描述 + 前缀选择 + 搜索 ─────────────────
    component PageChrome: ColumnLayout {
        property string searchKey: "appsSearch"
        spacing: 10
        Label {
            visible: text !== ""
            text: root.pageDescs[root.currentPage]
            color: c.textDim
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
        }
        RowLayout {
            spacing: 8
            Layout.topMargin: 14
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            PrefixSelector { page: root.pageKeys[root.currentPage] }
            Item { Layout.fillWidth: true }
        }
        RowLayout {
            spacing: 8
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            WField {
                id: pageSearch
                Layout.fillWidth: true
                placeholderText: root.searchHints[root.currentPage]
                text: root[root.searchKeys[root.currentPage]]
                onTextEdited: root[root.searchKeys[root.currentPage]] = text
            }
        }
    }

    component EmptyLabel: Label {
        property var listRef
        text: zh ? "没有匹配的结果。" : "No matches."
        color: c.textDim
        font.pixelSize: 12
        horizontalAlignment: Text.AlignHCenter
        anchors.centerIn: parent
        visible: listRef ? listRef.count === 0 : false
    }

    // ── 页面：应用 ──────────────────────────────────────────
    component AppsPage: Item {
        ColumnLayout {
            anchors.fill: parent
            spacing: 10

            PageChrome {}

            RowLayout {
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: 8
                WButton {
                    text: zh ? "添加配置" : "Add Config"
                    onClicked: backend.new_config(root.appsPrefix)
                }
                WAccentButton {
                    visible: backend.update_available
                    text: zh ? "有更新可用" : "Update Available"
                    ToolTip.visible: hovered
                    ToolTip.delay: 300
                    ToolTip.text: backend.update_details
                    onClicked: root.confirm(zh ? "更新运行器" : "Update Runners",
                        (zh ? "以下运行器有新版本可用，是否立即更新？\n\n" : "Updates are available for the following runners. Update now?\n\n")
                        + backend.update_details,
                        function () { backend.update_runners_now() })
                }
                Item { Layout.fillWidth: true }
            }

            ListView {
                id: appsList
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 14
                clip: true
                spacing: 8
                model: {
                    var q = root.appsSearch.toLowerCase()
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
                    height: 62
                    radius: 10
                    color: rowMouse.containsMouse ? c.cardBgHover : c.cardBg
                    border.width: 1
                    border.color: c.cardBorder

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 10

                        Item {
                            Layout.preferredWidth: 34
                            Layout.preferredHeight: 34
                            Image {
                                anchors.fill: parent
                                source: modelData.icon && modelData.icon !== "winrun" ? "file://" + modelData.icon : ""
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                mipmap: true
                            }
                            Text {
                                anchors.centerIn: parent
                                text: "⊞"
                                font.pixelSize: 18
                                color: c.textDim
                                visible: !modelData.icon || modelData.icon === "winrun"
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                Layout.fillWidth: true
                                text: modelData.name
                                color: c.text
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.fillWidth: true
                                text: modelData.detail
                                color: modelData.running ? c.accent : c.textDim
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                            }
                        }

                        WButton {
                            visible: modelData.hasLog
                            text: zh ? "日志" : "Log"
                            onClicked: {
                                root.currentLogAppId = modelData.appId
                                root.logTitle = modelData.name
                                logTextArea.text = backend.log_text(modelData.appId)
                                logPopup.open()
                            }
                        }
                        WDangerButton {
                            visible: modelData.running
                            text: zh ? "关闭" : "Close"
                            onClicked: backend.close_app(modelData.appId, root.appsPrefix)
                        }
                        WAccentButton {
                            visible: !modelData.running
                            text: zh ? "运行" : "Run"
                            ToolTip.visible: modelData.isSteam && hovered
                            ToolTip.delay: 400
                            ToolTip.text: zh ? "通过 Steam 启动" : "Start through Steam"
                            onClicked: {
                                if (modelData.isSteam && modelData.steamAppid)
                                    backend.run_steam_game(modelData.steamAppid, modelData.path, root.appsPrefix)
                                else
                                    backend.run_path(modelData.path, root.appsPrefix, modelData.runner)
                            }
                        }
                        WButton {
                            visible: modelData.canConfig
                            text: zh ? "配置" : "Config"
                            onClicked: backend.open_config(modelData.appId, root.appsPrefix)
                        }

                        Button {
                            id: moreBtn
                            implicitWidth: 28
                            implicitHeight: 28
                            background: Rectangle { radius: 6; color: moreBtn.hovered ? c.hover : "transparent" }
                            contentItem: Text { text: "⋯"; color: c.textDim; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            onClicked: appMenu.popup(moreBtn, 0, moreBtn.height + 2)
                            Menu {
                                id: appMenu
                                width: 190
                                background: Rectangle { radius: 10; color: c.cardBg; border.width: 1; border.color: c.cardBorder }
                                delegate: MenuItem {
                                    id: menuItem
                                    height: 34
                                    leftPadding: 12
                                    contentItem: Text {
                                        text: menuItem.text
                                        color: c.text
                                        font.pixelSize: 12
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    background: Rectangle {
                                        radius: 6
                                        color: menuItem.highlighted || menuItem.hovered ? c.hover : "transparent"
                                        anchors.margins: 2
                                    }
                                }
                                MenuItem { text: zh ? "重命名" : "Rename"
                                    onTriggered: {
                                        renameField.text = modelData.name
                                        root.renameTarget = modelData.appId
                                        renamePopup.open()
                                    }
                                }
                                MenuItem { text: zh ? "导出到应用列表" : "Export to App List"
                                    onTriggered: backend.export_app(modelData.appId, root.appsPrefix)
                                }
                                MenuItem { text: zh ? "打开目录" : "Open Folder"
                                    onTriggered: {
                                        var p = modelData.path
                                        var cut = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"))
                                        backend.open_folder(cut > 0 ? p.substring(0, cut) : p)
                                    }
                                }
                                MenuSeparator { contentItem: Rectangle { implicitHeight: 1; color: c.separator } }
                                MenuItem { text: zh ? "删除缓存" : "Delete Cache"
                                    onTriggered: root.confirm(zh ? "删除缓存" : "Delete Cache",
                                        zh ? "删除此应用保存的配置？"
                                          : "Delete this app's saved config?",
                                        function () { backend.delete_app(modelData.appId, root.appsPrefix) })
                                }
                            }
                        }
                    }
                }
                EmptyLabel { listRef: appsList }
                ScrollBar.vertical: ScrollBar {}
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
            spacing: 10

            PageChrome {}

            RowLayout {
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: 8
                WField {
                    id: customCmd
                    Layout.preferredWidth: 320
                    placeholderText: zh ? "自定义命令，如 steam" : "Custom command, e.g. steam"
                    onAccepted: launchCustom()
                }
                WAccentButton {
                    text: zh ? "运行" : "Run"
                    onClicked: launchCustom()
                }
                Item { Layout.fillWidth: true }
            }

            ListView {
                id: linuxList
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 14
                clip: true
                spacing: 8
                model: {
                    var q = root[root.searchKeys[root.currentPage]].toLowerCase()
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
                    height: 56
                    radius: 10
                    color: linuxMouse.containsMouse ? c.cardBgHover : c.cardBg
                    border.width: 1
                    border.color: c.cardBorder
                    MouseArea { id: linuxMouse; anchors.fill: parent; hoverEnabled: true }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 10
                        Item {
                            Layout.preferredWidth: 32
                            Layout.preferredHeight: 32
                            Image {
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectFit
                                mipmap: true
                                source: {
                                    var icon = modelData.icon
                                    if (!icon) return ""
                                    if (icon.indexOf("/") === 0) return "file://" + icon
                                    return "image://theme/" + icon
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                Layout.fillWidth: true
                                text: modelData.name
                                color: c.text
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.fillWidth: true
                                text: modelData.path
                                color: c.textDim
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                            }
                        }
                        WAccentButton {
                            text: zh ? "运行" : "Run"
                            onClicked: backend.launch_desktop(root.linuxPrefix, modelData.path, modelData.name)
                        }
                    }
                }
                EmptyLabel {
                    listRef: linuxList
                    text: zh ? "没有可启动的 Linux 程序" : "No launchable Linux apps"
                }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }

    // ── 页面：进程 ──────────────────────────────────────────
    component ProcsPage: Item {
        ColumnLayout {
            anchors.fill: parent
            spacing: 10

            PageChrome {}

            RowLayout {
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: 8
                WButton {
                    text: zh ? "刷新" : "Refresh"
                    onClicked: root.refreshCurrent()
                }
                WDangerButton {
                    text: zh ? "强制关闭所有进程" : "Force Close All Processes"
                    onClicked: backend.kill_all_processes(root.procsPrefix)
                }
                Item { Layout.fillWidth: true }
            }

            ListView {
                id: procsList
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 14
                clip: true
                spacing: 8
                model: {
                    var q = root[root.searchKeys[root.currentPage]].toLowerCase()
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
                    height: 56
                    radius: 10
                    color: procsMouse.containsMouse ? c.cardBgHover : c.cardBg
                    border.width: 1
                    border.color: c.cardBorder
                    MouseArea { id: procsMouse; anchors.fill: parent; hoverEnabled: true }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 10
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                Layout.fillWidth: true
                                text: modelData.title
                                color: c.text
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.fillWidth: true
                                text: modelData.command
                                color: c.textDim
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                            }
                        }
                        WDangerButton {
                            text: zh ? "强制关闭" : "Force Close"
                            onClicked: backend.kill_proc(modelData.pid, true)
                        }
                    }
                }
                EmptyLabel {
                    listRef: procsList
                    text: zh ? "没有找到该前置环境的运行进程。" : "No processes found for this prefix."
                }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }

    // ── 页面：目录 ──────────────────────────────────────────
    component DirsPage: Item {
        ColumnLayout {
            anchors.fill: parent
            spacing: 10

            PageChrome {}

            ListView {
                id: dirsList
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 14
                clip: true
                spacing: 8
                model: {
                    var q = root[root.searchKeys[root.currentPage]].toLowerCase()
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
                    height: 56
                    radius: 10
                    color: dirsMouse.containsMouse ? c.cardBgHover : c.cardBg
                    border.width: 1
                    border.color: c.cardBorder
                    MouseArea { id: dirsMouse; anchors.fill: parent; hoverEnabled: true }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 10
                        Text {
                            text: "🗂"
                            font.pixelSize: 20
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                Layout.fillWidth: true
                                text: modelData.name
                                color: c.text
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.fillWidth: true
                                text: modelData.detail
                                color: c.textDim
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                            }
                        }
                        WAccentButton {
                            text: zh ? "应用列表" : "App List"
                            onClicked: backend.show_dir_exes(root.dirsPrefix, modelData.path)
                        }
                        WButton {
                            text: zh ? "打开目录" : "Open Folder"
                            onClicked: backend.open_folder(modelData.path)
                        }
                        WDangerButton {
                            visible: modelData.canDelete
                            text: zh ? "删除目录" : "Delete Folder"
                            onClicked: root.confirm(zh ? "删除安装目录" : "Delete Install Folder",
                                (zh ? "将永久删除以下目录及其中所有文件：\n\n"
                                    : "This will permanently delete this folder and all files inside:\n\n")
                                + modelData.path
                                + (zh ? "\n\n这不会运行 Windows 卸载程序，可能留下注册表、快捷方式和配置残留。是否继续？"
                                      : "\n\nThis will not run the Windows uninstaller. Continue?"),
                                function () { backend.delete_install_dir(modelData.path) })
                        }
                    }
                }
                EmptyLabel {
                    listRef: dirsList
                    text: zh ? "没有找到包含 exe 的安装目录。" : "No install folders with executables found."
                }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }

    // ── 弹层：确认 ──────────────────────────────────────────
    property string logTitle: ""

    Popup {
        id: confirmPopup
        modal: true
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 440
        padding: 18
        background: Rectangle { radius: 12; color: c.cardBg; border.width: 1; border.color: c.cardBorder }
        contentItem: ColumnLayout {
            spacing: 12
            Label { id: confirmTitle; font.pixelSize: 14; font.weight: Font.DemiBold; color: c.text; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Label {
                id: confirmMessage
                font.pixelSize: 12
                color: c.textDim
                wrapMode: Text.WrapAnywhere
                Layout.fillWidth: true
            }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton { text: zh ? "取消" : "Cancel"; onClicked: confirmPopup.close() }
                WDangerButton {
                    text: zh ? "确定" : "OK"
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
        width: 380
        padding: 18
        background: Rectangle { radius: 12; color: c.cardBg; border.width: 1; border.color: c.cardBorder }
        contentItem: ColumnLayout {
            spacing: 12
            Label { text: zh ? "重命名" : "Rename"; font.pixelSize: 14; font.weight: Font.DemiBold; color: c.text }
            Label { text: zh ? "显示名称" : "Display name"; font.pixelSize: 12; color: c.textDim }
            WField { id: renameField; Layout.fillWidth: true; onAccepted: renamePopup.save() }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton { text: zh ? "取消" : "Cancel"; onClicked: renamePopup.close() }
                WAccentButton { text: zh ? "保存" : "Save"; onClicked: renamePopup.save() }
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
        width: 860
        height: 600
        padding: 14
        background: Rectangle { radius: 12; color: c.cardBg; border.width: 1; border.color: c.cardBorder }
        contentItem: ColumnLayout {
            spacing: 10
            Label {
                text: (zh ? "日志 · " : "Log · ") + root.logTitle
                font.pixelSize: 14
                font.weight: Font.DemiBold
                color: c.text
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 8
                color: c.fieldBg
                border.width: 1
                border.color: c.fieldBorder
                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 8
                    TextArea {
                        id: logTextArea
                        readOnly: true
                        wrapMode: TextArea.NoWrap
                        font.family: "monospace"
                        font.pixelSize: 11
                        color: c.text
                    }
                }
            }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton {
                    text: zh ? "刷新" : "Refresh"
                    onClicked: logTextArea.text = backend.log_text(root.currentLogAppId)
                }
                WButton {
                    text: zh ? "打开日志目录" : "Open Log Directory"
                    onClicked: backend.open_folder(backend.log_dir(root.currentLogAppId))
                }
                WAccentButton { text: zh ? "完成" : "Done"; onClicked: logPopup.close() }
            }
        }
    }

    // ── 弹层：目录里的 exe ──────────────────────────────────
    Popup {
        id: exesPopup
        modal: true
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: Overlay.overlay
        width: 760
        height: 560
        padding: 14
        background: Rectangle { radius: 12; color: c.cardBg; border.width: 1; border.color: c.cardBorder }
        contentItem: ColumnLayout {
            spacing: 10
            Label {
                text: root.exesTitle
                font.pixelSize: 14
                font.weight: Font.DemiBold
                color: c.text
                elide: Text.ElideMiddle
                Layout.fillWidth: true
            }
            ListView {
                id: exesList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 6
                delegate: Rectangle {
                    width: exesList.width
                    height: 50
                    radius: 8
                    color: exeMouse.containsMouse ? c.cardBgHover : c.fieldBg
                    border.width: 1
                    border.color: c.fieldBorder
                    MouseArea { id: exeMouse; anchors.fill: parent; hoverEnabled: true }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 8
                        spacing: 8
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label { text: modelData.name; color: c.text; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                            Label { text: modelData.detail; color: c.textDim; font.pixelSize: 11; elide: Text.ElideMiddle; Layout.fillWidth: true }
                        }
                        WAccentButton {
                            text: zh ? "加入应用" : "Add App"
                            onClicked: {
                                backend.config_from_exe(root.dirsPrefix, modelData.path)
                                exesPopup.close()
                            }
                        }
                        WButton {
                            text: zh ? "运行" : "Run"
                            onClicked: backend.run_path(modelData.path, root.dirsPrefix, "")
                        }
                    }
                }
                ScrollBar.vertical: ScrollBar {}
            }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton { text: zh ? "关闭" : "Close"; onClicked: exesPopup.close() }
            }
        }
    }

    // ── 弹层：配置编辑 ──────────────────────────────────────
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
        anchors.centerIn: Overlay.overlay
        width: 560
        height: Math.min(700, root.height - 24)
        padding: 16
        background: Rectangle { radius: 12; color: c.cardBg; border.width: 1; border.color: c.cardBorder }

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
            // 组合框的文本不是绑定，重开对话框时要手动同步一次
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
            spacing: 10

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: formCol.implicitHeight

                ScrollBar.vertical: ScrollBar {}

                ColumnLayout {
                    id: formCol
                    width: parent.width
                    spacing: 9

                    GridLayout {
                        columns: 2
                        columnSpacing: 10
                        rowSpacing: 8
                        Layout.fillWidth: true
                        Label { text: zh ? "执行文件" : "Executable"; color: c.textDim; font.pixelSize: 12 }
                        RowLayout {
                            spacing: 6
                            Layout.fillWidth: true
                            WField {
                                id: cfgExe
                                Layout.fillWidth: true
                                text: cfg.exe
                                onTextEdited: cfg.exe = text
                            }
                            WButton { text: zh ? "浏览" : "Browse"; onClicked: exeDialog.open() }
                        }
                        Label { text: zh ? "前置环境" : "Prefix"; color: c.textDim; font.pixelSize: 12 }
                        RowLayout {
                            spacing: 6
                            Layout.fillWidth: true
                            WField {
                                id: cfgPrefix
                                Layout.fillWidth: true
                                text: cfg.prefix
                                onTextEdited: cfg.prefix = text
                            }
                            WButton { text: zh ? "浏览" : "Browse"; onClicked: prefixDialog.open() }
                        }
                        Label { text: zh ? "运行器" : "Runner"; color: c.textDim; font.pixelSize: 12 }
                        WComboBox {
                            id: cfgRunner
                            Layout.fillWidth: true
                            model: root.runnersModel
                            textRole: "label"
                            onEditTextChanged: cfg.runner = editText
                            onActivated: cfg.runner = editText
                        }
                        Label { text: zh ? "启动参数" : "Launch arguments"; color: c.textDim; font.pixelSize: 12 }
                        WField {
                            id: cfgArgs
                            Layout.fillWidth: true
                            placeholderText: "-krqlv=hd"
                            text: cfg.programArgs
                            onTextEdited: cfg.programArgs = text
                        }
                    }
                    Label {
                        text: zh ? "追加在程序路径后的命令行参数，例如 -krqlv=hd"
                                : "Command-line arguments appended after the program path"
                        color: c.textDim
                        font.pixelSize: 11
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }

                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: c.separator }

                    Label { text: "Gamescope"; color: c.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                    Label {
                        text: zh ? "出现兼容问题时可以尝试使用 gamescope 运行"
                                : "Try running with Gamescope when compatibility issues occur"
                        color: c.textDim
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        spacing: 16
                        WCheckBox {
                            id: cfgGamescope
                            text: zh ? "使用 Gamescope" : "Use Gamescope"
                            checked: cfg.gamescope
                            onToggled: cfg.gamescope = checked
                        }
                        WCheckBox {
                            id: cfgFullscreen
                            text: zh ? "全屏运行" : "Fullscreen"
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
                        Label { text: zh ? "游戏分辨率" : "Game resolution"; color: c.textDim; font.pixelSize: 12 }
                        WComboBox {
                            id: cfgRes
                            Layout.fillWidth: true
                            model: root.resolutionsModel
                            textRole: "value"
                            enabled: cfgGamescope.checked
                            onEditTextChanged: cfg.res = editText
                            onActivated: cfg.res = editText
                        }
                        Label { text: zh ? "帧率限制" : "Frame-rate limit"; color: c.textDim; font.pixelSize: 12 }
                        WComboBox {
                            id: cfgFps
                            Layout.fillWidth: true
                            model: root.fpsModel
                            textRole: "value"
                            enabled: cfgGamescope.checked
                            onEditTextChanged: cfg.fps = editText
                            onActivated: cfg.fps = editText
                        }
                        Label { text: zh ? "Gamescope 额外参数" : "Extra Gamescope arguments"; color: c.textDim; font.pixelSize: 12 }
                        WField {
                            id: cfgExtra
                            Layout.fillWidth: true
                            text: cfg.args
                            enabled: cfgGamescope.checked
                            onTextEdited: cfg.args = text
                        }
                    }

                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: c.separator }

                    Label { text: zh ? "其他设置" : "Other Settings"; color: c.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                    WCheckBox {
                        id: cfgMangohud
                        text: "MangoHud"
                        checked: cfg.mangohud
                        onToggled: cfg.mangohud = checked
                    }
                    Label {
                        text: zh ? "显示帧数和性能占用" : "Show FPS and performance usage"
                        color: c.textDim
                        font.pixelSize: 11
                    }
                    WCheckBox {
                        id: cfgWayland
                        text: zh ? "以 Wayland 运行" : "Run on Wayland"
                        checked: cfg.wayland
                        enabled: !cfgGamescope.checked
                        onToggled: cfg.wayland = checked
                    }
                    Label {
                        text: zh ? "使用 Wine 的 Wayland 驱动。开启 Gamescope 时不生效；前置环境里已有程序在运行时，沿用它们的显示方式。"
                                : "Use Wine's Wayland driver. Not with Gamescope."
                        color: c.textDim
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        spacing: 10
                        Layout.fillWidth: true
                        Label { text: zh ? "环境变量" : "Environment variables"; color: c.textDim; font.pixelSize: 12 }
                        WField {
                            id: cfgEnv
                            Layout.fillWidth: true
                            text: cfg.envVars
                            onTextEdited: cfg.envVars = text
                        }
                    }
                }
            }

            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignRight
                WButton {
                    visible: root.configureMode
                    text: zh ? "保存并运行" : "Save & Run"
                    onClicked: {
                        var entry = configDialog.collect()
                        configDialog.close()
                        backend.save_config(entry)
                        backend.run_path(entry.exe, entry.prefix, entry.runner)
                    }
                }
                WButton { text: zh ? "取消" : "Cancel"; onClicked: configDialog.cancelled() }
                WAccentButton { text: zh ? "保存" : "Save"; onClicked: configDialog.saved() }
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
