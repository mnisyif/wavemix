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
  readonly property string effectSummary: {
    var chain = (fxState && fxState.chain) ? fxState.chain : []
    var plugins = (fxState && fxState.plugins) ? fxState.plugins : []
    var names = ({})
    for (var i = 0; i < plugins.length; i++)
      names[String(plugins[i].id)] = String(plugins[i].name)
    var active = []
    for (var j = 0; j < chain.length; j++) {
      var entry = chain[j]
      if (entry && entry.enabled !== false && entry.available !== false)
        active.push(String(names[String(entry.plugin)] || entry.plugin))
    }
    return active.length > 0 ? active.join(" → ") : "No effects enabled"
  }
  readonly property string effectStatus: (micFxOn ? "On" : "Bypassed") + " · " + effectSummary
  // Five channels fit before the list starts scrolling. The viewport is built
  // from the real card heights, so app chips and long names still count.
  readonly property real mixerContentHeight: {
    if (!channelsHeader) return 0
    var h = channelsHeader.implicitHeight + Style.space(8)
    if (root.channelIds.length === 0) {
      if (emptyText) h += emptyText.implicitHeight + Style.space(8)
    } else {
      var count = channelRepeater ? Math.min(5, channelRepeater.count) : 0
      for (var i = 0; i < count; i++) {
        var card = channelRepeater.itemAt(i)
        if (card) h += card.height + Style.space(8)
      }
      if (root.channelIds.length <= 5 && addRow)
        h += addRow.height + Style.space(8)
    }
    return h
  }
  readonly property string heroStatus: {
    var cur = deviceCurrent("defaultSource")
    var list = deviceList("defaultSource")
    for (var i = 0; i < list.length; i++)
      if (list[i].name === cur) return "DEFAULT MIC: " + String(list[i].description).toUpperCase()
    return "DEFAULT MIC: " + String(cur).toUpperCase()
  }
  // Hover tooltip: state first, the real device second, the three actions last.
  // The bubble is the shell's own, so this is copy and hierarchy only.
  function tooltipDevice(key) {
    if (!devicesData) return ""
    var label = deviceLabel(key)
    return label === "(none)" ? "" : label
  }
  readonly property string micDevice: tooltipDevice("input")
  readonly property string speakerDevice: tooltipDevice("output")
  readonly property string micTooltip: "Microphone " + (mutes.input ? "muted" : "on")
    + (micDevice !== "" ? "\n" + micDevice : "")
    + "\nLeft-click: " + (mutes.input ? "unmute" : "mute")
    + "\nRight-click: mixer  ·  Middle-click: effects"
  readonly property string speakerTooltip: "Speakers " + (mutes.output ? "muted" : "on")
    + (speakerDevice !== "" ? "\n" + speakerDevice : "")
    + "\nLeft-click: " + (mutes.output ? "unmute" : "mute")
    + "\nRight-click: mixer  ·  Middle-click: effects"

  property var statusData: null
  property var devicesData: null
  property var appData: []
  property int cursorIndex: 0
  property string view: "main" // "main" | "pick"
  property string tab: "mixer" // "mixer" | "effects" | "devices"
  readonly property var tabNames: ["mixer", "effects", "devices"]
  readonly property int tabIndex: Math.max(0, tabNames.indexOf(tab))
  property var fxState: null
  property string pickChannel: ""
  property bool editing: false
  // Short-lived feedback for the multi-output picker (the last output cannot
  // be removed, so the click is refused rather than sent to the CLI).
  property string outputNotice: ""

  // Load the device names once so the first hover already has the real device.
  Component.onCompleted: root.refreshDevices()

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
    list.push({ kind: "tabs" })
    if (tab === "mixer") {
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
    } else if (tab === "effects") {
      list.push({ kind: "micfx" })
      list.push({ kind: "openfx" })
    } else if (tab === "devices") {
      list.push({ kind: "device", key: "output" })
      list.push({ kind: "device", key: "input" })
      list.push({ kind: "device", key: "defaultSource" })
      list.push({ kind: "device", key: "defaultSink" })
    }
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

  readonly property var activeControls: {
    if (view !== "pick") return controls
    var list = [{ kind: "mute", which: "input" }, { kind: "mute", which: "output" }]
    var picks = pickControls
    if (picks) for (var i = 0; i < picks.length; i++) list.push(picks[i])
    return list
  }

  function findControl(parts) {
    var list = activeControls
    if (!list) return -1
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      var ok = true
      for (var key in parts) if (c[key] !== parts[key]) ok = false
      if (ok) return i
    }
    return -1
  }
  readonly property int ctlMic: findControl({ kind: "mute", which: "input" })
  readonly property int ctlSpk: findControl({ kind: "mute", which: "output" })
  readonly property int ctlTabs: findControl({ kind: "tabs" })
  readonly property int ctlMicFx: findControl({ kind: "micfx" })
  readonly property int ctlOpenFx: findControl({ kind: "openfx" })
  readonly property int ctlAdd: findControl({ kind: "add" })
  readonly property int ctlOutput: findControl({ kind: "device", key: "output" })
  readonly property int ctlInput: findControl({ kind: "device", key: "input" })
  readonly property int ctlDefaultSource: findControl({ kind: "device", key: "defaultSource" })
  readonly property int ctlDefaultSink: findControl({ kind: "device", key: "defaultSink" })

  // ---- commands ------------------------------------------------------------
  property var queue: []

  function run(args) {
    queue = queue.concat([args])
    pump()
  }
  function pump() {
    if (cmd.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    cmd.command = [root.bin].concat(next)
    cmd.running = true
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
  function setTab(name) {
    var next = String(name || "")
    if (root.tabNames.indexOf(next) === -1) return
    root.view = "main"
    if (root.tab !== next) root.tab = next
    root.cursorIndex = Math.max(0, root.ctlTabs)
    if (flick) flick.contentY = 0
  }
  function openPicker(id) {
    pickChannel = id
    view = "pick"
    // The two hero mute switches are the first controls in the picker view.
    cursorIndex = 2
    refreshApps()
  }
  function closePicker() {
    view = "main"
    tab = "mixer"
    cursorIndex = Math.max(0, root.ctlTabs)
  }
  function assignApp(app, id) {
    if (!app || !id) return
    run(["route", app, id])
    refreshSoon()
    view = "main"
    tab = "mixer"
    cursorIndex = Math.max(0, root.ctlTabs)
  }
  function unrouteApp(app) {
    run(["unroute", app])
    refreshSoon()
  }

  // ---- cursor --------------------------------------------------------------
  function clampCursor() {
    var list = activeControls
    if (!list) return
    var n = list.length
    cursorIndex = n === 0 ? 0 : Math.max(0, Math.min(n - 1, cursorIndex))
  }
  onControlsChanged: root.clampCursor()
  onActiveControlsChanged: root.clampCursor()

  function moveCursor(dx, dy) {
    var list = activeControls
    if (!list || list.length === 0) return
    if (dy !== 0) {
      cursorIndex = Math.max(0, Math.min(list.length - 1, cursorIndex + dy))
      return
    }
    if (dx === 0) return
    var c = list[cursorIndex]
    if (!c) return
    if (c.kind === "tabs") {
      var nextTab = root.tabIndex + dx
      if (nextTab >= 0 && nextTab < root.tabNames.length)
        root.setTab(root.tabNames[nextTab])
    } else if (c.kind === "send") {
      setVolume(c.channel, c.send, sendVol(c.channel, c.send) + dx * 5)
    }
  }

  function activate() {
    var list = activeControls
    if (!list) return
    var c = list[cursorIndex]
    if (!c) return
    if (c.kind === "tabs") {
      if (root.ctlTabs >= 0 && root.ctlTabs + 1 < activeControls.length)
        root.cursorIndex = root.ctlTabs + 1
    }
    else if (c.kind === "openfx") root.openMicFx()
    else if (c.kind === "send") toggleSend(c.channel, c.send)
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
  function refreshFxState() { if (!fxStateProc.running) fxStateProc.running = true }
  function toggleMute(which) {
    run(["mute", which, "toggle"])
    refreshSoon()
    Qt.callLater(root.refreshMutes)
  }
  function toggleMicFx() {
    run(["micfx", "toggle"])
    refreshSoon()
  }
  // Kept for the `mnisyif.wavemix micfxset` IPC compatibility hook.
  function setMicFx(key, value) {
    run(["micfx", "set", key, String(value)])
    refreshSoon()
  }
  function openMicFx() {
    if (root.opened) root.close()
    var opened = false
    if (root.bar && root.bar.shell
        && typeof root.bar.shell.toggle === "function")
      opened = root.bar.shell.toggle("mnisyif.wavemix-fx")
    // A third-party bar widget's scoped shell cannot control a separate panel
    // plugin; toggle() returns false in that case. Fall back to the shell CLI.
    if (!opened && root.bar)
      root.bar.run("omarchy-shell shell toggle mnisyif.wavemix-fx")
  }
  implicitWidth: icons.implicitWidth
  implicitHeight: icons.implicitHeight

  onOpenedChanged: {
    if (opened) {
      view = "main"
      tab = "mixer"
      cursorIndex = 0
      editing = false
      outputNotice = ""
      refresh()
      refreshDevices()
      refreshFxState()
      if (flick) flick.contentY = 0
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
    function tab(name: string): void { root.setTab(name) }
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
      onStreamFinished: { try { root.fxState = JSON.parse(text) } catch (e) {} }
    }
  }

  Process {
    id: cmd
    onRunningChanged: if (!running) root.pump()
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
    interval: 1500
    repeat: true
    running: root.opened && root.view === "main" && root.tab === "effects"
    triggeredOnStart: true
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
      tooltipText: root.micTooltip
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
      tooltipText: root.speakerTooltip
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
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(
      hero.implicitHeight
      + (root.view === "main" ? tabs.implicitHeight + Style.space(10) : 0)
      + ((root.view === "main" && root.tab === "mixer")
        ? root.mixerContentHeight : contentColumn.implicitHeight)
      + footer.implicitHeight
      + Style.space(10) * (root.view === "main" ? 3 : 2))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing || root.dropdownOpen
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activate()
      onCloseRequested: { if (root.view === "pick") root.closePicker(); else root.close() }
      onTextKey: function(t) { if (t === "b" || t === "B") { if (root.view === "pick") root.closePicker() } }

      Column {
        id: shellColumn
        anchors.fill: parent
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          iconComponent: Component {
            Text {
              text: root.heroGlyph
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          title: "Wavemix"
          meta: root.heroStatus
          foreground: root.foreground
          fontFamily: root.fontFamily
          trailingControl: Component {
            Row {
              spacing: Style.space(12)

              Item {
                width: fxBadge.implicitWidth
                height: micGroup.implicitHeight

                BorderSurface {
                  id: fxBadge
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: fxText.implicitWidth + Style.space(12)
                  implicitHeight: fxText.implicitHeight + Style.space(4)
                  color: root.micFxOn ? root.foreground : Color.background
                  borderSpec: Border.flat(root.foreground, Math.max(1, Style.space(1)))
                  radius: Style.cornerRadius

                  Text {
                    id: fxText
                    anchors.centerIn: parent
                    text: root.micFxOn ? "FX on" : "FX off"
                    color: root.micFxOn ? Color.background : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }

              Row {
                id: micGroup
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
                  hasCursor: root.cursorIndex === root.ctlMic
                  foreground: root.foreground
                  onHovered: function(on) { if (on) root.cursorIndex = root.ctlMic }
                  onToggled: root.toggleMute("input")

                  PanelToolTip {
                    visible: micSwitch.containsMouse
                    text: "Microphone " + (root.mutes.input ? "muted" : "on")
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
                  hasCursor: root.cursorIndex === root.ctlSpk
                  foreground: root.foreground
                  onHovered: function(on) { if (on) root.cursorIndex = root.ctlSpk }
                  onToggled: root.toggleMute("output")

                  PanelToolTip {
                    visible: spkSwitch.containsMouse
                    text: "Speakers " + (root.mutes.output ? "muted" : "on")
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }
        }

        ButtonGroup {
          id: tabs
          width: parent.width
          visible: root.view === "main"
          options: [
            { value: "mixer", label: "Mixer" },
            { value: "effects", label: "Effects" },
            { value: "devices", label: "Devices" }
          ]
          value: root.tab
          cursorIndex: root.cursorIndex === root.ctlTabs ? root.tabIndex : -1
          focusable: false
          foreground: root.foreground
          background: Color.background
          accent: Color.accent
          fontFamily: root.fontFamily
          onChanged: function(value) { root.setTab(value) }
        }

        Flickable {
          id: flick
          width: parent.width
          height: Math.max(0, shellColumn.height - hero.implicitHeight
            - (tabs.visible ? tabs.implicitHeight : 0)
            - footer.implicitHeight
            - shellColumn.spacing * (tabs.visible ? 3 : 2))
          contentWidth: width
          contentHeight: contentColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: contentColumn
            width: flick.width
            spacing: Style.space(10)

            // ---------------- mixer ----------------
            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.view === "main" && root.tab === "mixer"

              Item {
                id: channelsHeader
                width: parent.width
                implicitHeight: Math.max(channelsTitle.implicitHeight, channelsCount.implicitHeight)

                Text {
                  id: channelsTitle
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Channels"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  id: channelsCount
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.channelIds.length + (root.channelIds.length === 1 ? " channel" : " channels")
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Repeater {
                id: channelRepeater
                model: root.channelIds

                ChannelBlock {
                  required property string modelData
                  required property int index
                  width: parent.width
                  channelId: modelData
                  channelIndex: index
                }
              }

              Text {
                id: emptyText
                width: parent.width
                visible: root.channelIds.length === 0
                text: root.statusData ? "No channels yet." : "Loading…"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              AddRow {
                id: addRow
                width: parent.width
                controlIndex: root.ctlAdd
              }
            }

            // ---------------- effects ----------------
            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.view === "main" && root.tab === "effects"

              SectionCard {
                width: parent.width

                FxRow {
                  width: parent.width
                  controlIndex: root.ctlMicFx
                }

                Text {
                  width: parent.width
                  text: root.effectStatus
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: parent.width
                  visible: root.headroomTrim < 0.999
                  text: "Auto headroom  -" + (20 * Math.log10(1 / root.headroomTrim)).toFixed(1) + " dB"
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                OpenFxRow {
                  width: parent.width
                  controlIndex: root.ctlOpenFx
                }
              }
            }

            // ---------------- devices ----------------
            Column {
              width: parent.width
              spacing: Style.space(10)
              visible: root.view === "main" && root.tab === "devices"

              SectionCard {
                width: parent.width

                Text {
                  text: "Output"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  text: "The mixer's primary output."
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Dropdown {
                  id: ddOutput
                  width: parent.width
                  label: "Primary"
                  fontFamily: root.fontFamily
                  foreground: root.foreground
                  options: root.deviceOptions("output")
                  value: root.deviceCurrent("output")
                  hasCursor: root.view === "main" && root.cursorIndex === root.ctlOutput
                  onHovered: function(h) { if (h) root.cursorIndex = root.ctlOutput }
                  onChanged: function(v) { root.setDevice("output", v) }
                }

                Text {
                  text: "Also play to"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
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
              }

              SectionCard {
                width: parent.width

                Text {
                  text: "Input"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  text: "The physical microphone."
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
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
              }

              SectionCard {
                width: parent.width

                Text {
                  text: "Routing"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  text: "What apps use by default."
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
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
              }
            }

            // ---------------- picker ----------------
            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.view === "pick"

              CursorSurface {
                width: parent.width
                foreground: root.foreground
                implicitHeight: backText.implicitHeight + Style.space(10)

                Text {
                  id: backText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "‹  All channels"
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.closePicker()
                }
              }

              Text {
                width: parent.width
                text: "Add app to " + root.channelName(root.pickChannel)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
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
                text: "Nothing playing. Type a name above."
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: root.pickApps

                PickRow {
                  required property var modelData
                  required property int index
                  width: contentColumn.width
                  appName: modelData.name
                  currentChannel: modelData.channel
                  controlIndex: root.findControl({ kind: "pickapp", app: modelData.name })
                }
              }
            }
          }
        }

        Text {
          id: footer
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.view === "pick"
            ? "j/k  move   ·   Enter  assign   ·   Esc  back"
            : "j/k  move   ·   h/l  tabs / level   ·   Enter  open   ·   Esc  close"
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  // ---------------------------------------------------------------- components

  component SectionCard: BorderSurface {
    id: card
    default property alias content: body.data

    implicitHeight: body.implicitHeight + Style.space(20)
    color: Util.alpha(root.foreground, 0.035)
    borderSpec: Border.flat(Util.alpha(root.foreground, 0.12), 1)
    radius: Style.cornerRadius

    Column {
      id: body
      x: Style.space(10)
      y: Style.space(10)
      width: parent.width - Style.space(20)
      spacing: Style.space(8)
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
      ? (outputCount > 1 ? "Output ×" + outputCount : "Output")
      : "Stream"

    // The status poll can return the pre-command level after a release. Hold
    // the value the user just chose until the server reports it, so the slider
    // does not snap back and forth while the round-trip settles.
    property real pendingVolume: -1
    readonly property real displayVolume: pendingVolume >= 0 ? pendingVolume : row.volume

    onVolumeChanged: {
      if (pendingVolume >= 0 && Math.abs(Number(volume) - pendingVolume) < 0.5)
        pendingVolume = -1
    }
    function commitVolume(value) {
      var next = Math.max(0, Math.min(100, Number(value) || 0))
      pendingVolume = next
      pendingTimer.restart()
      root.setVolume(row.channelId, row.sendName, next)
    }

    Timer {
      id: pendingTimer
      interval: 1500
      repeat: false
      onTriggered: row.pendingVolume = -1
    }

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
        width: Style.space(58)
        anchors.verticalCenter: parent.verticalCenter
        text: row.sendLabel
        textFormat: Text.PlainText
        color: row.on ? root.foreground : Qt.darker(root.foreground, 1.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSlider {
        id: slider
        width: parent.width - (Style.space(16) + Style.space(58) + Style.space(38) + parent.spacing * 3)
        anchors.verticalCenter: parent.verticalCenter
        bar: root.bar
        minimum: 0
        maximum: 100
        step: 5
        integer: true
        value: row.displayVolume
        onReleased: function(v) { row.commitVolume(v) }
      }

      Text {
        width: Style.space(38)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: (slider.dragging ? Math.round(slider.liveValue) : Math.round(row.displayVolume)) + "%"
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

  component ChannelBlock: BorderSurface {
    id: block
    property string channelId: ""
    property int channelIndex: 0

    width: parent ? parent.width : 0
    implicitHeight: body.implicitHeight + Style.space(20)
    color: Util.alpha(root.foreground, 0.035)
    borderSpec: Border.flat(Util.alpha(root.foreground, 0.12), 1)
    radius: Style.cornerRadius

    readonly property var apps: root.channelApps(block.channelId)
    readonly property int deleteIndex: root.findControl({ kind: "delete", channel: block.channelId })
    readonly property int addAppIndex: root.findControl({ kind: "addapp", channel: block.channelId })
    readonly property var peakNode: root.channelPeakNode(block.channelId)

    Column {
      id: body
      x: Style.space(10)
      y: Style.space(10)
      width: parent.width - Style.space(20)
      spacing: Style.space(6)

      PwNodePeakMonitor {
        id: channelPeak
        node: block.peakNode
        enabled: root.opened
      }

      Item {
        width: parent.width
        height: Math.max(nameText.implicitHeight, deleteButton.implicitHeight)

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
          anchors.right: deleteButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.channelIsMic(block.channelId) ? "Microphone" : "Apps"
          color: Qt.darker(root.foreground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          id: deleteButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: String.fromCodePoint(0xf00d) // nf-fa-times
          foreground: root.foreground
          hoverColor: Color.urgent
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          hasCursor: root.cursorIndex === block.deleteIndex
          onHovered: function(on) { if (on) root.cursorIndex = block.deleteIndex }
          onClicked: root.deleteChannel(block.channelId)
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

      Flow {
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
    implicitHeight: Math.max(fxLabel.implicitHeight, fxSwitch.implicitHeight) + Style.space(8)

    Text {
      id: fxLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: "Effects chain"
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

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = fxRow.controlIndex
      onClicked: root.toggleMicFx()
    }
  }

  component OpenFxRow: CursorSurface {
    id: openRow
    property int controlIndex: 0

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    bordered: true
    implicitHeight: openLabel.implicitHeight + Style.space(12)

    Text {
      id: openLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: "Open effects"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: String.fromCodePoint(0xf013) // nf-fa-cog
      color: Qt.darker(root.foreground, 1.35)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorIndex = openRow.controlIndex
      onClicked: root.openMicFx()
    }
  }

  component AddRow: CursorSurface {
    id: addRow
    property int controlIndex: 0

    hasCursor: root.view === "main" && root.cursorIndex === controlIndex
    foreground: root.foreground
    bordered: true
    implicitHeight: addText.implicitHeight + Style.space(12)

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
