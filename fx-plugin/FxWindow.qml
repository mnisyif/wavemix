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

  property var serverState: null
  property string loadError: ""
  property string errorText: ""
  property bool fxApplying: false
  property string selectedInstance: ""
  property var controlOverrides: ({})
  property bool stateRefreshPending: false
  property var queue: []
  property string cmdTag: ""

  readonly property var serverChain: (serverState && serverState.chain
    && typeof serverState.chain.length === "number") ? serverState.chain : []
  readonly property var plugins: (serverState && serverState.plugins
    && typeof serverState.plugins.length === "number") ? serverState.plugins : []
  readonly property bool fxEnabled: serverState ? serverState.enabled === true : false
  readonly property bool fxRunning: serverState ? serverState.running === true : false
  readonly property string fxVersion: (serverState && serverState.wavemixVersion)
    ? String(serverState.wavemixVersion) : ""
  readonly property var selectedEntry: {
    for (var i = 0; i < root.serverChain.length; i++)
      if (String(root.serverChain[i].instance) === root.selectedInstance)
        return root.serverChain[i]
    return null
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

  function close() {
    window.visible = false
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

  function selectEffect(instance) {
    root.selectedInstance = String(instance || "")
  }

  function clampSelection() {
    var chain = root.serverChain
    if (chain.length === 0) {
      if (root.selectedInstance !== "") root.selectedInstance = ""
      return
    }
    for (var i = 0; i < chain.length; i++)
      if (String(chain[i].instance) === root.selectedInstance) return
    root.selectedInstance = String(chain[0].instance || "")
  }
  onServerChainChanged: root.clampSelection()

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

  function setControl(instance, key, value, control) {
    if (!root.serverState) return
    var number = root.quantizeControl(control, value)
    var next = {}
    for (var p in root.controlOverrides) next[p] = root.controlOverrides[p]
    next[root.controlKey(instance, key)] = {
      instance: String(instance),
      key: String(key),
      value: number
    }
    root.controlOverrides = next
    overrideExpire.restart()
    run(["fx", "set", String(instance), String(key), String(number)])
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
    cmdTag = next.length > 0 ? next[0] : ""
    cmd.command = [root.bin].concat(next)
    cmd.running = true
  }

  function shortError(text) {
    var lines = String(text || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line !== "") return line
    }
    return ""
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
          root.clampSelection()
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
      root.fxApplying = false
      if (exitCode !== 0) {
        var detail = root.shortError(cmdErr.text)
        root.errorText = detail !== "" ? detail : "The command failed."
      } else {
        root.errorText = ""
      }
      root.pump()
      if (!cmd.running) root.refreshState()
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
        if (event.key === Qt.Key_Escape) {
          root.close()
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
              onClicked: root.close()
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
            enabled: root.serverState !== null
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
            Layout.preferredWidth: Math.max(280,
              Math.round((window.width - Style.space(36) - Style.space(14)) * 0.42))
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: chainColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
              id: chainColumn
              width: parent.width
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
                visible: root.serverState !== null && root.serverChain.length === 0
                text: "No effects. Add one."
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Repeater {
                model: root.serverChain

                FxChainRow {
                  required property var modelData
                  required property int index
                  width: chainColumn.width
                  entry: modelData
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

              FxSettings {
                width: parent.width
              }
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

        RowLayout {
          Layout.fillWidth: true

          Text {
            text: root.fxRunning ? "Effects running" : "Effects not running"
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "Close"
            color: closeFooterArea.containsMouse
              ? Color.foreground : Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: closeFooterArea
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.close()
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

    readonly property string instanceId: (row.entry && row.entry.instance)
      ? String(row.entry.instance) : ""
    readonly property string pluginId: (row.entry && row.entry.plugin)
      ? String(row.entry.plugin) : ""
    readonly property string stateText: !row.entry ? ""
      : row.entry.available === false ? "unavailable"
      : row.entry.enabled === false ? "bypassed" : ""
    readonly property bool gpu: row.entry ? row.entry.gpu === true : false

    hasCursor: root.selectedInstance === row.instanceId
    foreground: Color.foreground
    implicitHeight: rowContent.implicitHeight + Style.space(10)

    RowLayout {
      id: rowContent
      anchors.fill: parent
      anchors.margins: Style.space(6)
      spacing: Style.space(6)

      Text {
        text: String(row.position + 1)
        Layout.preferredWidth: Style.space(20)
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        Layout.fillWidth: true
        text: root.pluginName(row.pluginId)
          + (row.instanceId !== "" ? " · " + row.instanceId : "")
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
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.selectEffect(row.instanceId)
    }
  }

  component FxSettings: Column {
    id: settings

    readonly property var entry: root.selectedEntry
    readonly property var meta: settings.entry
      ? root.pluginMeta(settings.entry.plugin) : null
    readonly property var controls: (settings.entry && settings.entry.controls
      && typeof settings.entry.controls.length === "number")
      ? settings.entry.controls : []
    readonly property bool available: settings.entry
      ? settings.entry.available !== false : false
    readonly property bool active: settings.entry
      ? settings.entry.enabled !== false : false
    readonly property bool editable: root.serverState !== null && !root.fxApplying
      && settings.available && settings.active
    readonly property string version: (settings.entry && settings.entry.pluginVersion)
      ? String(settings.entry.pluginVersion) : ""
    readonly property string requires: settings.meta
      ? String(settings.meta.requires || "") : ""
    readonly property string error: (settings.entry && settings.entry.error)
      ? String(settings.entry.error) : ""
    readonly property bool versionChanged: settings.entry
      ? settings.entry.versionChanged === true : false
    readonly property bool gpu: settings.entry ? settings.entry.gpu === true : false

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
      visible: settings.meta !== null && String(settings.meta.description || "") !== ""
      text: settings.meta ? String(settings.meta.description || "") : ""
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
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

    Repeater {
      model: settings.controls

      FxControlRow {
        required property var modelData
        required property int index
        width: settings.width
        control: modelData
        instanceId: settings.entry ? settings.entry.instance : ""
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
    property string instanceId: ""
    property bool editable: true

    readonly property real currentValue: controlRow.control
      ? root.controlValue(controlRow.instanceId, controlRow.control.key,
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
            root.setControl(controlRow.instanceId, controlRow.control.key, v,
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
