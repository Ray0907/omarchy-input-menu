import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import "Model.js" as Model

// Quickshell signals tell us when to read; scripts/snapshot owns the live state.
// fcitx5 can change its icon on focus without emitting a tray signal.
Item {
  id: root

  // Only the first bar's source writes the mode cache (see Panel.qml).
  property bool primary: false
  readonly property var trayItem: {
    var values = SystemTray.items.values
    for (var i = 0; i < values.length; i++)
      if (values[i] && String(values[i].id) === "Fcitx") return values[i]
    return null
  }

  property bool controllerAlive: false
  readonly property string status: trayItem ? "ready" : (controllerAlive ? "noSni" : "down")
  property bool focusKnown: false
  property bool hasFocusedWindow: false
  property int processStarts: 0

  property var snap: ({ sni: false, icon: "", items: [] })
  property bool hasValidSnapshot: false
  property bool bestEffort: false
  readonly property var inputMethods: (snap.items || []).filter(function (e) { return e.radio && !e.sub })
  readonly property var modes: (snap.items || []).filter(function (e) { return e.radio && e.sub && !Model.isKeyboard(snap.icon) })
  property string iconName: ""
  onSnapChanged: {
    if (snap.sni && snap.icon) iconName = snap.icon
    rememberModes()
  }
  readonly property string currentIm: {
    for (var i = 0; i < inputMethods.length; i++) if (inputMethods[i].checked) return inputMethods[i].icon
    return ""
  }
  readonly property string currentMode: {
    for (var i = 0; i < modes.length; i++) if (modes[i].checked) return modes[i].icon
    return ""
  }
  readonly property bool singleInputMethod: status === "ready" && inputMethods.length > 0 && inputMethods.length < 2
  property var modeCache: ({})
  property bool cacheReady: false
  property bool cacheDirty: false
  property bool failed: false

  readonly property string snapshotPath: {
    try { return Model.localFilePath(Qt.resolvedUrl("scripts/snapshot")) }
    catch (e) { return "" }
  }
  property bool refreshAgain: false
  property string clickId: ""
  property int focusVersion: 0
  property int switchVersion: 0
  property int runFocusVersion: -1
  property int runSwitchVersion: -1
  property bool runEligible: false
  property bool runValid: false
  property int readyFocusVersion: -1
  property int readySwitchVersion: -1
  property int focusQueryVersion: -1

  function checkController() {
    if (!probe.running) probe.running = true
  }

  function queryFocus() {
    if (initialFocus.running) return
    focusQueryVersion = focusVersion
    initialFocus.running = true
  }

  function refresh() {
    if (!snapshotPath || !focusKnown || (!hasFocusedWindow && (hasValidSnapshot || !trayItem))) return
    if (snapProc.running) { refreshAgain = true; return }
    runFocusVersion = focusVersion
    runSwitchVersion = switchVersion
    runEligible = focusKnown && !initialFocus.running && !focusWait.running && !focusSettle.running
    runValid = false
    snapProc.command = clickId ? [snapshotPath, "click", clickId] : [snapshotPath]
    clickId = ""
    snapProc.running = true
  }

  function trigger(id) {
    clickId = String(id)
    refresh()
  }

  property string pendingIm: ""
  property string pendingMode: ""
  property int tries: 0
  property bool awaitingConfirm: false
  property bool afterImClick: false

  function finishSwitch(didFail) {
    failed = didFail
    pendingIm = ""
    pendingMode = ""
    awaitingConfirm = false
    afterImClick = false
    confirmTimer.stop()
    noFocusDrop.stop()
  }

  function switchTo(im, mode) {
    pendingIm = String(im || "")
    pendingMode = String(mode || "")
    switchVersion += 1
    tries = 0
    failed = false
    awaitingConfirm = false
    afterImClick = false
    confirmTimer.stop()
    focusWait.stop()
    noFocusDrop.stop()
    focusKnown = false
    queryFocus()
  }

  function triggerIcon(list, icon) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].icon === icon) { trigger(list[i].id); return true }
    }
    return false
  }

  function attempt(list, icon, imClick) {
    tries += 1
    awaitingConfirm = true
    afterImClick = triggerIcon(list, icon) && imClick
    confirmTimer.restart()
  }

  // Only a completed run started after the last focus event and both focus
  // waits may select an entry. Older menu IDs can target another context.
  function apply() {
    if (!pendingIm || !focusKnown || !hasFocusedWindow || initialFocus.running ||
        snapProc.running || focusWait.running || focusSettle.running ||
        readyFocusVersion !== focusVersion || readySwitchVersion !== switchVersion || !snap.sni) return
    var active = snap.icon === pendingIm || snap.icon.indexOf(pendingIm + "_") === 0 ||
                 (Model.isKeyboard(pendingIm) && Model.isKeyboard(snap.icon))
    if (currentIm === pendingIm && (pendingMode ? snap.icon === pendingMode : active)) {
      finishSwitch(false)
      return
    }
    if (awaitingConfirm) {
      if (afterImClick && pendingMode && currentIm === pendingIm && active && tries < 3)
        attempt(modes, pendingMode, false)
      return
    }
    if (tries >= 3) { finishSwitch(true); return }
    if (currentIm !== pendingIm || !active) attempt(inputMethods, pendingIm, true)
    else if (pendingMode) attempt(modes, pendingMode, false)
  }

  Timer { id: focusWait; interval: 250; onTriggered: root.refresh() }
  Timer {
    id: noFocusDrop
    interval: 10000
    onTriggered: if (!root.hasFocusedWindow && root.pendingIm) root.finishSwitch(false)
  }
  Timer {
    id: confirmTimer
    interval: 1000
    onTriggered: {
      if (!root.pendingIm || !root.hasFocusedWindow) return
      if (focusWait.running || focusSettle.running) { restart(); return }
      if (root.tries >= 3) { root.finishSwitch(true); return }
      root.awaitingConfirm = false
      root.afterImClick = false
      root.refresh()
    }
  }

  Process {
    id: snapProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && typeof s === "object" && typeof s.sni === "boolean" &&
              root.focusKnown && root.runFocusVersion === root.focusVersion) {
            if (root.hasFocusedWindow) {
              root.snap = s
              root.bestEffort = false
              root.runValid = true
              if (s.sni && root.inputMethods.length > 0) root.hasValidSnapshot = true
            } else if (!root.hasValidSnapshot && root.trayItem && s.sni && Array.isArray(s.items)) {
              var methods = s.items.filter(function(e) { return e.radio && !e.sub })
              var checked = methods.find(function(e) { return e.checked && e.icon }) ||
                            methods.find(function(e) { return e.icon === s.icon ||
                              (Model.isKeyboard(e.icon) && Model.isKeyboard(s.icon)) ||
                              s.icon.indexOf(e.icon + "_") === 0 }) || methods[0]
              if (checked && checked.icon) {
                root.snap = { sni: true, icon: checked.icon, items: methods }
                root.bestEffort = true
                root.hasValidSnapshot = true
              }
            }
          }
        } catch (e) {}
      }
    }
    onRunningChanged: if (running) root.processStarts += 1
    onExited: function(code) {
      if (root.refreshAgain || root.clickId) {
        root.refreshAgain = false
        Qt.callLater(root.refresh)
      } else if (root.pendingIm && root.hasFocusedWindow && root.runEligible &&
                 root.runFocusVersion === root.focusVersion &&
                 root.runSwitchVersion === root.switchVersion &&
                 !focusWait.running && !focusSettle.running) {
        if (code === 0 && root.runValid && root.snap.sni) {
          root.readyFocusVersion = root.runFocusVersion
          root.readySwitchVersion = root.runSwitchVersion
          Qt.callLater(root.apply)
        } else if (!root.awaitingConfirm) {
          root.tries += 1
          root.awaitingConfirm = true
          confirmTimer.restart()
        }
      }
    }
  }

  QsMenuOpener { id: rootMenu; menu: root.trayItem ? root.trayItem.menu : null }
  Connections { target: rootMenu; function onChildrenChanged() { root.refresh() } }
  Connections { target: root.trayItem; ignoreUnknownSignals: true; function onIconChanged() { root.refresh() } }
  onTrayItemChanged: {
    if (!trayItem && bestEffort) {
      bestEffort = false
      hasValidSnapshot = false
      snap = ({ sni: false, icon: "", items: [] })
      iconName = ""
      checkController()
    } else {
      if (trayItem && !hasFocusedWindow) hasValidSnapshot = false
      if (trayItem || hasFocusedWindow) refresh()
      if (!trayItem) checkController()
    }
  }

  Timer { id: focusSettle; interval: 120; onTriggered: root.refresh() }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || String(event.name) !== "activewindow") return
      root.focusVersion += 1
      root.focusKnown = true
      root.hasFocusedWindow = String(event.data || "").replace(/[,\s]/g, "").length > 0
      if (!root.hasFocusedWindow) {
        focusSettle.stop()
        focusWait.stop()
        confirmTimer.stop()
        root.awaitingConfirm = false
        root.afterImClick = false
        root.clickId = ""
        if (root.pendingIm && !noFocusDrop.running) noFocusDrop.start()
        if (!root.pendingIm && !root.hasValidSnapshot) root.refresh()
      } else {
        noFocusDrop.stop()
        if (focusWait.running) focusWait.stop()
        focusSettle.restart()
      }
    }
  }

  function rememberModes() {
    if (!currentIm || Model.isKeyboard(currentIm) || modes.length === 0) return
    var list = modes.map(function (m) { return { icon: m.icon, text: m.text } })
    if (JSON.stringify(modeCache[currentIm]) === JSON.stringify(list)) return
    var next = Object.assign({}, modeCache)
    next[currentIm] = list
    modeCache = next
    if (!cacheReady) cacheDirty = true
    else if (primary) cacheFile.setText(JSON.stringify(modeCache))
  }

  function loadCache(raw, invalid) {
    var stored = {}
    if (!invalid) {
      try {
        stored = JSON.parse(raw)
        if (!stored || typeof stored !== "object" || Array.isArray(stored)) { invalid = true; stored = {} }
        else {
          var clean = {}
          Object.keys(stored).forEach(function (key) {
            if (key === "__proto__" || key === "constructor" || key === "prototype") { invalid = true; return }
            var list = stored[key]
            if (Model.isKeyboard(key) || !Array.isArray(list)) { invalid = true; return }
            var valid = list.filter(function (m) { return m && typeof m.icon === "string" && typeof m.text === "string" })
            if (valid.length !== list.length) invalid = true
            if (valid.length || list.length === 0) clean[key] = valid
          })
          stored = clean
        }
      } catch (e) { invalid = true; stored = {} }
    }
    modeCache = Object.assign({}, stored, modeCache)
    cacheReady = true
    rememberModes()
    if (primary && (invalid || cacheDirty)) cacheFile.setText(JSON.stringify(modeCache))
    cacheDirty = false
  }

  function strip(list) {
    return list.map(function (x) { return { id: x.id, icon: x.icon, text: x.text, checked: x.checked } })
  }

  function dump() {
    return JSON.stringify({ status: status, iconName: iconName, currentIm: currentIm, currentMode: currentMode,
                            inputMethods: strip(inputMethods), modes: strip(modes), modeCache: modeCache,
                            singleInputMethod: singleInputMethod, primary: primary, failed: failed,
                            focused: hasFocusedWindow, focusKnown: focusKnown, focusQueryRunning: initialFocus.running,
                            processStarts: processStarts, focusEvents: focusVersion,
                            pendingIm: pendingIm, pendingMode: pendingMode })
  }

  Process {
    id: initialFocus
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.focusQueryVersion !== root.focusVersion) return
        try { root.hasFocusedWindow = !!JSON.parse(text).address } catch (e) { root.hasFocusedWindow = false }
        root.focusKnown = true
      }
    }
    onRunningChanged: if (running) root.processStarts += 1
    onExited: {
      if (!root.focusKnown) { root.hasFocusedWindow = false; root.focusKnown = true }
      if (root.pendingIm) {
        if (root.hasFocusedWindow) { noFocusDrop.stop(); focusWait.restart() }
        else noFocusDrop.restart()
      } else root.refresh()
    }
  }

  Process {
    id: probe
    command: ["busctl", "--user", "--auto-start=no", "call", "org.fcitx.Fcitx5", "/controller", "org.fcitx.Fcitx.Controller1", "State"]
    onRunningChanged: if (running) root.processStarts += 1
    onExited: function(code) { root.controllerAlive = code === 0 }
  }

  FileView {
    id: cacheFile
    path: Quickshell.env("HOME") + "/.local/state/input-menu-modes.json"
    printErrors: false
    onLoaded: root.loadCache(text(), false)
    onLoadFailed: root.loadCache("", true)
  }

  Component.onCompleted: {
    checkController()
    queryFocus()
  }
}
