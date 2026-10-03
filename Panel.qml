import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.ray0907.input-menu"
  ipcTarget: "io.github.ray0907.input-menu"
  manageIpc: false

  readonly property string locale: Model.localeKey(Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || "")
  readonly property var str: Model.strings(locale)
  readonly property var hiddenModes: setting("hiddenModes", Model.DEFAULT_HIDDEN_MODES)
  property bool hasConfigTool: false
  property string themeState: ""

  readonly property var rows: source.status === "ready"
    ? Model.rows(source.inputMethods, source.bestEffort ? {} : source.modeCache, hiddenModes, source.currentMode, locale) : []
  readonly property string badgeIcon: source.status === "ready"
    ? (source.pendingMode || source.pendingIm || source.iconName) : source.iconName
  readonly property string badgeGlyph: {
    var entries = source.inputMethods.concat(source.modes, source.modeCache[source.pendingIm] || [])
    for (var i = 0; i < entries.length; i++)
      if (entries[i].icon === badgeIcon) return Model.glyphFor(badgeIcon, entries[i].text)
    return Model.glyphFor(badgeIcon, "")
  }
  readonly property string badgeTitle: {
    if (source.failed) return str.switchFailed
    for (var i = 0; i < rows.length; i++)
      if (rows[i].mode === badgeIcon || (rows[i].im === badgeIcon && !rows[i].mode)) return rows[i].title
    for (var j = 0; j < rows.length; j++) if (rows[j].checked) return rows[j].title
    return Model.titleFor(badgeIcon, locale, "")
  }
  readonly property bool dimmed: source.status !== "ready"

  readonly property var extras: {
    var out = []
    if (source.status === "down") {
      out.push({ kind: "notice", title: str.notRunning })
      out.push({ kind: "action", id: "start", title: str.start })
    } else if (source.status === "noSni") {
      out.push({ kind: "notice", title: str.sniOff })
      out.push({ kind: "action", id: "enable", title: str.enable })
    } else if (source.singleInputMethod) {
      out.push({ kind: "notice", title: str.onlyOne })
      out.push({ kind: "action", id: "installIm", title: str.installIm })
    }
    if (source.failed) out.push({ kind: "notice", title: str.switchFailed })
    out.push({ kind: "separator" })
    out.push({ kind: "action", id: "emoji", title: str.emoji })
    if (source.status !== "down" && !source.singleInputMethod) out.push({ kind: "action", id: "installIm", title: str.installIm })
    if (themeState === "free" || themeState === "claimed")
      out.push({ kind: "action", id: "matchTheme", title: str.matchTheme })
    if (hasConfigTool) out.push({ kind: "action", id: "settings", title: str.settings })
    return out
  }
  readonly property var actionRows: extras.filter(function(x) { return x.kind === "action" })
  function actionOrdinal(extraIndex) {
    var n = 0
    for (var i = 0; i < extraIndex && i < extras.length; i++) if (extras[i].kind === "action") n++
    return n
  }
  readonly property int rowCount: rows.length + actionRows.length

  property int selectedIndex: 0
  property bool cursorActive: false
  // Opening grows the menu from the badge on a spring. Retargeting one value from wherever it is makes it
  // interruptible. spring 5 / damping 0.5 was measured on the device: no overshoot, about 320 ms to settle
  // (Apple's damping ratio 1.0, response 0.3 s), because nothing was flicked.
  property real reveal: root.opened ? 1 : 0
  Behavior on reveal { SpringAnimation { spring: 5; damping: 0.5; epsilon: 0.001 } }

  function launch(command) {
    source.processStarts += 1
    Quickshell.execDetached(command)
  }

  // One window per action: skip when the same command is already running, and ignore a second click within
  // two seconds while the first is still starting (its window has no process to find yet).
  property var lastLaunch: ({})
  function launchOnce(pattern, command) {
    var now = Date.now()
    if (now - (lastLaunch[pattern] || 0) < 2000) return
    lastLaunch[pattern] = now
    launch(Model.guardedLaunch(pattern, command))
  }

  function activate(index) {
    if (index < 0 || index >= rowCount) return
    if (index < rows.length) {
      var r = rows[index]
      close()
      source.switchTo(r.im, r.mode)
      return
    }
    var a = actionRows[index - rows.length]
    close()
    if (a.id === "emoji") launchOnce("omarchy-menu-emoji", ["omarchy-menu-emoji"])
    else if (a.id === "settings") launchOnce("fcitx5-configtool", ["fcitx5-configtool"])
    else if (a.id === "start") launch(["systemctl", "--user", "start", "omarchy-fcitx5"])
    else if (a.id === "enable") launchOnce("scripts/enable", ["omarchy-launch-floating-terminal-with-presentation",
                                                        Model.shellQuote(Model.localFilePath(Qt.resolvedUrl("scripts/enable")))])
    else if (a.id === "installIm") launchOnce("scripts/add-engine", ["omarchy-launch-floating-terminal-with-presentation",
                                                        Model.shellQuote(Model.localFilePath(Qt.resolvedUrl("scripts/add-engine")))])
    else if (a.id === "matchTheme") launchOnce("scripts/theme enable", ["omarchy-launch-floating-terminal-with-presentation",
                                                        Model.shellQuote(Model.localFilePath(Qt.resolvedUrl("scripts/theme"))) + " enable"])
  }

  onOpenedChanged: if (opened) {
    themeProc.running = true
    if (source.status !== "ready") source.checkController()
    else if (source.hasFocusedWindow) source.refresh()
    cursorActive = false
    var idx = -1
    for (var i = 0; i < rows.length; i++) if (rows[i].checked) idx = i
    selectedIndex = idx >= 0 ? idx : 0
  }
  onRowCountChanged: if (selectedIndex >= rowCount) selectedIndex = Math.max(0, rowCount - 1)

  FcitxSource {
    id: source
    // QsWindow.window is typed QObject to qmllint; at runtime it is the bar's PanelWindow.
    primary: !!root.QsWindow.window && Quickshell.screens.length > 0 &&
             root.QsWindow.window.screen.name === Quickshell.screens[0].name // qmllint disable missing-property
  }

  Process {
    id: configToolCheck
    command: ["sh", "-c", "command -v fcitx5-configtool"]
    onRunningChanged: if (running) source.processStarts += 1
    onExited: function(code) { root.hasConfigTool = code === 0 }
  }
  Component.onCompleted: configToolCheck.running = true

  Process {
    id: themeProc
    command: [Model.localFilePath(Qt.resolvedUrl("scripts/theme")), "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.themeState = text.trim()
    }
    onRunningChanged: if (running) source.processStarts += 1
  }

  IpcHandler {
    target: "io.github.ray0907.input-menu"
    function state(): string {
      var s = JSON.parse(source.dump())
      s.badgeGlyph = root.badgeGlyph
      s.badgeTitle = root.badgeTitle
      s.rows = root.rows
      s.selectedIndex = root.selectedIndex
      s.cursorActive = root.cursorActive
      s.themeState = root.themeState
      s.extras = root.extras
      return JSON.stringify(s)
    }
    function switchTo(im: string, mode: string): void { source.switchTo(im, mode) }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function menuOpen(): bool { return root.opened }
    function mouseTarget(index: int): string {
      var row = inputRows.itemAt(index)
      if (!root.opened || !row) return ""
      var point = row.mapToItem(null, row.width / 2, row.height / 2)
      return JSON.stringify({ x: Math.round(point.x), y: Math.round(point.y) })
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.badgeGlyph
    fontSize: Style.font.caption
    horizontalMargin: 8
    dimmed: root.dimmed
    tooltipText: root.dimmed ? (source.status === "down" ? root.str.notRunning : root.str.sniOff) : root.badgeTitle
    onPressed: function(b) {
      if (b === Qt.RightButton)
        launch(["busctl", "--user", "--auto-start=no", "call", "org.fcitx.Fcitx5", "/controller",
                                 "org.fcitx.Fcitx.Controller1", "Toggle"])
      else root.toggle()
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.round(Style.font.caption * 1.7)
      height: width
      radius: Math.round(width * 0.22)
      color: "transparent"
      border.width: 1
      border.color: root.barForeground
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(280))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      transform: Scale {
        origin.x: keyCatcher.mapFromItem(button, button.width / 2, 0).x
        origin.y: 0
        xScale: 0.96 + 0.04 * root.reveal
        yScale: 0.96 + 0.04 * root.reveal
      }
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0 && root.rowCount > 0)
          root.selectedIndex = (root.selectedIndex + dy + root.rowCount) % root.rowCount
      }
      onActivateRequested: root.activate(root.selectedIndex)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(2)

        Repeater {
          id: inputRows
          model: root.rows
          MenuRow {
            required property var modelData
            required property int index
            width: column.width
            rowIndex: index
            checked: modelData.checked
            glyph: modelData.glyph
            title: modelData.title
          }
        }

        Repeater {
          model: root.extras
          Item {
            required property var modelData
            required property int index
            width: column.width
            implicitHeight: modelData.kind === "separator" ? sep.implicitHeight + Style.space(6)
                          : (modelData.kind === "notice" ? note.implicitHeight + Style.space(8) : act.implicitHeight)
            PanelSeparator {
              id: sep
              visible: modelData.kind === "separator"
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              foreground: root.barForeground
            }
            Text {
              id: note
              visible: modelData.kind === "notice"
              anchors.verticalCenter: parent.verticalCenter
              x: Style.space(6)
              width: parent.width - Style.space(12)
              textFormat: Text.PlainText
              text: modelData.title || ""
              wrapMode: Text.WordWrap
              color: root.barForeground
              opacity: 0.75
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MenuRow {
              id: act
              visible: modelData.kind === "action"
              width: parent.width
              rowIndex: root.rows.length + root.actionOrdinal(index)
              glyph: ""
              title: modelData.title || ""
            }
          }
        }
      }
    }
  }

  component MenuRow: Rectangle {
    id: row
    property int rowIndex: 0
    property bool checked: false
    property string glyph: ""
    property string title: ""

    readonly property bool hasCursor: root.cursorActive && root.selectedIndex === rowIndex
    readonly property color ink: hasCursor ? Model.pickInk(Color.accent, Color.popups.background, root.barForeground) : root.barForeground

    radius: Style.cornerRadius
    scale: mouse.pressed ? 0.97 : 1
    Behavior on scale { SpringAnimation { spring: 5; damping: 0.5; epsilon: 0.001 } }
    color: hasCursor ? (mouse.pressed ? Qt.darker(Color.accent, 1.2) : Color.accent) : "transparent"
    implicitHeight: rowInner.implicitHeight + Style.spacing.md * 2

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: row.checked ? "✓" : ""
        width: Style.space(14)
        color: row.ink
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Rectangle {
        visible: row.glyph !== ""
        width: visible ? Math.round(Style.font.body * 1.6) : 0
        height: width
        radius: Math.round(width * 0.22)
        color: "transparent"
        border.width: 1
        border.color: row.ink
        anchors.verticalCenter: parent.verticalCenter
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: row.glyph
          color: row.ink
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        text: row.title
        width: Math.max(0, row.width - Style.space(12) - Style.space(14) - Style.space(16)
                         - (row.glyph ? Math.round(Style.font.body * 1.6) : 0))
        color: row.ink
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.selectedIndex = row.rowIndex
      }
      onClicked: root.activate(row.rowIndex)
    }
  }
}
