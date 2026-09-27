import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Bar icon that shows or hides the touch pie.
//
// The enabled state lives in dot.json, which is the single source of truth, so
// this watches that file for the icon state and toggles through the plugin's
// IPC method. Keeping a second copy of the state here would drift the moment
// anything else changed it (the editor, the keybind).
//
// Only `bar`, `moduleName` and `settings` are injected by the bar host, and
// presses arrive through triggerPress() -- the bar's ModuleSlot owns the
// topmost pointer layer, so child MouseAreas are not reachable.
Item {
  id: root

  property QtObject bar: null
  property string moduleName: "io.github.shaggyd.dotcom"
  property var settings: ({})
  property color barForeground: Color.foreground
  property string barFontFamily: Style.font.family

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/dot.json"
  property bool dotOn: true

  onBarChanged: {
    var host = bar
    barForeground = host ? host.barForeground : Color.foreground
    barFontFamily = host ? host.fontFamily : Style.font.family
  }

  implicitWidth: Style.bar.statusSlot
  implicitHeight: Style.bar.sizeHorizontal

  function triggerPress(button) {
    if (button !== Qt.LeftButton) return
    Util.execArgv(["omarchy-shell", "shell", "call", "io.github.shaggyd.dotcom", "toggleDot", "{}"])
  }

  function readState(raw) {
    try {
      var d = JSON.parse(String(raw || "{}"))
      root.dotOn = !(d && d.enabled === false)
    } catch (e) {
      root.dotOn = true
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.readState(text())
    onLoadFailed: {}
    onFileChanged: reload()
  }

  Component.onCompleted: stateFile.reload()

  // Drawn rather than borrowed from an icon font, so it matches the pie's own
  // dot-in-a-ring at any size: a thin ring with an accent centre when the dot
  // is on, and a hollow ring when it is off. Colours follow the bar foreground
  // and the theme accent, so the idle state never looks like a broken glyph.
  Rectangle {
    id: mark
    anchors.centerIn: parent
    width: Math.round(Style.bar.iconFont * 1.08)
    height: width
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1.5, width * 0.09)
    border.color: root.barForeground
    opacity: root.dotOn ? 1.0 : 0.5

    Rectangle {
      visible: root.dotOn
      anchors.centerIn: parent
      width: Math.round(parent.width * 0.42)
      height: width
      radius: width / 2
      color: Color.accent
    }
  }
}
