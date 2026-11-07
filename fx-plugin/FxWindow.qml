import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Wavemix effects editor. The shell injects `shell` and `manifest`, then
// calls open()/close(). The floating window is intentionally independent of
// the bar panel so it can stay open while the mixer is closed.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: window.visible
  property int floatAttempts: 0
  readonly property int windowWidth: 846
  readonly property int windowHeight: 700
  readonly property string bin: (Quickshell.env("HOME") || "") + "/.local/bin/wavemix"
  readonly property string pluginId: "mnisyif.wavemix-fx"

  property var serverState: null
  property string loadError: ""
  property string errorText: ""
  property string applyError: ""
  property bool applying: false
  property bool pendingApply: false
  property bool awaitingSync: false
  property bool restartWarning: false
  property bool conflict: false
  property bool confirmClose: false
  property bool closingFromHost: false
  property bool forceSyncDraft: false
  property bool addOpen: false
  property int selectedAddIndex: 0
  property int selectedControlIndex: 0
  property int newCounter: 0

  property var draft: []
  property string draftBaseSignature: "[]"
  property string selectedKey: ""
  property var controlOverrides: ({})
  property bool stateRefreshPending: false
  property var queue: []
  property string cmdTag: ""

  property bool dragActive: false
  property int dragFrom: -1
  property int dragTarget: 0
  property real dragY: 0
  property string dragName: ""

  readonly property var serverChain: (serverState && serverState.chain
    && typeof serverState.chain.length === "number") ? serverState.chain : []
  readonly property var plugins: (serverState && serverState.plugins
    && typeof serverState.plugins.length === "number") ? serverState.plugins : []
  readonly property bool fxEnabled: serverState ? serverState.enabled === true : false
  readonly property bool fxRunning: serverState ? serverState.running === true : false
  readonly property string fxVersion: (serverState && serverState.wavemixVersion)
    ? String(serverState.wavemixVersion) : ""

  readonly property string serverSignature: {
    var out = []
    for (var i = 0; i < root.serverChain.length; i++) {
      var e = root.serverChain[i]
      out.push([String(e.plugin || ""), String(e.instance || ""),
                e.enabled !== false])
    }
    return JSON.stringify(out)
  }
  readonly property bool dirty: root.signature(root.draft) !== root.draftBaseSignature
  readonly property var selectedDraftEntry: {
    for (var i = 0; i < root.draft.length; i++)
      if (root.draft[i].key === root.selectedKey) return root.draft[i]
    return null
  }
  readonly property var selectedServerEntry: {
    var entry = root.selectedDraftEntry
    if (!entry || entry.isNew) return null
    for (var i = 0; i < root.serverChain.length; i++)
      if (String(root.serverChain[i].instance) === entry.instance)
        return root.serverChain[i]
    return null
  }
  readonly property real insertionY: {
    if (!root.dragActive || root.draft.length === 0) return 0
    if (root.dragTarget >= root.draft.length) {
      var last = chainRepeater.itemAt(root.draft.length - 1)
      return last ? last.y + last.height : 0
    }
    var item = chainRepeater.itemAt(root.dragTarget)
    return item ? item.y : 0
  }
  readonly property var fakeBar: QtObject {
    readonly property color foreground: Color.foreground
    readonly property color background: Color.background
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: Style.font.family
    readonly property string position: "top"
    readonly property bool vertical: false
    readonly property int barSize: 26
  }

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    window.visible = true
    floatAttempts = 0
    floatTimer.restart()
    refreshState()
    Qt.callLater(function() { content.forceActiveFocus() })
  }

  function requestClose() {
    if (root.dirty) {
      root.confirmClose = true
      return
    }
    root.hideWindow()
  }

  function hideWindow() {
    window.visible = false
    if (!root.closingFromHost && root.shell
        && typeof root.shell.hide === "function") {
      root.closingFromHost = true
      root.shell.hide(root.pluginId)
      root.closingFromHost = false
    }
  }

  // Invoked by the shell's hide(). Do not call hide() again from here.
  function close() {
    root.closingFromHost = true
    root.requestClose()
    root.closingFromHost = false
  }

  function discardAndClose() {
    root.confirmClose = false
    root.syncDraft()
    root.hideWindow()
  }

  // Hyprland opens a new toplevel tiled. Make this one a real floating editor
  // and centre it. The match is by title because Quickshell does not expose
  // the Wayland address directly.
  function floatAddress(address) {
    if (!/^0x[0-9a-f]+$/i.test(address)) return
    var target = 'hl.get_window("address:' + address + '")'
    var floatRule = 'hl.dsp.window.float({ action = "on", window = '
      + target + ' })'
    var resizeRule = 'hl.dsp.window.resize({ x = ' + root.windowWidth
      + ', y = ' + root.windowHeight + ', window = ' + target + ' })'
    var centerRule = 'hl.dsp.window.center({ window = ' + target + ' })'
    floatProc.command = [
      "sh", "-c",
      'hyprctl dispatch "$1"; hyprctl dispatch "$2"; hyprctl dispatch "$3"',
      "wavemix-float", floatRule, resizeRule, centerRule
    ]
    floatProc.running = true
  }

  // ------------------------------------------------------------- state helpers

  function refreshState() {
    if (stateProc.running) {
      stateRefreshPending = true
      return
    }
    stateProc.running = true
  }

  function signature(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      out.push([String(e.plugin || ""), String(e.key || e.instance || ""),
                e.enabled !== false])
    }
    return JSON.stringify(out)
  }

  function syncDraft() {
    var next = []
    for (var i = 0; i < root.serverChain.length; i++) {
      var entry = root.serverChain[i]
      next.push({
        key: String(entry.instance),
        instance: String(entry.instance),
        plugin: String(entry.plugin),
        enabled: entry.enabled !== false,
        isNew: false,
        controls: ({}),
        available: entry.available !== false,
        error: entry.error || "",
        pluginVersion: String(entry.pluginVersion || ""),
        gpu: entry.gpu === true,
        versionChanged: entry.versionChanged === true
      })
    }
    root.draft = next
    root.draftBaseSignature = root.signature(next)
    root.conflict = false
    root.awaitingSync = false
    root.clampSelection()
  }

  function pluginMeta(id) {
    var key = String(id || "")
    for (var i = 0; i < root.plugins.length; i++)
      if (String(root.plugins[i].id) === key) return root.plugins[i]
    return null
  }

  function pluginName(id) {
    var meta = pluginMeta(id)
    return meta ? String(meta.name || id) : (id === "" ? "Unknown effect" : id)
  }

  function controlList(entry) {
    if (!entry) return []
    if (!entry.isNew) {
      for (var i = 0; i < root.serverChain.length; i++)
        if (String(root.serverChain[i].instance) === entry.instance)
          return root.serverChain[i].controls || []
      return []
    }
    var meta = root.pluginMeta(entry.plugin)
    var specs = meta ? (meta.controls || []) : []
    var out = []
    for (var j = 0; j < specs.length; j++) {
      var spec = specs[j]
      var stored = entry.controls ? entry.controls[spec.key] : undefined
      out.push({
        key: spec.key, label: spec.label, param: spec.param,
        min: spec.min, max: spec.max, step: spec.step, unit: spec.unit,
        integer: spec.integer,
        value: stored !== undefined ? stored : spec.default
      })
    }
    return out
  }

  onSelectedKeyChanged: root.selectedControlIndex = 0

  function draftHasPlugin(pluginId) {
    for (var i = 0; i < root.draft.length; i++)
      if (root.draft[i].plugin === pluginId) return true
    return false
  }

  function canAddPlugin(meta) {
    if (!meta || meta.available !== true) return false
    if (meta.allowMultiple === false && root.draftHasPlugin(meta.id)) return false
    return true
  }

  function clampSelection() {
    if (root.draft.length === 0) {
      if (root.selectedKey !== "") root.selectedKey = ""
      return
    }
    for (var i = 0; i < root.draft.length; i++)
      if (root.draft[i].key === root.selectedKey) return
    root.selectedKey = root.draft[0].key
  }

  onServerChainChanged: {
    if (root.forceSyncDraft) {
      root.forceSyncDraft = false
      root.syncDraft()
      return
    }
    if (!root.dirty) root.syncDraft()
    else if (root.serverSignature !== root.draftBaseSignature)
      root.conflict = true
    root.clampSelection()
  }

  function moveSelection(dy) {
    if (root.draft.length === 0) return
    var at = 0
    for (var i = 0; i < root.draft.length; i++)
      if (root.draft[i].key === root.selectedKey) { at = i; break }
    at = Math.max(0, Math.min(root.draft.length - 1, at + dy))
    root.selectedKey = root.draft[at].key
  }

  function moveAddSelection(dy) {
    if (root.plugins.length === 0) return
    root.selectedAddIndex = Math.max(0,
      Math.min(root.plugins.length - 1, root.selectedAddIndex + dy))
  }

  function copyDraftEntry(entry, overrides) {
    var copy = {
      key: entry.key,
      instance: entry.instance,
      plugin: entry.plugin,
      enabled: entry.enabled,
      isNew: entry.isNew,
      controls: entry.controls,
      available: entry.available,
      error: entry.error,
      pluginVersion: entry.pluginVersion,
      gpu: entry.gpu,
      versionChanged: entry.versionChanged
    }
    if (overrides)
      for (var key in overrides) copy[key] = overrides[key]
    return copy
  }

  function openAddView() {
    if (root.applying || root.awaitingSync) return
    root.addOpen = true
    root.selectedAddIndex = 0
    for (var i = 0; i < root.plugins.length; i++)
      if (root.canAddPlugin(root.plugins[i])) {
        root.selectedAddIndex = i
        break
      }
  }

  function addDraft(pluginId) {
    if (root.applying || root.awaitingSync) return
    var meta = root.pluginMeta(pluginId)
    if (!root.canAddPlugin(meta)) return
    var controls = {}
    var specs = meta.controls || []
    for (var i = 0; i < specs.length; i++)
      controls[specs[i].key] = specs[i].default
    root.newCounter++
    var key = "new:" + root.newCounter
    root.draft = root.draft.concat([{
      key: key,
      instance: "",
      plugin: String(pluginId),
      enabled: true,
      isNew: true,
      controls: controls,
      available: true,
      error: "",
      pluginVersion: String(meta.version || ""),
      gpu: meta.gpu === true,
      versionChanged: false
    }])
    root.selectedKey = key
    root.addOpen = false
  }

  function addSelectedPlugin() {
    var meta = root.plugins[root.selectedAddIndex]
    if (meta) root.addDraft(meta.id)
  }

  function removeDraft(key) {
    if (root.applying || root.awaitingSync) return
    var next = []
    for (var i = 0; i < root.draft.length; i++)
      if (root.draft[i].key !== key) next.push(root.draft[i])
    root.draft = next
    root.clampSelection()
  }

  function toggleDraft(key) {
    if (root.applying || root.awaitingSync) return
    var next = root.draft.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].key !== key) continue
      next[i] = root.copyDraftEntry(next[i], { enabled: !next[i].enabled })
      break
    }
    root.draft = next
  }

  function moveDraft(from, to) {
    if (root.applying || root.awaitingSync) return
    if (from < 0 || from >= root.draft.length) return
    to = Math.max(0, Math.min(root.draft.length - 1, to))
    if (to === from) return
    var next = root.draft.slice()
    var entry = next.splice(from, 1)[0]
    next.splice(to, 0, entry)
    root.draft = next
    root.selectedKey = entry.key
  }

  function moveSelected(dy) {
    var at = -1
    for (var i = 0; i < root.draft.length; i++)
      if (root.draft[i].key === root.selectedKey) { at = i; break }
    if (at >= 0) root.moveDraft(at, at + dy)
  }

  function cycleControl(delta) {
    var entry = root.selectedDraftEntry
    var controls = root.controlList(entry)
    if (controls.length === 0) return
    root.selectedControlIndex = (root.selectedControlIndex + delta
      + controls.length) % controls.length
  }

  function adjustSelectedControl(delta) {
    if (root.applying || root.awaitingSync || root.pendingApply) return
    var entry = root.selectedDraftEntry
    var controls = root.controlList(entry)
    if (controls.length === 0) return
    var index = Math.max(0,
      Math.min(controls.length - 1, root.selectedControlIndex))
    var control = controls[index]
    var step = Number(control.step) || 1
    var current = Number(root.controlValue(entry.key, control.key, control.value))
    root.setControl(entry.key, control.key, current + delta * step, control)
  }

  function startDrag(key, index, y) {
    if (root.applying || root.awaitingSync) return
    root.dragActive = true
    root.dragFrom = index
    root.dragTarget = index
    root.dragY = y
    root.dragName = root.pluginName(root.draft[index] ? root.draft[index].plugin : "")
    root.selectedKey = key
  }

  function updateDrag(y) {
    if (!root.dragActive) return
    root.dragY = y
    var target = root.draft.length
    for (var i = 0; i < root.draft.length; i++) {
      var item = chainRepeater.itemAt(i)
      if (!item) continue
      if (y < item.y + item.height / 2) { target = i; break }
    }
    root.dragTarget = target
  }

  function endDrag() {
    if (!root.dragActive) return
    var to = root.dragTarget
    if (to > root.dragFrom) to--
    root.dragActive = false
    root.moveDraft(root.dragFrom, to)
  }

  function cancelDrag() {
    root.dragActive = false
  }

  function discardDraft() {
    root.syncDraft()
    root.applyError = ""
    root.restartWarning = false
  }

  function shortError(text) {
    var lines = String(text || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line !== "") return line
    }
    return ""
  }

  function applyDraft() {
    if (!root.dirty || root.applying || root.awaitingSync
        || commitProc.running) return
    root.applying = true
    root.applyError = ""
    root.restartWarning = false
    if (cmd.running || queue.length > 0) {
      root.pendingApply = true
      return
    }
    root.startCommit()
  }

  function startCommit() {
    if (!root.dirty) return
    var chain = []
    for (var i = 0; i < root.draft.length; i++) {
      var entry = root.draft[i]
      var row = { plugin: entry.plugin, enabled: entry.enabled !== false }
      if (entry.isNew) {
        row.instance = ""
        row.controls = entry.controls || {}
      } else {
        row.instance = entry.instance
      }
      chain.push(row)
    }
    applyWatchdog.restart()
    commitProc.command = [root.bin, "fx", "commit", "--stdin", "--json"]
    commitProc.running = true
    commitProc.write(JSON.stringify({ chain: chain }) + "\n")
  }

  function maybeStartPendingApply() {
    if (!root.pendingApply) return
    if (cmd.running || queue.length > 0 || commitProc.running) return
    root.pendingApply = false
    root.startCommit()
  }

  function retryRestart() {
    root.restartWarning = false
    run(["fx", "apply"])
  }

  // ------------------------------------------------------------- control state

  function controlKey(instance, key) {
    return String(instance) + "\u0001" + String(key)
  }

  function controlValue(instance, key, fallback) {
    var override = root.controlOverrides[root.controlKey(instance, key)]
    return override ? Number(override.value) : fallback
  }

  function quantizeControl(control, value) {
    var number = Number(value)
    if (!control || !isFinite(number)) return number
    var min = Number(control.min)
    var max = Number(control.max)
    var step = Number(control.step)
    if (isFinite(min)) number = Math.max(min, number)
    if (isFinite(max)) number = Math.min(max, number)
    if (isFinite(step) && step > 0 && isFinite(min))
      number = min + Math.round((number - min) / step) * step
    return Math.round(number * 1000000) / 1000000
  }

  function controlDecimals(control) {
    var step = control ? Number(control.step) : 0
    if (!isFinite(step) || step >= 1) return 0
    var decimals = 0
    var scaled = step
    while (decimals < 4 && Math.abs(scaled - Math.round(scaled)) > 1e-6) {
      scaled *= 10
      decimals++
    }
    return decimals
  }

  function formatControlValue(control, value) {
    var number = Number(value)
    if (!isFinite(number)) return ""
    var text = number.toFixed(root.controlDecimals(control))
    if (Math.abs(number - Number(text)) > 1e-9)
      text = number.toFixed(3)
    if (text.indexOf(".") >= 0)
      text = text.replace(/0+$/, "").replace(/\.$/, "")
    return text
  }

  function controlUnit(control) {
    return control ? String(control.unit || "") : ""
  }

  function setControl(key, controlKey, value, control) {
    if (root.applying || root.awaitingSync || root.pendingApply) return
    var entry = null
    for (var i = 0; i < root.draft.length; i++)
      if (root.draft[i].key === key) { entry = root.draft[i]; break }
    if (!entry) return
    var number = root.quantizeControl(control, value)

    if (entry.isNew) {
      var controls = {}
      for (var p in entry.controls) controls[p] = entry.controls[p]
      controls[controlKey] = number
      var nextDraft = root.draft.slice()
      for (var i = 0; i < nextDraft.length; i++)
        if (nextDraft[i].key === key) {
          nextDraft[i] = root.copyDraftEntry(nextDraft[i], { controls: controls })
          break
        }
      root.draft = nextDraft
      return
    }

    var next = {}
    for (var q in root.controlOverrides) next[q] = root.controlOverrides[q]
    next[root.controlKey(key, controlKey)] = {
      instance: String(key), key: String(controlKey), value: number
    }
    root.controlOverrides = next
    overrideExpire.restart()
    run(["fx", "set", String(key), String(controlKey), String(number)])
  }

  function reconcileOverrides() {
    var keys = Object.keys(root.controlOverrides)
    if (keys.length === 0) return
    var next = {}
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var override = root.controlOverrides[key]
      var entry = null
      for (var j = 0; j < root.serverChain.length; j++)
        if (String(root.serverChain[j].instance) === override.instance) {
          entry = root.serverChain[j]
          break
        }
      if (!entry) continue
      var controls = entry.controls || []
      var found = null
      for (var c = 0; c < controls.length; c++)
        if (String(controls[c].key) === override.key) {
          found = controls[c]
          break
        }
      if (!found) continue
      var tolerance = Math.max(0.000001,
        Math.abs(Number(found.step) || 0) + 0.000001)
      if (Math.abs(Number(found.value) - Number(override.value)) <= tolerance)
        continue
      next[key] = override
    }
    root.controlOverrides = next
    if (Object.keys(next).length === 0) overrideExpire.stop()
  }

  function toggleMaster() {
    if (!root.serverState) return
    run(["fx", root.fxEnabled ? "disable" : "enable"])
  }

  // ------------------------------------------------------------ command queue

  function run(args) {
    queue = queue.concat([args])
    pump()
  }

  function pump() {
    if (cmd.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    cmdTag = next.length > 1 ? next[0] + " " + next[1] : next[0]
    cmd.command = [root.bin].concat(next)
    cmd.running = true
  }

  // --------------------------------------------------------------- processes

  Process {
    id: stateProc
    command: [root.bin, "fx", "state", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.serverState = JSON.parse(text)
          root.loadError = ""
          root.reconcileOverrides()
        } catch (e) {
          root.loadError = "Could not load effects."
        }
      }
    }
    stderr: StdioCollector {
      id: stateErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var detail = root.shortError(stateErr.text)
        root.loadError = detail !== ""
          ? "Could not load effects: " + detail
          : "Could not load effects."
      }
      if (root.stateRefreshPending) {
        root.stateRefreshPending = false
        Qt.callLater(root.refreshState)
      }
    }
    onRunningChanged: if (!running) {
      if (root.serverState === null && root.loadError === "")
        root.loadError = "Could not load effects."
      if (root.stateRefreshPending) {
        root.stateRefreshPending = false
        Qt.callLater(root.refreshState)
      }
    }
  }

  Process {
    id: cmd
    stdout: StdioCollector {
      id: cmdOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: cmdErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var detail = root.shortError(cmdErr.text)
        root.errorText = detail !== "" ? detail : "The command failed."
      } else {
        root.errorText = ""
        if (root.cmdTag === "fx apply") root.restartWarning = false
      }
      root.pump()
      if (!cmd.running) {
        if (root.pendingApply) root.maybeStartPendingApply()
        else root.refreshState()
      }
    }
    onRunningChanged: {
      if (running) return
      root.pump()
      if (!cmd.running) {
        if (root.pendingApply) root.maybeStartPendingApply()
        else if (!root.applying) root.refreshState()
      }
    }
  }

  Process {
    id: commitProc
    stdinEnabled: true
    stdout: StdioCollector {
      id: commitOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: commitErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.applying = false
      root.pendingApply = false
      applyWatchdog.stop()
      var result = null
      try { result = JSON.parse(commitOut.text) } catch (e) {}
      if (exitCode === 0 && result && result.ok === true) {
        root.applyError = ""
        root.forceSyncDraft = true
        root.awaitingSync = true
        root.draftBaseSignature = root.signature(root.draft)
        root.restartWarning = result.restarted !== true
        root.refreshState()
      } else {
        root.awaitingSync = false
        root.applyError = result && result.error
          ? String(result.error)
          : (root.shortError(commitErr.text) || "Could not apply changes.")
      }
    }
    onRunningChanged: if (!running && root.applying) {
      root.applying = false
      root.pendingApply = false
      applyWatchdog.stop()
      root.awaitingSync = false
      root.applyError = "Could not run the apply command."
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var list = JSON.parse(text)
          for (var i = 0; i < list.length; i++) {
            if (String(list[i].title) !== "Wavemix — Effects") continue
            floatTimer.stop()
            root.floatAddress(String(list[i].address || ""))
            return
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: floatProc
    command: ["true"]
  }

  Timer {
    id: applyWatchdog
    interval: 120000
    repeat: false
    onTriggered: {
      if (root.applying) {
        root.applying = false
        root.pendingApply = false
        root.applyError = "Applying the chain timed out."
        if (commitProc.running) commitProc.signal(15)
      }
    }
  }

  Timer {
    id: floatTimer
    interval: 150
    repeat: true
    running: false
    onTriggered: {
      if (root.floatAttempts >= 20) {
        stop()
        return
      }
      root.floatAttempts++
      if (!clientsProc.running) clientsProc.running = true
    }
  }

  Timer {
    id: overrideExpire
    interval: 4000
    repeat: false
    onTriggered: root.controlOverrides = ({})
  }

  // ------------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: "Wavemix — Effects"
    color: Color.background
    implicitWidth: root.windowWidth
    implicitHeight: root.windowHeight
    minimumSize: Qt.size(700, 540)
    visible: false

    onWindowConnected: {
      root.floatAttempts = 0
      floatTimer.restart()
    }

    FocusScope {
      id: content
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (root.confirmClose) {
          if (event.key === Qt.Key_Escape) {
            root.confirmClose = false
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.discardAndClose()
            event.accepted = true
          }
          return
        }
        if (root.addOpen) {
          if (event.key === Qt.Key_Escape) {
            root.addOpen = false
            event.accepted = true
          } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
            root.moveAddSelection(1)
            event.accepted = true
          } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
            root.moveAddSelection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.addSelectedPlugin()
            event.accepted = true
          }
          return
        }
        if (event.key === Qt.Key_Escape) {
          root.requestClose()
          event.accepted = true
        } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
          if (event.modifiers & Qt.ControlModifier) root.moveSelected(1)
          else root.moveSelection(1)
          event.accepted = true
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
          if (event.modifiers & Qt.ControlModifier) root.moveSelected(-1)
          else root.moveSelection(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (event.modifiers & Qt.ControlModifier) root.applyDraft()
          else if (root.selectedKey !== "") root.toggleDraft(root.selectedKey)
          event.accepted = true
        } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
          if (root.selectedKey !== "") root.removeDraft(root.selectedKey)
          event.accepted = true
        } else if (event.key === Qt.Key_A) {
          root.openAddView()
          event.accepted = true
        } else if (event.key === Qt.Key_H) {
          root.adjustSelectedControl(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_L) {
          root.adjustSelectedControl(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.cycleControl((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab) {
          root.cycleControl(-1)
          event.accepted = true
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(18)
        spacing: Style.space(12)

        RowLayout {
          Layout.fillWidth: true

          Column {
            spacing: Style.space(2)

            Text {
              text: "EFFECTS"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              font.letterSpacing: 1.2
            }

            Text {
              text: root.fxVersion !== "" ? "Wavemix " + root.fxVersion : "Wavemix"
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Item { Layout.fillWidth: true }

          Text {
            text: String.fromCodePoint(0xf00d)
            color: closeArea.containsMouse ? Color.urgent : Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body

            MouseArea {
              id: closeArea
              anchors.fill: parent
              anchors.margins: -Style.space(5)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.requestClose()
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true

          Text {
            text: "Microphone effects"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Item { Layout.fillWidth: true }

          ToggleSwitch {
            checked: root.fxEnabled
            enabled: root.serverState !== null && !root.applying
              && !root.awaitingSync
            foreground: Color.foreground
            onToggled: root.toggleMaster()
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(14)

          Flickable {
            id: leftFlick
            Layout.preferredWidth: Math.max(280,
              Math.round((window.width - Style.space(36) - Style.space(14)) * 0.42))
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: root.addOpen ? addColumn.implicitHeight
                                       : chainColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: !root.dragActive && contentHeight > height

            Column {
              id: chainColumn
              visible: !root.addOpen
              width: leftFlick.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                visible: root.serverState === null && root.loadError === ""
                text: "Loading…"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                visible: root.loadError !== ""
                text: root.loadError
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                visible: root.loadError !== ""
                text: "Retry"
                color: loadRetryArea.containsMouse ? Color.foreground
                                                   : Qt.darker(Color.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: loadRetryArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refreshState()
                }
              }

              Text {
                width: parent.width
                visible: root.serverState !== null && root.draft.length === 0
                text: "No effects. Add one."
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Repeater {
                id: chainRepeater
                model: root.draft

                FxChainRow {
                  required property var modelData
                  required property int index
                  width: chainColumn.width
                  entry: modelData
                  position: index
                  dragHost: chainColumn
                }
              }

              Item {
                width: parent.width
                implicitHeight: addEffectLabel.implicitHeight + Style.space(10)

                Text {
                  id: addEffectLabel
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "+  Add effect"
                  color: (!root.applying && !root.awaitingSync)
                    ? (addEffectArea.containsMouse ? Color.foreground
                                                   : Qt.darker(Color.foreground, 1.3))
                    : Qt.darker(Color.foreground, 1.8)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  id: addEffectArea
                  anchors.fill: parent
                  enabled: !root.applying && !root.awaitingSync
                  hoverEnabled: true
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.openAddView()
                }
              }
            }

            Rectangle {
              id: insertionLine
              visible: root.dragActive
              x: 0
              y: root.insertionY
              width: chainColumn.width
              height: 2
              color: Color.accent
              z: 20
            }

            Rectangle {
              id: dragGhost
              visible: root.dragActive
              x: 0
              y: Math.max(0, Math.min(chainColumn.height - height,
                                  root.dragY - height / 2))
              width: chainColumn.width
              height: Style.space(28)
              color: Color.background
              opacity: 0.92
              border.width: 1
              border.color: Color.accent
              z: 21

              Text {
                anchors.centerIn: parent
                text: root.dragName
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Column {
              id: addColumn
              visible: root.addOpen
              width: leftFlick.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: "‹  Back to effects"
                color: backArea.containsMouse ? Color.foreground
                                              : Qt.darker(Color.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: backArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addOpen = false
                }
              }

              PanelSectionHeader {
                width: parent.width
                text: "ADD EFFECT"
                foreground: Color.foreground
                fontFamily: Style.font.family
              }

              Repeater {
                model: root.plugins

                FxPluginRow {
                  required property var modelData
                  required property int index
                  width: addColumn.width
                  plugin: modelData
                  position: index
                }
              }
            }
          }

          Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: settingsColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
              id: settingsColumn
              width: parent.width
              spacing: Style.space(8)

              FxSettings { width: parent.width }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.errorText !== ""
          text: root.errorText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.applyError !== ""
          text: "Could not apply: " + root.applyError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        RowLayout {
          Layout.fillWidth: true
          visible: root.restartWarning

          Text {
            text: "Saved, but audio did not restart."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "Retry"
            color: retryArea.containsMouse ? Color.foreground
                                           : Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: retryArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.retryRestart()
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: root.conflict

          Text {
            text: "The chain changed on disk."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "Reload"
            color: reloadArea.containsMouse ? Color.foreground
                                            : Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: reloadArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.syncDraft()
            }
          }

          Text {
            text: "Keep draft"
            color: keepArea.containsMouse ? Color.foreground
                                          : Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: keepArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.conflict = false
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true

          Text {
            text: root.applying ? "Applying… audio restarts briefly"
              : root.awaitingSync ? "Refreshing effects…"
              : (root.dirty ? "Unsaved changes" : "All changes applied")
            color: (root.applying || root.awaitingSync) ? Color.accent
              : (root.dirty ? Color.foreground : Qt.darker(Color.foreground, 1.5))
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Item { Layout.fillWidth: true }

          Text {
            visible: root.dirty && !root.applying && !root.awaitingSync
            text: "Discard"
            color: discardArea.containsMouse ? Color.foreground
                                             : Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: discardArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.discardDraft()
            }
          }

          Text {
            text: "Apply changes"
            color: (root.dirty && !root.applying && !root.awaitingSync)
              ? Color.foreground : Qt.darker(Color.foreground, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              enabled: root.dirty && !root.applying && !root.awaitingSync
                && !commitProc.running
              hoverEnabled: true
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.applyDraft()
            }
          }
        }
      }

      Rectangle {
        anchors.fill: parent
        visible: root.confirmClose
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100

        MouseArea { anchors.fill: parent }

        Rectangle {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(48), Style.space(430))
          height: confirmColumn.implicitHeight + Style.space(32)
          color: Color.background
          border.width: 1
          border.color: Qt.darker(Color.foreground, 2.2)
          radius: Style.cornerRadius

          Column {
            id: confirmColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(16)
            spacing: Style.space(12)

            Text {
              width: parent.width
              text: "Discard unsaved changes?"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Your staged chain changes will be lost."
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width

              Item { Layout.fillWidth: true }

              Text {
                text: "Keep editing"
                color: keepEditingArea.containsMouse ? Color.foreground
                                                     : Qt.darker(Color.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: keepEditingArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.confirmClose = false
                }
              }

              Text {
                text: "Discard"
                color: discardCloseArea.containsMouse ? Color.urgent
                                                      : Qt.darker(Color.foreground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: discardCloseArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.discardAndClose()
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- components

  component FxChainRow: CursorSurface {
    id: row
    property var entry: null
    property int position: 0
    property var dragHost: null

    readonly property string key: (row.entry && row.entry.key)
      ? String(row.entry.key) : ""
    readonly property string instanceId: (row.entry && row.entry.instance)
      ? String(row.entry.instance) : ""
    readonly property string pluginId: (row.entry && row.entry.plugin)
      ? String(row.entry.plugin) : ""
    readonly property string stateText: !row.entry ? ""
      : row.entry.available === false ? "unavailable"
      : row.entry.enabled === false ? "bypassed"
      : row.entry.isNew === true ? "new" : ""
    readonly property bool gpu: row.entry ? row.entry.gpu === true : false

    hasCursor: root.selectedKey === row.key
    foreground: Color.foreground
    implicitHeight: rowContent.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.selectedKey = row.key
    }

    RowLayout {
      id: rowContent
      anchors.fill: parent
      anchors.margins: Style.space(6)
      spacing: Style.space(4)

      Text {
        text: String.fromCodePoint(0xf0c9)
        Layout.preferredWidth: Style.space(14)
        color: dragArea.containsMouse ? Color.foreground
                                      : Qt.darker(Color.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption

        MouseArea {
          id: dragArea
          anchors.fill: parent
          enabled: !root.applying && !root.awaitingSync
          cursorShape: Qt.SizeVerCursor
          preventStealing: true
          onPressed: function(mouse) {
            var p = dragArea.mapToItem(row.dragHost, mouse.x, mouse.y)
            root.startDrag(row.key, row.position, p.y)
          }
          onPositionChanged: function(mouse) {
            if (!root.dragActive) return
            var p = dragArea.mapToItem(row.dragHost, mouse.x, mouse.y)
            root.updateDrag(p.y)
          }
          onReleased: root.endDrag()
          onCanceled: root.cancelDrag()
        }
      }

      Text {
        text: String(row.position + 1)
        Layout.preferredWidth: Style.space(18)
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        Layout.fillWidth: true
        text: root.pluginName(row.pluginId)
          + (row.instanceId !== "" ? " · " + row.instanceId : " · new")
        elide: Text.ElideRight
        color: row.entry && row.entry.enabled === false
          ? Qt.darker(Color.foreground, 1.6) : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        visible: row.stateText !== ""
        text: row.stateText
        color: row.entry && row.entry.available === false
          ? Color.urgent : Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: row.gpu
        text: "GPU"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      PanelActionButton {
        iconText: row.entry && row.entry.enabled === false
          ? String.fromCodePoint(0xf070) // nf-fa-eye_slash
          : String.fromCodePoint(0xf06e) // nf-fa-eye
        tooltipText: row.entry && row.entry.enabled === false
          ? "Enable effect" : "Bypass effect"
        enabled: !root.applying && !root.awaitingSync
        foreground: Color.foreground
        fontFamily: Style.font.family
        onClicked: root.toggleDraft(row.key)
      }

      PanelActionButton {
        iconText: String.fromCodePoint(0xf00d)
        tooltipText: "Remove effect"
        enabled: !root.applying && !root.awaitingSync
        foreground: Color.foreground
        hoverColor: Color.urgent
        fontFamily: Style.font.family
        onClicked: root.removeDraft(row.key)
      }
    }
  }

  component FxPluginRow: CursorSurface {
    id: pluginRow
    property var plugin: null
    property int position: 0

    readonly property bool available: pluginRow.plugin
      ? pluginRow.plugin.available === true : false
    readonly property bool canAdd: root.canAddPlugin(pluginRow.plugin)
    readonly property string typeText: pluginRow.plugin
      ? String(pluginRow.plugin.type || "") : ""
    readonly property string requires: pluginRow.plugin
      ? String(pluginRow.plugin.requires || "") : ""
    readonly property string error: pluginRow.plugin
      ? String(pluginRow.plugin.error || "") : ""

    hasCursor: root.addOpen && root.selectedAddIndex === pluginRow.position
    foreground: Color.foreground
    implicitHeight: Math.max(Style.space(52),
                             pluginContent.implicitHeight + Style.space(10))

    RowLayout {
      id: pluginContent
      anchors.fill: parent
      anchors.margins: Style.space(6)
      spacing: Style.space(6)

      Column {
        Layout.fillWidth: true
        spacing: Style.space(2)

        RowLayout {
          width: parent.width

          Text {
            Layout.fillWidth: true
            text: root.pluginName(pluginRow.plugin ? pluginRow.plugin.id : "")
            elide: Text.ElideRight
            color: pluginRow.available ? Color.foreground
                                       : Qt.darker(Color.foreground, 1.9)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            visible: pluginRow.typeText !== ""
            text: pluginRow.typeText
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: pluginRow.plugin && pluginRow.plugin.gpu === true
            text: "GPU"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Text {
          width: parent.width
          visible: pluginRow.plugin
            && String(pluginRow.plugin.description || "") !== ""
          text: pluginRow.plugin ? String(pluginRow.plugin.description || "") : ""
          color: Qt.darker(Color.foreground, 1.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: !pluginRow.available
          text: pluginRow.error !== "" ? pluginRow.error
            : (pluginRow.requires !== "" ? pluginRow.requires : "Unavailable.")
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: pluginRow.available && !pluginRow.canAdd
          text: "Already added."
          color: Qt.darker(Color.foreground, 1.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: pluginRow.canAdd && !root.applying && !root.awaitingSync
      hoverEnabled: true
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.addDraft(pluginRow.plugin.id)
    }
  }

  component FxSettings: Column {
    id: settings

    readonly property var entry: root.selectedDraftEntry
    readonly property var serverEntry: root.selectedServerEntry
    readonly property var meta: settings.entry
      ? root.pluginMeta(settings.entry.plugin) : null
    readonly property var controls: root.controlList(settings.entry)
    readonly property bool available: settings.entry
      ? settings.entry.available !== false : false
    readonly property bool active: settings.entry
      ? settings.entry.enabled !== false : false
    readonly property bool editable: root.serverState !== null && !root.applying
      && !root.awaitingSync
      && settings.available && settings.active
      && (settings.entry === null || settings.entry.isNew
          || settings.serverEntry !== null)
    readonly property string typeText: settings.meta
      ? String(settings.meta.type || "") : ""
    readonly property string version: settings.entry
      ? String(settings.entry.pluginVersion
               || (settings.meta ? settings.meta.version : "") || "") : ""
    readonly property string requires: settings.meta
      ? String(settings.meta.requires || "") : ""
    readonly property string error: settings.serverEntry
      ? String(settings.serverEntry.error || "")
      : (settings.meta ? String(settings.meta.error || "") : "")
    readonly property bool versionChanged: settings.serverEntry
      ? settings.serverEntry.versionChanged === true : false
    readonly property bool gpu: settings.entry
      ? settings.entry.gpu === true
        || (settings.meta && settings.meta.gpu === true)
      : false

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Text {
      width: parent.width
      visible: settings.entry === null
      text: "Select an effect."
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    RowLayout {
      width: parent.width
      visible: settings.entry !== null

      Text {
        Layout.fillWidth: true
        text: settings.entry ? root.pluginName(settings.entry.plugin) : ""
        elide: Text.ElideRight
        color: settings.available ? Color.foreground
                                  : Qt.darker(Color.foreground, 1.9)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        visible: settings.typeText !== ""
        text: settings.typeText
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: settings.version !== ""
        text: "v" + settings.version
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: settings.gpu
        text: "GPU"
        color: settings.available ? Color.accent
                                  : Qt.darker(Color.foreground, 1.9)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      width: parent.width
      visible: settings.meta !== null
        && String(settings.meta.description || "") !== ""
      text: settings.meta ? String(settings.meta.description || "") : ""
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: settings.entry !== null && settings.entry.isNew === true
      text: "New effect — applied on Apply."
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: settings.versionChanged
      text: "Plugin definition changed since this effect was added; check its settings."
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: !settings.available && settings.entry !== null
      text: settings.error !== "" ? settings.error
        : (settings.requires !== "" ? settings.requires : "Effect unavailable.")
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: settings.entry !== null && !settings.active
      text: (settings.serverEntry && settings.serverEntry.enabled === false)
        ? "Bypassed." : "Bypassed — apply to change."
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: settings.controls

      FxControlRow {
        required property var modelData
        required property int index
        width: settings.width
        control: modelData
        instanceKey: settings.entry ? settings.entry.key : ""
        editable: settings.editable
      }
    }

    Text {
      width: parent.width
      visible: settings.entry !== null && settings.controls.length === 0
      text: "No parameters."
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  component FxControlRow: Item {
    id: controlRow
    property var control: null
    property string instanceKey: ""
    property bool editable: true

    readonly property real currentValue: controlRow.control
      ? root.controlValue(controlRow.instanceKey, controlRow.control.key,
                          controlRow.control.value) : 0
    implicitHeight: Math.max(controlLabel.implicitHeight, slider.implicitHeight,
                             valueText.implicitHeight) + Style.space(4)

    RowLayout {
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        id: controlLabel
        Layout.preferredWidth: Style.space(120)
        text: controlRow.control
          ? String(controlRow.control.label || controlRow.control.key) : ""
        elide: Text.ElideRight
        color: Qt.darker(Color.foreground, 1.25)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      PanelSlider {
        id: slider
        Layout.fillWidth: true
        bar: root.fakeBar
        minimum: controlRow.control ? Number(controlRow.control.min) : 0
        maximum: controlRow.control ? Number(controlRow.control.max) : 1
        step: (controlRow.control && Number(controlRow.control.step) > 0)
          ? Number(controlRow.control.step) : 0.01
        integer: controlRow.control ? controlRow.control.integer === true : false
        value: controlRow.currentValue
        enabled: controlRow.editable
        onReleased: function(v) {
          if (controlRow.control)
            root.setControl(controlRow.instanceKey, controlRow.control.key, v,
                            controlRow.control)
        }
      }

      Text {
        id: valueText
        Layout.preferredWidth: Style.space(80)
        horizontalAlignment: Text.AlignRight
        text: controlRow.control
          ? root.formatControlValue(controlRow.control,
                                    slider.dragging ? slider.liveValue
                                                    : controlRow.currentValue)
            + root.controlUnit(controlRow.control)
          : ""
        color: controlRow.editable ? Color.foreground
                                   : Qt.darker(Color.foreground, 1.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
