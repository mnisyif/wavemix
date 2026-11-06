import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// Wavemix: a bar button and a channel-mixer panel.
//
// Each channel has two sends -- output (to your speakers) and input (to the
// shared virtual mic) -- each with a level fader and an enable check. A channel
// can be deleted, and apps can be assigned to it (a chip per app). A device
// section at the bottom picks the physical output and input.
//
// The bar itself is a mic icon and a speaker icon: left-click either to mute
// it, right-click to open the panel. The panel is a view over the `wavemix`
// CLI: it polls `status --json`, `devices --json` and (only while picking)
// `apps --json`, and drives `send` / `device` / `channel` / `route` / `unroute`.
Panel {
  id: root
  moduleName: "mnisyif.wavemix"
  ipcTarget: "mnisyif.wavemix"
  manageIpc: false

  readonly property string bin: (Quickshell.env("HOME") || "") + "/.local/bin/wavemix"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // device mute state (physical output/input), and the bar glyphs for it
  property var mutes: ({ output: false, input: false })
  readonly property string micOn: String.fromCodePoint(0xf130) // nf-fa-microphone
  readonly property string micOff: String.fromCodePoint(0xf131) // nf-fa-microphone_slash
  readonly property string spkOn: String.fromCodePoint(0xf057e) // nf-md-volume_high
  readonly property string spkOff: String.fromCodePoint(0xf075f) // nf-md-volume_mute
  // Icon cell: a touch tighter than a full bar icon slot (the pair sits closer
  // than two separate widgets).
  readonly property real iconCell: Style.bar.iconSlot - Style.space(3)

  readonly property string heroGlyph: String.fromCodePoint(0xf1de) // nf-fa-sliders
  readonly property bool micFxOn: statusData && statusData.micFx ? statusData.micFx.enabled === true : false
  readonly property var headroom: (statusData && statusData.headroom)
    ? statusData.headroom : ({ output: 1, input: 1 })
  // The most aggressive trim across the two send buses; below 1 means the
  // engine is holding the summed mix under the -1 dBFS headroom target.
  readonly property real headroomTrim: Math.min(Number(headroom.output) || 1,
                                                Number(headroom.input) || 1)
  readonly property string heroStatus: {
    var cur = deviceCurrent("defaultSource")
    var list = deviceList("defaultSource")
    for (var i = 0; i < list.length; i++)
      if (list[i].name === cur) return "DEFAULT MIC: " + String(list[i].description).toUpperCase()
    return "DEFAULT MIC: " + String(cur).toUpperCase()
  }
  readonly property string tooltipText: "Wavemix — mic "
    + (mutes.input ? "muted" : "on") + " · speakers " + (mutes.output ? "muted" : "on")
    + "   (left-click an icon to mute · right-click for panel)"

  property var statusData: null
  property var devicesData: null
  property var appData: []
  property int cursorIndex: 0
  property string view: "main" // "main" | "pick"
  property string pickChannel: ""
  property bool editing: false
  // Short-lived feedback for the multi-output picker (the last output cannot
  // be removed, so the click is refused rather than sent to the CLI).
  property string outputNotice: ""

  // Effects popup. fxData is the JSON from `wavemix fx state`.
  property bool fxOpen: false
  property bool fxRefreshPending: false
  property var fxData: null
  readonly property var fxChain: (fxData && fxData.chain
    && typeof fxData.chain.length === "number") ? fxData.chain : []
  readonly property var fxPlugins: (fxData && fxData.plugins
    && typeof fxData.plugins.length === "number") ? fxData.plugins : []
  readonly property bool fxEnabled: fxData ? fxData.enabled === true : false
  readonly property bool fxRunning: fxData ? fxData.running === true : false
  readonly property string fxVersion: (fxData && fxData.wavemixVersion)
    ? String(fxData.wavemixVersion) : ""

  // Chain editing happens in the Effects popup: "chain" is the current chain
  // and "add" is the plugin list. Structural commands restart audio, so only
  // one may be in flight; fxApplying drives the notice and disables the
  // controls until the CLI returns.
  property string fxView: "chain" // "chain" | "add"
  property string fxSelected: ""
  property bool fxApplying: false
  property string fxError: ""
  property string fxLoadError: ""
  // The add list scrolls when the manifests do not fit. Leave room for the
  // header, back row, and section header before using the screen height.
  readonly property real fxAddListMaxHeight: Math.max(Style.space(120),
    Math.min(Style.space(360),
             fxPopup.availableCardHeight - Style.space(230)))

  // ---- model ---------------------------------------------------------------
  readonly property var channelIds: {
    var g = statusData && statusData.graph ? statusData.graph.channels : null
    return g ? Object.keys(g) : []
  }
  readonly property var rules: (statusData && statusData.rules) ? statusData.rules : ({})

  function channelOf(id) {
    return statusData && statusData.graph ? statusData.graph.channels[id] : null
  }
  function channelName(id) {
    var c = channelOf(id)
    return c ? String(c.name) : id
  }
  function channelIsMic(id) {
    var c = channelOf(id)
    return c ? c.source === "mic" : false
  }
  function channelApps(id) {
    var out = []
    for (var k in rules) if (rules[k] === id) out.push(k)
    out.sort()
    return out
  }
  function sendOf(id, send) {
    var c = channelOf(id)
    return c ? c.sends[send] : null
  }
  function sendOn(id, send) {
    var s = sendOf(id, send)
    return s ? s.on === true : false
  }
  function sendVol(id, send) {
    var s = sendOf(id, send)
    return s ? Number(s.volume) : 0
  }

  // ---- meters --------------------------------------------------------------
  // Live peak monitors read the channel's raw audio, before its send faders.
  // Apps channels have their own null-sink; the mic channel shares the mic bus.
  readonly property var pwNodes: {
    var map = ({})
    var list = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < list.length; i++) {
      var node = list[i]
      if (node && node.name) map[String(node.name)] = node
    }
    return map
  }
  function channelPeakNode(id) {
    if (!id) return null
    var name = channelIsMic(id) ? "wavemix_micbus" : "wavemix_" + id
    return pwNodes[name] || null
  }

  // ---- device helpers ------------------------------------------------------
  function deviceList(key) {
    if (!devicesData) return []
    if (key === "output") return devicesData.outputs || []
    if (key === "input") return devicesData.inputs || []
    if (key === "defaultSource") return devicesData.sources || []
    if (key === "defaultSink") return devicesData.sinks || []
    return []
  }
  function deviceCurrent(key) {
    if (!devicesData || !devicesData.selected) return ""
    return devicesData.selected[key] || ""
  }
  function deviceLabel(which) {
    var cur = deviceCurrent(which)
    var list = deviceList(which)
    for (var i = 0; i < list.length; i++) if (list[i].name === cur) return String(list[i].description)
    return cur === "" ? "(none)" : cur
  }
  function deviceOptions(key) {
    return deviceList(key).map(function(d) { return { value: d.name, label: d.description } })
  }
  function setDevice(key, name) {
    var cmd = deviceCommand(key, name)
    if (cmd) { run(cmd); refreshSoon() }
  }
  function dropdownFor(key) {
    if (key === "output") return ddOutput
    if (key === "input") return ddInput
    if (key === "defaultSource") return ddDefaultSource
    if (key === "defaultSink") return ddDefaultSink
    return null
  }
  function openDeviceDropdown(key) {
    var d = dropdownFor(key)
    if (d) d.toggle()
  }
  // ---- multi-output --------------------------------------------------------
  // selected.outputs may still hold the @DEFAULT_SINK@ sentinel (a migrated
  // default state). Resolve it to the concrete primary so the picker checks
  // the output the engine is actually playing through.
  function resolveOutputName(name) {
    var n = String(name || "")
    if (n === "" || n === "@DEFAULT_SINK@") return deviceCurrent("output")
    return n
  }
  function deviceSelectedOutputs() {
    var primary = deviceCurrent("output")
    var raw = (devicesData && devicesData.selected) ? devicesData.selected.outputs : null
    var out = []
    if (!raw || typeof raw.length !== "number") {
      if (primary !== "") out.push(primary)
      return out
    }
    for (var i = 0; i < raw.length; i++) {
      var name = resolveOutputName(raw[i])
      if (name !== "" && out.indexOf(name) === -1) out.push(name)
    }
    if (out.length === 0 && primary !== "") out.push(primary)
    return out
  }
  function outputIsSelected(name) {
    return deviceSelectedOutputs().indexOf(String(name || "")) !== -1
  }
  function additionalOutputs() {
    var primary = deviceCurrent("output")
    var list = deviceList("output")
    var out = []
    for (var i = 0; i < list.length; i++)
      if (String(list[i].name) !== primary) out.push(list[i])
    return out
  }
  function showOutputNotice(message) {
    root.outputNotice = String(message)
    outputNoticeTimer.restart()
  }
  function toggleOutput(name) {
    var target = String(name || "")
    if (target === "") return
    if (root.outputIsSelected(target)) {
      if (root.deviceSelectedOutputs().length <= 1) {
        root.showOutputNotice("Keep at least one output selected.")
        return
      }
      run(["device", "output-remove", target])
    } else {
      run(["device", "output-add", target])
    }
    root.outputNotice = ""
    refreshSoon()
  }

  readonly property bool dropdownOpen: ddOutput.popupOpen || ddInput.popupOpen
    || ddDefaultSource.popupOpen || ddDefaultSink.popupOpen

  // ---- control lists -------------------------------------------------------
  readonly property var controls: {
    var list = []
    list.push({ kind: "mute", which: "input" })
    list.push({ kind: "mute", which: "output" })
    list.push({ kind: "micfx" })
    for (var i = 0; i < channelIds.length; i++) {
      var id = channelIds[i]
      var apps = channelApps(id)
      list.push({ kind: "send", channel: id, send: "output" })
      list.push({ kind: "send", channel: id, send: "input" })
      for (var j = 0; j < apps.length; j++) list.push({ kind: "app", channel: id, app: apps[j] })
      list.push({ kind: "addapp", channel: id })
      list.push({ kind: "delete", channel: id })
    }
    list.push({ kind: "add" })
    list.push({ kind: "device", key: "output" })
    list.push({ kind: "device", key: "input" })
    list.push({ kind: "device", key: "defaultSource" })
    list.push({ kind: "device", key: "defaultSink" })
    return list
  }

  readonly property var pickApps: {
    var seen = ({})
    var out = []
    function add(name) {
      var n = String(name || "")
      if (n === "") return
      var k = n.toLowerCase()
      if (seen[k]) return
      seen[k] = true
      out.push({ name: n, channel: String(root.rules[k] || "") })
    }
    for (var i = 0; i < appData.length; i++) add(appData[i].app)
    for (var k in root.rules) add(k)
    out.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
    return out
  }

  readonly property var pickControls: {
    var list = []
    for (var i = 0; i < pickApps.length; i++) list.push({ kind: "pickapp", app: pickApps[i].name })
    return list
  }

  readonly property var activeControls: view === "pick" ? pickControls : controls

  function findControl(parts) {
    for (var i = 0; i < activeControls.length; i++) {
      var c = activeControls[i]
      var ok = true
      for (var key in parts) if (c[key] !== parts[key]) ok = false
      if (ok) return i
    }
    return -1
  }
  readonly property int ctlMic: findControl({ kind: "mute", which: "input" })
  readonly property int ctlSpk: findControl({ kind: "mute", which: "output" })
  readonly property int ctlMicFx: findControl({ kind: "micfx" })
  readonly property int ctlAdd: controls.length - 5
  readonly property int ctlOutput: controls.length - 4
  readonly property int ctlInput: controls.length - 3
  readonly property int ctlDefaultSource: controls.length - 2
  readonly property int ctlDefaultSink: controls.length - 1

  // ---- commands ------------------------------------------------------------
  property var queue: []
  property string cmdTag: ""
  // Completed commands are queued so a command that exits while the next one
  // is being started cannot lose its tag/exit status. `pump()` never clears it;
  // the runningChanged handler consumes one entry per finished command.
  property var finishedCommands: []

  // run() accepts an optional tag so a queued command can be identified when
  // it exits (the structural fx commands need their own completion handling).
  function run(args, tag) {
    queue = queue.concat([{ args: args, tag: String(tag || "") }])
    pump()
  }
  function pump() {
    if (cmd.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    root.cmdTag = String(next.tag || "")
    cmd.command = [root.bin].concat(next.args)
    cmd.running = true
    if (root.cmdTag === "fxapply") fxApplyWatchdog.restart()
  }
  function refreshSoon() { settle.restart() }

  function setVolume(id, send, value) {
    run(["send", id, send, "volume", String(Math.max(0, Math.min(100, Math.round(value))))])
    refreshSoon()
  }
  function toggleSend(id, send) {
    run(["send", id, send, sendOn(id, send) ? "off" : "on"])
    refreshSoon()
  }
  function addChannel() {
    run(["channel", "add", "Channel " + (channelIds.length + 1)])
    run(["up"])
    refreshSoon()
  }
  function deleteChannel(id) {
    run(["channel", "remove", id])
    run(["up"])
    refreshSoon()
  }
  function deviceCommand(key, name) {
    if (key === "output") return ["device", "output", name]
    if (key === "input") return ["device", "input", name]
    if (key === "defaultSource") return ["default", "source", name]
    if (key === "defaultSink") return ["default", "sink", name]
    return null
  }
  function cycleDevice(key, dir) {
    var list = deviceList(key)
    if (list.length < 2) return
    var cur = deviceCurrent(key)
    var at = 0
    for (var i = 0; i < list.length; i++) if (list[i].name === cur) at = i
    var cmd = deviceCommand(key, list[(at + dir + list.length) % list.length].name)
    if (cmd) { run(cmd); refreshSoon() }
  }
  function openPicker(id) {
    pickChannel = id
    view = "pick"
    cursorIndex = 0
    refreshApps()
  }
  function closePicker() { view = "main" }
  function assignApp(app, id) {
    if (!app || !id) return
    run(["route", app, id])
    refreshSoon()
    view = "main"
  }
  function unrouteApp(app) {
    run(["unroute", app])
    refreshSoon()
  }

  // ---- cursor --------------------------------------------------------------
  function clampCursor() {
    var n = activeControls.length
    cursorIndex = n === 0 ? 0 : Math.max(0, Math.min(n - 1, cursorIndex))
  }
  onControlsChanged: root.clampCursor()
  onActiveControlsChanged: root.clampCursor()

  function moveCursor(dx, dy) {
    var list = activeControls
    if (list.length === 0) return
    if (dy !== 0) {
      cursorIndex = Math.max(0, Math.min(list.length - 1, cursorIndex + dy))
      return
    }
    if (dx === 0) return
    var c = list[cursorIndex]
    if (!c) return
    if (c.kind === "send") setVolume(c.channel, c.send, sendVol(c.channel, c.send) + dx * 5)
  }

  function activate() {
    var c = activeControls[cursorIndex]
    if (!c) return
    if (c.kind === "send") toggleSend(c.channel, c.send)
    else if (c.kind === "add") addChannel()
    else if (c.kind === "delete") deleteChannel(c.channel)
    else if (c.kind === "app") unrouteApp(c.app)
    else if (c.kind === "addapp") openPicker(c.channel)
    else if (c.kind === "mute") root.toggleMute(c.which)
    else if (c.kind === "micfx") root.toggleMicFx()
    else if (c.kind === "device") root.openDeviceDropdown(c.key)
    else if (c.kind === "pickapp") assignApp(c.app, pickChannel)
  }

  // ---- polling -------------------------------------------------------------
  function refresh() { if (!statusProc.running) statusProc.running = true }
  function refreshDevices() { if (!devicesProc.running) devicesProc.running = true }
  function refreshApps() { if (!appsProc.running) appsProc.running = true }
  function refreshMutes() { if (!mutesProc.running) mutesProc.running = true }
  function toggleMute(which) {
    run(["mute", which, "toggle"])
    refreshSoon()
    Qt.callLater(root.refreshMutes)
  }
  function toggleMicFx() {
    run(["micfx", "toggle"])
    refreshSoon()
  }
  function fxPluginName(id) {
    var key = String(id || "")
    for (var i = 0; i < root.fxPlugins.length; i++)
      if (String(root.fxPlugins[i].id) === key)
        return String(root.fxPlugins[i].name || key)
    return key === "" ? "Unknown effect" : key
  }
  function clampFxSelection() {
    var chain = root.fxChain
    if (chain.length === 0) {
      if (root.fxSelected !== "") root.fxSelected = ""
      return
    }
    for (var i = 0; i < chain.length; i++) {
      var entry = chain[i]
      if (entry && String(entry.instance) === root.fxSelected) return
    }
    root.fxSelected = String(chain[0].instance || "")
  }
  onFxChainChanged: root.clampFxSelection()

  function selectFx(instance) {
    root.fxSelected = String(instance || "")
  }
  function openFxAdd() {
    if (!root.fxData || root.fxApplying) return
    root.fxView = "add"
    fxPluginScroll.contentY = 0
  }
  function closeFxAdd() { root.fxView = "chain" }
  function fxMutate(args) {
    if (root.fxApplying) return
    root.fxError = ""
    root.fxApplying = true
    run(args, "fxapply")
  }
  function fxAddEffect(pluginId) {
    if (root.fxApplying || !root.fxData) return
    root.fxView = "chain"
    root.fxMutate(["fx", "add", String(pluginId)])
  }
  function fxToggleEffect(instance) {
    root.fxMutate(["fx", "toggle", String(instance)])
  }
  function fxRemoveEffect(instance) {
    root.fxMutate(["fx", "remove", String(instance)])
  }
  function fxMoveEffect(instance, direction) {
    if (direction !== "up" && direction !== "down") return
    root.fxMutate(["fx", "move", String(instance), direction])
  }
  function fxShortError(text) {
    var lines = String(text || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line !== "") return line
    }
    return ""
  }
  function finishFxCommand(exitCode) {
    fxApplyWatchdog.stop()
    root.fxApplying = false
    if (exitCode !== 0) {
      var detail = root.fxShortError(cmdErr.text)
      root.fxError = detail !== ""
        ? "Could not change effects: " + detail
        : "Could not change effects."
    } else {
      root.fxError = ""
    }
    fxRefreshSoon.restart()
  }
  function refreshFxState() {
    if (fxStateProc.running) {
      root.fxRefreshPending = true
      return
    }
    fxStateProc.running = true
  }
  function openMicFx() {
    if (root.opened) root.close()
    root.fxView = "chain"
    root.fxError = ""
    root.fxLoadError = ""
    root.fxOpen = true
    root.refreshFxState()
  }
  function toggleFxMaster() {
    if (!root.fxData || root.fxApplying) return
    run(["fx", root.fxEnabled ? "disable" : "enable"])
  }
  function setMicFx(key, value) {
    run(["micfx", "set", key, String(value)])
    fxRefreshSoon.restart()
  }

  implicitWidth: icons.implicitWidth
  implicitHeight: icons.implicitHeight

  onFxOpenChanged: if (fxOpen) root.refreshFxState()

  onOpenedChanged: {
    if (opened) {
      root.fxOpen = false
      view = "main"
      cursorIndex = 0
      editing = false
      outputNotice = ""
      refresh()
      refreshDevices()
    }
  }

  IpcHandler {
    target: "mnisyif.wavemix"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh(); root.refreshDevices() }
    function mute(which: string): void { root.toggleMute(which) }
    function micfx(): void { root.openMicFx() }
    function fx(): void { root.openMicFx() }
    function micfxset(key: string, value: string): void { root.setMicFx(key, value) }
  }

  Process {
    id: statusProc
    command: [root.bin, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.statusData = JSON.parse(text) } catch (e) {} }
    }
  }

  Process {
    id: devicesProc
    command: [root.bin, "devices", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.devicesData = JSON.parse(text) } catch (e) {} }
    }
  }

  Process {
    id: appsProc
    command: [root.bin, "apps", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.appData = JSON.parse(text) } catch (e) {} }
    }
  }

  Process {
    id: mutesProc
    command: [root.bin, "mutes"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.mutes = JSON.parse(text) } catch (e) {} }
    }
  }

  Process {
    id: fxStateProc
    command: [root.bin, "fx", "state", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.fxData = JSON.parse(text)
          root.fxLoadError = ""
        } catch (e) {
          root.fxLoadError = "Could not load effects."
        }
      }
    }
    stderr: StdioCollector {
      id: fxStateErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var detail = root.fxShortError(fxStateErr.text)
        root.fxLoadError = detail !== ""
          ? "Could not load effects: " + detail
          : "Could not load effects."
      }
      if (root.fxRefreshPending) {
        root.fxRefreshPending = false
        Qt.callLater(root.refreshFxState)
      }
    }
  }

  Process {
    id: cmd
    stderr: StdioCollector {
      id: cmdErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      // Capture the tag at signal time; a later run()/pump() must not be able
      // to change which command this exit belongs to.
      root.finishedCommands = root.finishedCommands.concat([
        { tag: root.cmdTag, code: exitCode }
      ])
    }
    onRunningChanged: {
      if (running) return
      // Capture the tag now, before a deferred callback can be preceded by a
      // new run() that starts another command.
      var endedTag = root.cmdTag
      Qt.callLater(function() {
        var finished = null
        if (root.finishedCommands.length > 0) {
          finished = root.finishedCommands[0]
          root.finishedCommands = root.finishedCommands.slice(1)
        }
        if (finished) {
          if (finished.tag === "fxapply") root.finishFxCommand(finished.code)
        } else if (endedTag === "fxapply") {
          // No exit record: the command could not start. Clear the applying
          // state instead of leaving every control disabled.
          root.finishFxCommand(-1)
        }
        root.pump()
        // After the queue drains (and nothing else took its place), refresh the
        // chain. Testing queue.length here would schedule a refresh while the
        // next command is already running.
        if (root.fxOpen && !cmd.running) fxRefreshSoon.restart()
      })
    }
  }

  Timer {
    id: fxApplyWatchdog
    interval: 45000
    repeat: false
    onTriggered: if (root.fxApplying) root.finishFxCommand(-1)
  }

  Timer {
    id: settle
    interval: 250
    repeat: false
    onTriggered: { root.refresh(); root.refreshDevices(); root.refreshMutes() }
  }

  Timer {
    id: outputNoticeTimer
    interval: 4000
    repeat: false
    onTriggered: root.outputNotice = ""
  }

  Timer {
    id: fxRefreshSoon
    interval: 500
    repeat: false
    onTriggered: root.refreshFxState()
  }

  Timer {
    interval: 1500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshMutes()
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 1000
    running: root.opened && root.view === "pick"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshApps()
  }

  // Two independent icon buttons so the bar routes a click to the one under
  // the cursor (a plain MouseArea inside one widget never sees the click - the
  // bar dispatches to registered click targets by position).
  Row {
    id: icons
    anchors.centerIn: parent
    spacing: 0

    WidgetButton {
      id: micButton
      bar: root.bar
      labelVisible: true
      text: root.mutes.input ? root.micOff : root.micOn
      fontSize: Style.bar.iconFont
      foreground: root.mutes.input ? Qt.darker(root.foreground, 1.7) : root.foreground
      fixedWidth: root.iconCell
      tooltipText: "Microphone - left-click mute · right-click mixer · middle-click noise settings"
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) root.toggle()
        else if (buttonCode === Qt.MiddleButton) root.openMicFx()
        else if (buttonCode === Qt.LeftButton) root.toggleMute("input")
      }
    }

    WidgetButton {
      id: spkButton
      bar: root.bar
      labelVisible: true
      text: root.mutes.output ? root.spkOff : root.spkOn
      fontSize: Style.bar.iconFont
      foreground: root.mutes.output ? Qt.darker(root.foreground, 1.7) : root.foreground
      fixedWidth: root.iconCell
      tooltipText: "Speakers - left-click mute · right-click mixer · middle-click noise settings"
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) root.toggle()
        else if (buttonCode === Qt.MiddleButton) root.openMicFx()
        else if (buttonCode === Qt.LeftButton) root.toggleMute("output")
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: icons
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing || root.dropdownOpen
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activate()
      onCloseRequested: { if (root.view === "pick") root.closePicker(); else root.close() }
      onTextKey: function(t) { if (t === "b" || t === "B") { if (root.view === "pick") root.closePicker() } }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          // ---------------- main ----------------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.view === "main"

            // ---------- Hero: icon · title/status · mute switches ----------
            Item {
              id: hero
              width: parent.width
              implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight,
                                       heroSwitches.implicitHeight)

              Text {
                id: heroIcon
                text: root.heroGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                id: heroSwitches
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(12)

                Row {
                  spacing: Style.space(6)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.mutes.input ? root.micOff : root.micOn
                    color: root.mutes.input ? Qt.darker(root.foreground, 1.7) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                  }

                  ToggleSwitch {
                    id: micSwitch
                    checked: !root.mutes.input
                    hasCursor: root.view === "main" && root.cursorIndex === root.ctlMic
                    foreground: root.foreground
                    onHovered: function(on) { if (on) root.cursorIndex = root.ctlMic }
                    onToggled: root.toggleMute("input")

                    PanelToolTip {
                      visible: micSwitch.containsMouse
                      text: "Microphone - " + (root.mutes.input ? "muted" : "on")
                      fontFamily: root.fontFamily
                    }
                  }
                }

                Row {
                  spacing: Style.space(6)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.mutes.output ? root.spkOff : root.spkOn
                    color: root.mutes.output ? Qt.darker(root.foreground, 1.7) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                  }

                  ToggleSwitch {
                    id: spkSwitch
                    checked: !root.mutes.output
                    hasCursor: root.view === "main" && root.cursorIndex === root.ctlSpk
                    foreground: root.foreground
                    onHovered: function(on) { if (on) root.cursorIndex = root.ctlSpk }
                    onToggled: root.toggleMute("output")

                    PanelToolTip {
                      visible: spkSwitch.containsMouse
                      text: "Speakers - " + (root.mutes.output ? "muted" : "on")
                      fontFamily: root.fontFamily
                    }
                  }
                }
              }

              Column {
                id: heroLabels
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(14)
                anchors.right: heroSwitches.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: "Wavemix"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: root.heroStatus
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "MIC FX"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            FxRow {
              width: parent.width
              controlIndex: root.ctlMicFx
            }

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              visible: root.headroomTrim < 0.999
              text: "AUTO HEADROOM  -" + (20 * Math.log10(1 / root.headroomTrim)).toFixed(1) + " dB"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }

            Text {
              visible: root.channelIds.length === 0
              text: root.statusData ? "No channels." : "Loading…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.channelIds

              ChannelBlock {
                required property string modelData
                required property int index
                width: column.width
                channelId: modelData
                channelIndex: index
              }
            }

            AddRow {
              width: parent.width
              controlIndex: root.ctlAdd
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "DEVICES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Dropdown {
              id: ddOutput
              width: parent.width
              label: "Output"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: root.deviceOptions("output")
              value: root.deviceCurrent("output")
              hasCursor: root.view === "main" && root.cursorIndex === root.ctlOutput
              onHovered: function(h) { if (h) root.cursorIndex = root.ctlOutput }
              onChanged: function(v) { root.setDevice("output", v) }
            }

            PanelSectionHeader {
              text: "Also play to"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              visible: root.additionalOutputs().length === 0
              text: root.devicesData ? "No other outputs connected." : "Loading…"
              textFormat: Text.PlainText
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.additionalOutputs()

              OutputCheckRow {
                required property var modelData
                width: parent.width
                outputName: String(modelData.name)
                outputDescription: String(modelData.description)
                checked: root.outputIsSelected(modelData.name)
              }
            }

            Text {
              width: parent.width
              visible: root.outputNotice !== ""
              text: root.outputNotice
              textFormat: Text.PlainText
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Dropdown {
              id: ddInput
              width: parent.width
              label: "Mic"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: root.deviceOptions("input")
              value: root.deviceCurrent("input")
              hasCursor: root.view === "main" && root.cursorIndex === root.ctlInput
              onHovered: function(h) { if (h) root.cursorIndex = root.ctlInput }
              onChanged: function(v) { root.setDevice("input", v) }
            }

            Dropdown {
              id: ddDefaultSource
              width: parent.width
              label: "Default mic"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: root.deviceOptions("defaultSource")
              value: root.deviceCurrent("defaultSource")
              hasCursor: root.view === "main" && root.cursorIndex === root.ctlDefaultSource
              onHovered: function(h) { if (h) root.cursorIndex = root.ctlDefaultSource }
              onChanged: function(v) { root.setDevice("defaultSource", v) }
            }

            Dropdown {
              id: ddDefaultSink
              width: parent.width
              label: "Default out"
              fontFamily: root.fontFamily
              foreground: root.foreground
              options: root.deviceOptions("defaultSink")
              value: root.deviceCurrent("defaultSink")
              hasCursor: root.view === "main" && root.cursorIndex === root.ctlDefaultSink
              onHovered: function(h) { if (h) root.cursorIndex = root.ctlDefaultSink }
              onChanged: function(v) { root.setDevice("defaultSink", v) }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "j/k  move   ·   h/l  level / device   ·   Enter  toggle / open   ·   Esc  close"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ---------------- picker ----------------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.view === "pick"

            PanelSectionHeader {
              text: "ADD APP TO " + root.channelName(root.pickChannel)
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Type an app name (e.g. firefox)"
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: { root.assignApp(text, root.pickChannel); text = "" }
              Keys.onEscapePressed: { root.editing = false; keyCatcher.forceActiveFocus() }
              onActiveFocusChanged: root.editing = activeFocus
            }

            Text {
              width: parent.width
              text: "Playing now / known apps:"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.pickApps.length === 0
              text: "(nothing playing - type a name above)"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.pickApps

              PickRow {
                required property var modelData
                required property int index
                width: column.width
                appName: modelData.name
                currentChannel: modelData.channel
                controlIndex: index
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "j/k  move   ·   Enter  assign   ·   Esc  back"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }

  // Effects open in their own popup so they stay reachable while the mixer
  // panel is closed. Middle-click either bar icon, or the gear on the
  // Noise suppression row, opens it.
  QtObject {
    id: fxOwner
    function close() { root.fxOpen = false }
  }

  PopupCard {
    id: fxPopup
    anchorItem: icons
    bar: root.bar
    owner: fxOwner
    open: root.fxOpen
    contentWidth: fxPopup.fittedContentWidth(Style.space(380))
    contentHeight: fxPopup.fittedContentHeight(fxColumn.implicitHeight)

    Column {
      id: fxColumn
      anchors.fill: parent
      spacing: Style.space(10)

      Item {
        width: parent.width
        implicitHeight: Math.max(fxHeading.implicitHeight, fxClose.implicitHeight)

        Column {
          id: fxHeading
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            id: fxTitle
            text: "EFFECTS"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            font.letterSpacing: 1.2
          }

          Text {
            id: fxVersion
            text: root.fxVersion !== "" ? "Wavemix " + root.fxVersion : "Wavemix"
            textFormat: Text.PlainText
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          id: fxClose
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: String.fromCodePoint(0xf00d) // nf-fa-times
          color: fxCloseArea.containsMouse ? Color.urgent : Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body

          MouseArea {
            id: fxCloseArea
            anchors.fill: parent
            anchors.margins: -Style.space(5)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.fxOpen = false
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.fxView === "chain"

        Item {
          width: parent.width
          implicitHeight: Math.max(fxMasterLabel.implicitHeight,
                                   fxMasterSwitch.implicitHeight)

          Text {
            id: fxMasterLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Microphone effects"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          ToggleSwitch {
            id: fxMasterSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.fxEnabled
            enabled: root.fxData !== null && !root.fxApplying
            foreground: root.foreground
            onToggled: root.toggleFxMaster()
          }
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          width: parent.width
          visible: root.fxApplying
          text: "Applying… audio restarts briefly"
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.fxError !== ""
          text: root.fxError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.fxLoadError !== ""
          text: root.fxLoadError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.fxData === null && root.fxLoadError === ""
          text: "Loading…"
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: root.fxData !== null && root.fxChain.length === 0
          text: "No effects. Add one."
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.fxChain

          FxChainRow {
            required property var modelData
            required property int index
            width: fxColumn.width
            entry: modelData
            position: index
            count: root.fxChain.length
          }
        }

        PanelSeparator { foreground: root.foreground }

        Item {
          width: parent.width
          implicitHeight: fxAddText.implicitHeight + Style.space(8)

          Text {
            id: fxAddText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: "+  Add effect"
            textFormat: Text.PlainText
            color: (!root.fxData || root.fxApplying)
              ? Qt.darker(root.foreground, 1.8)
              : (fxAddArea.containsMouse ? root.foreground
                                         : Qt.darker(root.foreground, 1.3))
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: fxAddArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.fxData !== null && !root.fxApplying
            cursorShape: fxAddArea.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.openFxAdd()
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.fxView === "add"

        Item {
          width: parent.width
          implicitHeight: fxBackText.implicitHeight + Style.space(4)

          Text {
            id: fxBackText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "‹  Back to effects"
            textFormat: Text.PlainText
            color: fxBackArea.containsMouse ? root.foreground
                                            : Qt.darker(root.foreground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: fxBackArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeFxAdd()
          }
        }

        PanelSectionHeader {
          text: "ADD EFFECT"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          visible: root.fxPlugins.length === 0
          text: "No plugins found."
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Item {
          width: parent.width
          implicitHeight: fxPluginScroll.height

          Flickable {
            id: fxPluginScroll
            width: parent.width
            height: Math.min(fxPluginList.implicitHeight,
                             root.fxAddListMaxHeight)
            contentWidth: width
            contentHeight: fxPluginList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
              id: fxPluginList
              width: fxPluginScroll.width

              Repeater {
                model: root.fxPlugins

                FxPluginRow {
                  required property var modelData
                  width: fxPluginList.width
                  plugin: modelData
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
    id: chainRow
    property var entry: null
    property int position: 0
    property int count: 0

    readonly property string pluginId: (chainRow.entry && chainRow.entry.plugin)
      ? String(chainRow.entry.plugin) : ""
    readonly property string instanceId: (chainRow.entry && chainRow.entry.instance)
      ? String(chainRow.entry.instance) : ""
    readonly property string stateText: !chainRow.entry ? ""
      : chainRow.entry.available === false ? "unavailable"
      : chainRow.entry.enabled === false ? "bypassed" : ""

    hasCursor: root.fxSelected === chainRow.instanceId
    foreground: root.foreground
    implicitHeight: Math.max(chainName.implicitHeight,
                             chainActions.implicitHeight) + Style.space(8)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.selectFx(chainRow.instanceId)
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(6)

      Text {
        id: chainName
        width: Math.max(0, parent.width - chainActions.width
          - (chainState.visible ? chainState.width + parent.spacing : 0)
          - parent.spacing)
        anchors.verticalCenter: parent.verticalCenter
        text: root.fxPluginName(chainRow.pluginId)
          + (chainRow.instanceId !== "" ? " · " + chainRow.instanceId : "")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: chainRow.entry && chainRow.entry.enabled === false
          ? Qt.darker(root.foreground, 1.6) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: chainState
        anchors.verticalCenter: parent.verticalCenter
        visible: chainRow.stateText !== ""
        text: chainRow.stateText
        textFormat: Text.PlainText
        color: chainRow.entry && chainRow.entry.available === false
          ? Color.urgent : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        id: chainActions
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: chainRow.entry && chainRow.entry.enabled === false
            ? String.fromCodePoint(0xf070) // nf-fa-eye_slash
            : String.fromCodePoint(0xf06e) // nf-fa-eye
          tooltipText: chainRow.entry && chainRow.entry.enabled === false
            ? "Enable effect" : "Bypass effect"
          enabled: !root.fxApplying
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.fxToggleEffect(chainRow.instanceId)
        }

        PanelActionButton {
          iconText: String.fromCodePoint(0xf077) // nf-fa-chevron_up
          tooltipText: "Move up"
          enabled: !root.fxApplying && chainRow.position > 0
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.fxMoveEffect(chainRow.instanceId, "up")
        }

        PanelActionButton {
          iconText: String.fromCodePoint(0xf078) // nf-fa-chevron_down
          tooltipText: "Move down"
          enabled: !root.fxApplying && chainRow.position < chainRow.count - 1
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.fxMoveEffect(chainRow.instanceId, "down")
        }

        PanelActionButton {
          iconText: String.fromCodePoint(0xf00d) // nf-fa-times
          tooltipText: "Remove effect"
          enabled: !root.fxApplying
          foreground: root.foreground
          hoverColor: Color.urgent
          fontFamily: root.fontFamily
          onClicked: root.fxRemoveEffect(chainRow.instanceId)
        }
      }
    }
  }

  component FxPluginRow: CursorSurface {
    id: pluginRow
    property var plugin: null

    readonly property bool available: pluginRow.plugin
      ? pluginRow.plugin.available === true : false
    readonly property bool gpu: pluginRow.plugin
      ? pluginRow.plugin.gpu === true : false
    readonly property string pluginId: pluginRow.plugin
      ? String(pluginRow.plugin.id || "") : ""
    readonly property string pluginName: pluginRow.plugin
      ? String(pluginRow.plugin.name || pluginRow.pluginId) : ""
    readonly property string pluginVersion: pluginRow.plugin
      ? String(pluginRow.plugin.version || "") : ""
    readonly property string pluginSource: pluginRow.plugin
      ? String(pluginRow.plugin.source || "") : ""
    readonly property string pluginDescription: pluginRow.plugin
      ? String(pluginRow.plugin.description || "") : ""
    readonly property string pluginRequires: pluginRow.plugin
      ? String(pluginRow.plugin.requires || "") : ""
    readonly property string pluginError: pluginRow.plugin
      ? String(pluginRow.plugin.error || "") : ""

    hasCursor: pluginRow.available && pluginMouse.containsMouse
    foreground: root.foreground
    implicitHeight: pluginBody.implicitHeight + Style.space(12)

    Column {
      id: pluginBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          id: addName
          width: Math.max(0, parent.width - addVersion.width
            - (addGpu.visible ? addGpu.width + parent.spacing : 0)
            - parent.spacing)
          anchors.verticalCenter: parent.verticalCenter
          text: pluginRow.pluginName
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: pluginRow.available ? root.foreground
                                     : Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          id: addGpu
          anchors.verticalCenter: parent.verticalCenter
          visible: pluginRow.gpu
          text: "GPU"
          textFormat: Text.PlainText
          color: pluginRow.available ? Color.accent
                                     : Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          id: addVersion
          anchors.verticalCenter: parent.verticalCenter
          text: pluginRow.pluginVersion !== ""
            ? "v" + pluginRow.pluginVersion : ""
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        width: parent.width
        visible: pluginRow.pluginDescription !== ""
        text: pluginRow.pluginDescription
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: pluginRow.available ? Qt.darker(root.foreground, 1.2)
                                   : Qt.darker(root.foreground, 1.9)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        text: pluginRow.pluginSource
          + (pluginRow.available ? "" : " · unavailable")
        textFormat: Text.PlainText
        color: pluginRow.available ? Qt.darker(root.foreground, 1.5)
                                   : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: pluginRow.pluginRequires !== ""
        text: pluginRow.pluginRequires
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: pluginRow.pluginError !== ""
        text: pluginRow.pluginError
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: pluginMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: pluginRow.available
      cursorShape: pluginRow.available ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.fxAddEffect(pluginRow.pluginId)
    }
  }

  component CheckBox: Item {
    id: box
    property bool checked: false
    // Off when the surrounding row owns the click (the Also play to rows).
    property bool interactive: true
    signal toggled()

    implicitWidth: Style.space(16)
    implicitHeight: Style.space(16)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(2)
      color: "transparent"
      border.width: Math.max(1, Style.space(1))
      border.color: root.foreground
    }

    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 0.55
      height: parent.height * 0.55
      radius: Style.space(1)
      color: root.foreground
      visible: box.checked
    }

    MouseArea {
      anchors.fill: parent
      enabled: box.interactive
      cursorShape: Qt.PointingHandCursor
      onClicked: box.toggled()
    }
  }

  component OutputCheckRow: Item {
    id: outRow
    property string outputName: ""
    property string outputDescription: ""
    property bool checked: false

    implicitHeight: outLabel.implicitHeight + Style.space(8)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      CheckBox {
        anchors.verticalCenter: parent.verticalCenter
        checked: outRow.checked
        interactive: false
      }

      Text {
        id: outLabel
        width: parent.width - Style.space(16) - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        text: outRow.outputDescription !== "" ? outRow.outputDescription : outRow.outputName
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleOutput(outRow.outputName)
    }
  }

  component ChannelMeter: Item {
    id: meter
    property real level: 0
    property real held: 0

    implicitHeight: Math.max(Style.space(3), 3)

    onLevelChanged: {
      if (level >= held) {
        held = level
        holdTimer.restart()
        decayTimer.stop()
      }
    }

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: Util.alpha(root.foreground, 0.18)
      clip: true

      Rectangle {
        height: parent.height
        width: parent.width * Math.max(0, Math.min(1, meter.level))
        radius: height / 2
        color: root.foreground
        Behavior on width { NumberAnimation { duration: Style.duration(70) } }
      }
    }

    // Peak hold: stays put briefly, then falls back to the live level.
    Rectangle {
      visible: meter.held > 0.01
      width: Math.max(Style.space(2), 2)
      height: parent.height
      radius: width / 2
      color: root.foreground
      x: Math.max(0, Math.min(meterTrack.width - width,
                               meterTrack.width * Math.max(0, Math.min(1, meter.held)) - width / 2))
    }

    Timer {
      id: holdTimer
      interval: 700
      repeat: false
      onTriggered: decayTimer.restart()
    }

    Timer {
      id: decayTimer
      interval: 40
      repeat: true
      onTriggered: {
        meter.held = Math.max(meter.level, meter.held - 0.02)
        if (meter.held <= meter.level) {
          meter.held = meter.level
          decayTimer.stop()
        }
      }
    }
  }

  component SendRow: CursorSurface {
    id: row
    property string channelId: ""
    property string sendName: "output"
    property int controlIndex: 0

    readonly property bool on: root.sendOn(channelId, sendName)
    readonly property int volume: root.sendVol(channelId, sendName)
    readonly property int outputCount: root.deviceSelectedOutputs().length
    readonly property string sendLabel: sendName === "output"
      ? (outputCount > 1 ? "out ×" + outputCount : "out")
      : "stream"

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    implicitHeight: slider.implicitHeight + Style.space(4)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      CheckBox {
        anchors.verticalCenter: parent.verticalCenter
        checked: row.on
        onToggled: root.toggleSend(row.channelId, row.sendName)
      }

      Text {
        width: Style.space(46)
        anchors.verticalCenter: parent.verticalCenter
        text: row.sendLabel
        textFormat: Text.PlainText
        color: row.on ? root.foreground : Qt.darker(root.foreground, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSlider {
        id: slider
        width: parent.width - (Style.space(16) + Style.space(46) + Style.space(38) + parent.spacing * 3)
        anchors.verticalCenter: parent.verticalCenter
        bar: root.bar
        minimum: 0
        maximum: 100
        step: 5
        integer: true
        value: row.volume
        onReleased: function(v) { root.setVolume(row.channelId, row.sendName, v) }
      }

      Text {
        width: Style.space(38)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: (slider.dragging ? Math.round(slider.liveValue) : row.volume) + "%"
        color: row.on ? root.foreground : Qt.darker(root.foreground, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = row.controlIndex
    }
  }

  component ChannelBlock: Column {
    id: block
    property string channelId: ""
    property int channelIndex: 0

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    readonly property var apps: root.channelApps(block.channelId)
    readonly property int deleteIndex: root.findControl({ kind: "delete", channel: block.channelId })
    readonly property int addAppIndex: root.findControl({ kind: "addapp", channel: block.channelId })
    readonly property var peakNode: root.channelPeakNode(block.channelId)

    PwNodePeakMonitor {
      id: channelPeak
      node: block.peakNode
      enabled: root.opened
    }

    // header: name · source · delete
    Item {
      width: parent.width
      height: Math.max(nameText.implicitHeight, deleteText.implicitHeight)

      Text {
        id: nameText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.channelName(block.channelId)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        anchors.right: deleteText.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: root.channelIsMic(block.channelId) ? "microphone" : "apps"
        color: Qt.darker(root.foreground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: deleteText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: String.fromCodePoint(0xf00d) // nf-fa-times
        color: deleteArea.containsMouse ? Color.urgent : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        MouseArea {
          id: deleteArea
          anchors.fill: parent
          anchors.margins: -Style.space(5)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) root.cursorIndex = block.deleteIndex
          onClicked: root.deleteChannel(block.channelId)
        }
      }
    }

    ChannelMeter {
      width: parent.width
      level: channelPeak.peak
    }

    SendRow {
      width: parent.width
      channelId: block.channelId
      sendName: "output"
      controlIndex: root.findControl({ kind: "send", channel: block.channelId, send: "output" })
    }

    SendRow {
      width: parent.width
      channelId: block.channelId
      sendName: "input"
      controlIndex: root.findControl({ kind: "send", channel: block.channelId, send: "input" })
    }

    // apps assigned to this channel
    Row {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: block.apps

        AppChip {
          required property string modelData
          app: modelData
          controlIndex: root.findControl({ kind: "app", channel: block.channelId, app: modelData })
        }
      }

      AddAppChip {
        controlIndex: block.addAppIndex
        channelId: block.channelId
      }
    }
  }

  component AppChip: CursorSurface {
    id: chip
    property string app: ""
    property int controlIndex: 0

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    implicitWidth: chipText.implicitWidth + Style.space(16)
    implicitHeight: chipText.implicitHeight + Style.space(6)
    outline: true

    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.app + "  " + String.fromCodePoint(0xf00d)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = chip.controlIndex
      onClicked: root.unrouteApp(chip.app)
    }
  }

  component AddAppChip: CursorSurface {
    id: addApp
    property int controlIndex: 0
    property string channelId: ""

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    implicitWidth: addAppText.implicitWidth + Style.space(16)
    implicitHeight: addAppText.implicitHeight + Style.space(6)
    outline: true

    Text {
      id: addAppText
      anchors.centerIn: parent
      text: "+ app"
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = addApp.controlIndex
      onClicked: root.openPicker(addApp.channelId)
    }
  }

  component FxRow: CursorSurface {
    id: fxRow
    property int controlIndex: 0

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    implicitHeight: fxLabel.implicitHeight + Style.space(10)

    Text {
      id: fxLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: "Noise suppression"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    ToggleSwitch {
      id: fxSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      interactive: false
      checked: root.micFxOn
      hasCursor: root.view === "main" && root.cursorIndex === fxRow.controlIndex
      foreground: root.foreground
    }

    Text {
      id: fxGear
      z: 2
      anchors.right: fxSwitch.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: String.fromCodePoint(0xf013) // nf-fa-cog
      color: fxGearArea.containsMouse ? root.foreground : Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body

      MouseArea {
        id: fxGearArea
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openMicFx()
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = fxRow.controlIndex
      onClicked: root.toggleMicFx()
    }
  }

  component AddRow: CursorSurface {
    id: addRow
    property int controlIndex: 0

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    implicitHeight: addText.implicitHeight + Style.space(8)

    Text {
      id: addText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      text: "+  Add channel"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = addRow.controlIndex
      onClicked: root.addChannel()
    }
  }

  component PickerRow: CursorSurface {
    id: picker
    property string deviceKey: "output"
    property string label: ""
    property int controlIndex: 0

    readonly property var list: root.deviceList(deviceKey)
    readonly property bool canCycle: list.length > 1

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    implicitHeight: pickerRow.implicitHeight + Style.space(8)

    Row {
      id: pickerRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        width: Style.space(74)
        text: picker.label
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width - Style.space(74) - Style.space(40) - parent.spacing * 2
        text: root.deviceLabel(picker.deviceKey)
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: Style.space(40)
        horizontalAlignment: Text.AlignRight
        visible: picker.canCycle
        text: "◂ ▸"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: picker.canCycle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = picker.controlIndex
      onClicked: root.cycleDevice(picker.deviceKey, 1)
    }
  }

  component PickRow: CursorSurface {
    id: pick
    property string appName: ""
    property string currentChannel: ""
    property int controlIndex: 0

    hasCursor: root.view === "pick" && root.cursorIndex === controlIndex
    foreground: root.foreground
    implicitHeight: pickName.implicitHeight + Style.space(8)

    Text {
      id: pickName
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      text: pick.appName
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: pick.currentChannel === "" ? "unassigned" : root.channelName(pick.currentChannel)
      color: Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = pick.controlIndex
      onClicked: root.assignApp(pick.appName, root.pickChannel)
    }
  }
}
