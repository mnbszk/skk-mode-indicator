import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Ui
import qs.Commons

// fcitx5-skk widget. While skk is active it shows the SKK input mode
// (あ / ア / ｱ / A / Ａ); otherwise a dimmed "EN". Left click toggles fcitx5,
// middle click or the wheel cycles SKK modes, right click opens the fcitx5
// config tool.
//
// fcitx5 exposes neither its active state nor the SKK mode as a signal of its
// own, but its tray item emits NewIcon whenever either changes, so a long-lived
// dbus-monitor drives the refresh rather than polling. The SKK mode is read
// from the tray's dbusmenu, where it is the submenu whose label repeats its
// checked item ("あ - Hiragana"). Focus changes refresh too, since the state
// can be per window.
BarWidget {
  id: root
  moduleName: "skk-mode-indicator"

  property bool fcitxRunning: false
  property bool skkOn: false
  property string currentIm: ""
  // Tray service and menu path, needed to switch modes through the menu.
  property string trayService: ""
  property string trayMenu: ""
  // [{ id, label, short, checked }] for the SKK mode submenu.
  property var modes: []
  readonly property var currentMode: {
    for (var i = 0; i < modes.length; i++) if (modes[i].checked) return modes[i]
    return null
  }

  readonly property string offLabel: String(root.settings && root.settings.offLabel || "EN")
  // Modes the wheel/middle click cycles through, by their short label.
  readonly property var cycleModes: root.settings && Array.isArray(root.settings.cycle)
    ? root.settings.cycle : ["あ", "ア", "A"]

  readonly property string stateScript: Qt.resolvedUrl("skk-state.sh").toString().replace(/^file:\/\//, "")

  property bool refreshPending: false

  function refresh() {
    if (queryProc.running) {
      refreshPending = true
      return
    }
    refreshPending = false
    queryProc.running = true
  }

  function toggle() {
    if (!root.bar) return
    root.bar.run("fcitx5-remote -t")
    debounce.restart()
  }

  // "あ - Hiragana" -> "あ", "A_ - Latin" -> "A".
  function shortLabel(label) {
    return String(label).split(" - ")[0].replace(/_+$/, "").trim()
  }

  function parseModes(layoutJson) {
    var root_
    try {
      root_ = JSON.parse(layoutJson).data[1]
    } catch (e) {
      return []
    }

    function prop(props, key) {
      return props && props[key] ? props[key].data : undefined
    }

    function find(node, isRoot) {
      var props = node[1]
      var children = (node[2] || []).map(function(c) { return c.data })
      if (!isRoot && children.length > 0) {
        var label = prop(props, "label")
        var items = children.map(function(c) {
          return {
            id: c[0],
            label: String(prop(c[1], "label") || ""),
            checked: prop(c[1], "toggle-state") === 1
          }
        })
        var hit = items.some(function(it) { return it.checked && it.label === label })
        if (hit) {
          return items.map(function(it) {
            it.short = root.shortLabel(it.label)
            return it
          })
        }
      }
      for (var i = 0; i < children.length; i++) {
        var found = find(children[i], false)
        if (found) return found
      }
      return null
    }

    return find(root_, true) || []
  }

  function cycleMode(step) {
    if (!root.skkOn || !root.trayService || modes.length === 0) return
    var ring = modes.filter(function(m) { return root.cycleModes.indexOf(m.short) !== -1 })
    if (ring.length === 0) ring = modes
    var idx = -1
    for (var i = 0; i < ring.length; i++) if (ring[i].checked) idx = i
    var next = ring[((idx + step) % ring.length + ring.length) % ring.length]
    root.bar.run("busctl --user call " + Util.shellQuote(root.trayService) + " " + Util.shellQuote(root.trayMenu)
      + " com.canonical.dbusmenu Event isvu " + next.id + " clicked s '' 0")
    debounce.restart()
  }

  Component.onCompleted: refresh()

  Process {
    id: queryProc
    command: ["sh", root.stateScript]
    onRunningChanged: if (!running && root.refreshPending) root.refresh()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const lines = String(text || "").split("\n")
        const state = parseInt(lines[0])
        root.fcitxRunning = state === 1 || state === 2
        root.currentIm = (lines[1] || "").trim()
        root.skkOn = state === 2 && root.currentIm === "skk"
        root.trayService = (lines[2] || "").trim()
        root.trayMenu = (lines[3] || "").trim()
        root.modes = root.skkOn ? root.parseModes(lines[4] || "") : []
      }
    }
  }

  Process {
    id: watchProc
    running: true
    command: ["dbus-monitor", "--session",
      "type='signal',interface='org.kde.StatusNotifierItem',member='NewIcon'"]
    stdout: SplitParser {
      onRead: function(line) {
        if (line.indexOf("member=NewIcon") !== -1) debounce.restart()
      }
    }
    // Keep watching if dbus-monitor ever exits.
    onRunningChanged: if (!running) restartTimer.restart()
  }

  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: watchProc.running = true
  }

  Timer {
    id: debounce
    interval: 80
    onTriggered: root.refresh()
  }

  // Safety net for fcitx5 restarts and anything the signal misses.
  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && event.name === "activewindowv2") debounce.restart()
    }
  }

  visible: fcitxRunning
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.skkOn ? (root.currentMode ? root.currentMode.short : "あ") : root.offLabel
    dimmed: !root.skkOn
    horizontalMargin: 6
    tooltipText: root.skkOn
      ? "SKK: " + (root.currentMode ? root.currentMode.label : "on")
      : "SKK: off (" + (root.currentIm || "none") + ")"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.bar.run("fcitx5-configtool")
      else if (b === Qt.MiddleButton) root.cycleMode(1)
      else root.toggle()
    }
    onWheelMoved: function(delta) { root.cycleMode(delta > 0 ? -1 : 1) }
  }
}
