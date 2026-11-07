import QtQuick
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

  function open(payloadJson) {
    window.visible = true
    floatAttempts = 0
    floatTimer.restart()
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
      anchors.fill: parent
      focus: true

      Text {
        anchors.centerIn: parent
        text: "Wavemix Effects"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
      }
    }
  }
}
