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

  // Material Symbols, like the pie, rather than the bar's Nerd Font: a filled
  // dot in a ring for on, an empty ring for off.
  Text {
    anchors.centerIn: parent
    text: String.fromCharCode(root.dotOn ? 0xE39E : 0xE559)
    color: root.barForeground
    opacity: root.dotOn ? 1.0 : 0.45
    font.family: "Material Symbols Rounded"
    font.pixelSize: Style.bar.iconFont
    renderType: Text.NativeRendering
  }
}
