import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "Catalog.js" as Catalog

// A draggable on-screen dot that opens a pie menu of window and system
// actions. It exists because the stock tablet experience buries the handful
// of actions you actually reach for in small bar icons and hotkeys that
// need a physical keyboard.
//
// The window is always up (keepLoaded) and `visible` is never bound to
// `opened` -- the dot itself must persist while the pie is dismissed. Only
// the pie's own chrome and the dismiss scrim are conditional.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var manifest: null
  property var shell: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.shaggyd.dotcom"

  // Persisted between sessions. Fractions rather than pixels so the dot lands
  // in the same relative spot on any screen, including a different tablet.
  //
  //   comfort  : confine the dot to a rect inset by the pie radius, so the pie
  //              is always drawn at full size. Set false to restore the old
  //              behaviour where the pie shrank near an edge.
  //   slices   : null means use `defaultSlices`. An array here replaces them;
  //              see `sanitizeSlices` for the accepted shape.
  property var config: ({
    dotSize: 48,
    idleOpacity: 0.5,
    radius: 132,
    iconSize: 30,
    showLabels: true,
    holdMs: 600,
    comfort: true,
    // Whether the dot is showing. Toggled from the bar icon.
    enabled: true,
    // Set after the first-run salute, so "reporting for duty" shows once.
    greeted: false,
    // Motion. `physics` is the master switch. springOpen and wobble are
    // separate so the two open effects can be tried apart or together, and
    // inertia can be turned off if a flying dot is not wanted.
    physics: true,
    springOpen: true,
    wobble: true,
    inertia: true,
    fx: 0.72,
    fy: 0.72,
    slices: null
  })

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/dot.json"

  // ------------------------------------------------------------------ state

  property bool opened: false
  property int hoveredSlice: -1
  property bool hovering: false
  property bool dragging: false
  // A press that travelled far enough to count as a move, rather than a tap.
  property bool moved: false
  // Set once the press has been held long enough to mean "I want to move
  // this". Until then the finger does nothing, so a tap can never be
  // misread as a drag and a drag never fires the pie by accident.
  property bool dragArmed: false
  // True when the press began with the pie already open, so the release knows
  // the pie was collapsed by the press and must not be reopened.
  property bool pressedWhileOpen: false
  // True for the whole press, armed or not. Touch gives no hover, so this is
  // what makes the dot acknowledge a finger landing on it.
  property bool holding: false
  property double holdStartedAt: 0
  property real holdProgress: 0

  // 0 = fully collapsed into the dot, 1 = fully open. Everything about the
  // pie's appearance is a function of this one number, so opening and
  // closing are the same animation played forwards and backwards.
  property real pieProgress: 0

  // The open effects. `pieProgress` drives the radial spring pop; `wobbleAngle`
  // is a one-shot damped spin, kicked on open and applied as a rotation about
  // the dot, so the ring settles with a little wobble.
  property real wobbleAngle: 0
  property real wobbleKick: 6
  // Press/release squash on the dot, and the magnet on a pressed slice.
  property real squashX: 1
  property real squashY: 1
  property bool slicePressed: false
  // Radial drag-select from the idle dot: drag outward to fan the pie and pick
  // a slice, with no hold required. Moving the dot still needs the hold.
  property bool radialSelecting: false
  readonly property real radialThreshold: Style.space(24)
  // Drag velocity, low-pass filtered, for the release glide.
  property real vX: 0
  property real vY: 0
  property real lastSampleT: 0
  property real inertiaToX: 0
  property real inertiaToY: 0

  // The dot can be switched off entirely -- useful when the screen should stay
  // clear, or when a physical keyboard makes it unnecessary. The bar icon
  // toggles this, and it lives in dot.json so there is one source of truth
  // rather than a second copy in the bar widget that could drift.
  readonly property bool dotOn: root.config.enabled !== false

  function toggleDot() {
    var next = {}
    for (var k in root.config) next[k] = root.config[k]
    next.enabled = !root.dotOn
    root.config = next
    root.persist()
    if (!next.enabled && root.mode === "use") root.dismiss()
  }

  readonly property bool dimmed: !root.opened && !root.hovering && !root.holding && !root.dragging && !root.moved && !root.dragArmed
  readonly property real currentOpacity: root.dimmed ? root.config.idleOpacity : 1.0

  // Set on a slice click, consumed by actionDelay once the pie is gone, so the
  // action never runs while this overlay is still holding the layer.
  property var pendingSlice: null

  property var targetScreen: null

  // "use"  -- the pie runs actions.
  // "edit" -- the Command Deck panel is docked beside the pie, which stays as
  //           the WYSIWYG live preview; the hub is Done.
  // "pick" -- the tile sheet is open over the editor for one slice.
  property string mode: "use"
  property var draftSlices: []
  property int pickIndex: -1
  property string pickCategory: "Window"
  property string pickQuery: ""
  property bool editDirty: false
  // Settings are staged like the slice draft: the panel previews them live, but
  // nothing is written until Save (Cancel restores the snapshot).
  property bool settingsDirty: false
  property bool confirmCancel: false
  // Command Deck panel state. `configBackup` snapshots the settings on enter so
  // Cancel can revert them (settings apply live for the preview); `deckTab`
  // picks the Slices or Settings page.
  property string deckTab: "slices"
  property var configBackup: null
  readonly property bool deckRight: root.dotX < ((root.screenW > 0 ? root.screenW : panel.width) / 2)
  // Transient line shown while editing. The dot's failure flash is unavailable
  // here because the dot is hidden in edit mode.
  property string editNotice: ""

  // Identity order: the order slices were *added*, which does not change when
  // the ring is reordered. The Repeater is keyed on this rather than on the
  // display order, so a reorder moves the existing delegates instead of
  // swapping their contents -- which is what makes the move animatable. With
  // an index-keyed model there is nothing to animate: each index keeps its
  // position and just shows different data.
  property var stableIds: []

  // What this machine actually has. The catalog is static, so without this an
  // entry whose command is missing would only fail at tap time, with no way for
  // the picker to say why.
  property var availableCommands: ({})
  property var enabledPlugins: ({})
  property bool capabilitiesProbed: false

  // Drag-to-reorder (edit mode). While dragId is set, that slice's delegate
  // follows the finger instead of its slot, and the others shuffle to open a
  // gap where it will land.
  property string dragId: ""
  property real dragAngle: 0

  readonly property string iconFamily: "Material Symbols Rounded"

  // The outer ring is the pie's frame, so it uses the theme's popup-card
  // border. Omarchy wires that to the Hyprland active-border colour
  // (`[popups] border = "hyprland.active-border"` in the theme's shell.toml),
  // so the ring matches window borders and follows theme switches live.
  readonly property color ringBorderColor: Color.popups.border

  // Labels sit on the slice fill, so contrast is measured against the
  // background role. alphaForContrast raises the alpha until it clears 4.5:1,
  // so a theme with a dim foreground cannot leave labels unreadable. On Miasma
  // this resolves to foreground @0.66 (4.68:1); the theme's own `muted`
  // (#666666, 2.77:1) and `bar.active` (#685742, 2.30:1) both fail and are
  // deliberately not used.
  readonly property color labelColor: Util.alpha(Color.foreground,
    Catalog.alphaForContrast(Color.foreground, Color.background, 0.66, 4.5))
  readonly property color labelActiveColor: Util.alpha(Color.accent,
    Catalog.alphaForContrast(Color.accent, Color.background, 0.8, 3.0))
  // ----------------------------------------------------------------- slices
  //
  // Slices are resolved from Catalog.js by key. A stored slice is one of:
  //
  //   { "key": "hypr.window.fullscreen" }               catalog entry
  //   { "key": "pie.edit", "label": "Settings" }        catalog entry, relabelled
  //   { "label": "X", "glyph": "...", "argv": [...] }   fully custom
  //   { "label": "X", "glyph": "...", "app": {...} }    an application
  //
  // Referencing catalog keys rather than copying commands means improving a
  // catalog entry propagates to every pie that uses it, and a stale key
  // degrades to "slice missing" instead of a thrown binding.
  //
  // Glyphs come from Catalog.js, which builds them with String.fromCharCode:
  // raw Private Use Area bytes and \uXXXX escapes have both been silently
  // corrupted by tooling during this project. Menu-catalog entries carry
  // font:"menu" because Omarchy's menu icons are Nerd Font glyphs, not
  // Material Symbols, and would render as tofu in the pie's icon font.
  //
  // Two commands are worth a note:
  //
  //   keyboard -- texp-vk, not `omarchy-shell onscreen-keyboard toggle`. The
  //     plugin that would answer that target
  //     (io.github.mtolhuys.onscreen-keyboard) is disabled on this machine --
  //     wvkbd is the keyboard in use -- so the target does not exist and the
  //     call fails with "Target not found." (exit 1). An earlier `-q` check
  //     reported success because -q suppresses exactly that failure, which is
  //     how the dead target survived the first pass. texp-vk is the wrapper
  //     the SUPER+U binding already uses, and it starts the keyboard on demand.
  //
  //   settings -- the Settings slice is `pie.edit`, which opens the editor.
  //     The omarchy Setup menu is not a default slice; it lives in the System
  //     catalog as `sys.setup` and can be added from the picker.
  readonly property var defaultSlices: [
    { key: "hypr.window.fullscreen" },
    { key: "sys.apps" },
    { key: "sys.terminal" },
    { key: "sys.power" },
    { key: "pie.edit" },
    { key: "sys.keyboard" }
  ]

  // ---- catalogs ----------------------------------------------------------
  //
  // Menu and Apps are built at run time: the menu from Omarchy's own JSONC so
  // it stays in sync, the apps from the shell's AppLibrary. Both are lazily
  // populated -- 333 routes and ~90 icon lookups are not worth doing at start.
  property var menuCatalog: []
  property var appCatalog: []
  property var pluginCatalog: []
  // "Pie" is deliberately absent: Recenter/Reset are editor commands, not
  // slice actions, so offering them as pickable content never made sense. The
  // PIE catalog is kept only so the default Settings slice's `pie.edit` key
  // still resolves; those two need a home in the editor chrome instead.
  readonly property var catalogCategories: ["Window", "System", "Keyboard", "Menu", "Apps", "Plugins"]

  function catalogFor(category) {
    if (category === "Window") return Catalog.WINDOW
    if (category === "System") return Catalog.SYSTEM
    if (category === "Keyboard") return Catalog.KEYBOARDS
    if (category === "Menu") return root.menuCatalog
    if (category === "Apps") return root.appCatalog
    if (category === "Plugins") return root.pluginCatalog
    if (category === "Pie") return Catalog.PIE
    return []
  }

  function catalogByKey(key) {
    var lists = [Catalog.WINDOW, Catalog.SYSTEM, Catalog.KEYBOARDS, Catalog.PIE, root.menuCatalog, root.appCatalog, root.pluginCatalog]
    for (var i = 0; i < lists.length; i++) {
      var list = lists[i]
      for (var j = 0; j < list.length; j++) if (list[j].key === key) return list[j]
    }
    return null
  }

  // Apps come from Quickshell's DesktopEntries singleton -- the same source
  // Omarchy's own menu uses -- rather than the shell's AppLibrary capability.
  // That capability is gated on a plugin declaring kind "menu"
  // (shell.qml:603), and declaring it did not actually grant it (verified:
  // appLibrary stayed null after adding the kind and restarting), so relying
  // on it would have left this tab permanently empty.
  // Apps are grouped alphabetically rather than by .desktop Categories: those
  // are half-noise ("GNOME", "Qt" are toolkit tags) and 14 of the 62 visible
  // entries have none at all, which would scatter a third of the list into an
  // "Other" bucket. Buckets of three letters keep a 60-app list to ~9 headings
  // instead of 26 one-item sections.
  function alphaSection(label) {
    var c = String(label || "").replace(/^\s+/, "").charAt(0).toUpperCase()
    if (c < "A" || c > "Z") return "Other"
    var i = Math.floor((c.charCodeAt(0) - 65) / 3)
    return String.fromCharCode(65 + i * 3) + "-" + String.fromCharCode(65 + i * 3 + 2)
  }

  function buildAppCatalog() {
    if (root.appCatalog.length > 0) return
    var all = DesktopEntries.applications.values
    if (!all) return
    var out = []
    for (var i = 0; i < all.length; i++) {
      var e = all[i]
      if (!e || e.noDisplay === true) continue
      var id = String(e.id || "")
      var name = String(e.name || "")
      if (id === "" || name === "") continue
      var icon = String(e.icon || "")
      out.push({
        key: "app." + id,
        label: name,
        // A generic glyph, not "": the tile draws this underneath the image, so
        // an app whose icon is missing or fails to load degrades to an icon
        // rather than an empty square.
        glyph: Catalog.g(0xE8B9),
        icon: icon !== "" ? Quickshell.iconPath(icon, true) : "",
        group: "Apps",
        section: root.alphaSection(name),
        app: { id: id, name: name }
      })
    }
    out.sort(function (a, b) {
      var x = a.label.toLowerCase(), y = b.label.toLowerCase()
      return x < y ? -1 : (x > y ? 1 : 0)
    })
    root.appCatalog = out
  }

  // ---- resolution --------------------------------------------------------

  // Turn one stored slice into something drawable and runnable, or null.
  function resolveSlice(s) {
    if (!Util.isPlainObject(s)) return null
    var base = {}
    if (typeof s.key === "string" && s.key.length > 0) {
      var found = root.catalogByKey(s.key)
      if (!found) return null
      base = found
    }
    var label = String(s.label != null ? s.label : (base.label != null ? base.label : ""))
    if (label === "" || label.length > 20) return null
    var glyph = String(s.glyph != null ? s.glyph : (base.glyph != null ? base.glyph : ""))
    if (glyph.length > 4) glyph = ""

    var out = {
      id: String(s.id != null ? s.id : (base.key != null ? base.key : label)),
      key: String(s.key != null ? s.key : ""),
      label: label,
      glyph: glyph,
      font: (base.font === "menu") ? "menu" : "material",
      icon: String(s.icon != null ? s.icon : (base.icon != null ? base.icon : "")),
      repeat: (s.repeat === true) || (base.repeat === true)
    }
    if (base.hypr) out.hypr = base.hypr
    if (base.argv) out.argv = base.argv
    if (base.chain) out.chain = base.chain
    if (base.plugin) out.plugin = base.plugin
    if (base.app) out.app = base.app
    if (base.requires) out.requires = base.requires
    if (base.install) out.install = base.install
    if (base.installAur) out.installAur = base.installAur
    if (base.requiresAny) out.requiresAny = base.requiresAny
    if (base.requiresPlugin) out.requiresPlugin = base.requiresPlugin
    // Inline fields override the catalog entry.
    if (typeof s.hypr === "string" && s.hypr.length > 0) out.hypr = s.hypr
    if (Array.isArray(s.argv)) out.argv = s.argv
    if (typeof s.plugin === "string") out.plugin = s.plugin
    if (Util.isPlainObject(s.app)) out.app = s.app
    if (!out.hypr && !out.argv && !out.chain && !out.plugin && !out.app) return null
    return out
  }

  // A user `slices` array is arbitrary data from a JSON file, so it is
  // validated rather than trusted: wrong types would otherwise throw inside a
  // binding and take the whole overlay down. Length is capped at 9 because the
  // label layout stops being readable past that.
  function sanitizeSlices(value) {
    if (!Array.isArray(value)) return null
    if (value.length < 3 || value.length > 9) return null

    // The editor slice is non-negotiable. A stored set that lacks it -- a
    // hand-edited dot.json, or a bug elsewhere -- would leave no way back into
    // the editor, so it is re-added rather than the config being rejected.
    // At the 9-slice cap something has to give, and the editor wins.
    var input = value.slice()
    var hasEditor = false
    for (var e = 0; e < input.length; e++) {
      var probe = root.resolveSlice(input[e])
      if (probe && probe.plugin === "edit") { hasEditor = true; break }
    }
    if (!hasEditor) {
      if (input.length >= 9) input[input.length - 1] = { key: "pie.edit" }
      else input.push({ key: "pie.edit" })
    }

    var seen = {}
    var out = []
    for (var i = 0; i < input.length; i++) {
      var r = root.resolveSlice(input[i])
      if (!r) continue
      if (seen[r.id]) continue
      seen[r.id] = true
      out.push(r)
    }
    return out.length >= 3 ? out : null
  }

  readonly property var resolvedDefaults: root.sanitizeSlices(root.defaultSlices) || []
  readonly property var activeSlices: root.sanitizeSlices(root.config.slices) || root.resolvedDefaults
  // While editing, everything draws and hit-tests against the draft, so the
  // preview is exactly what Done would save.
  readonly property var displaySlices: (root.mode === "use") ? root.activeSlices : root.draftSlices
  readonly property int sliceCount: root.displaySlices.length
  readonly property real sectorAngle: 360 / Math.max(1, root.sliceCount)

  // Slices are laid out with slice 0 centred on 12 o'clock and the rest
  // running clockwise.
  //
  // These two functions and `sliceAt` must agree on one convention or a tap
  // fires the slice a quarter turn away from the one that was touched. An
  // earlier version drew from -90 degrees while `sliceAt` measured from 0,
  // which rotated every hit-test 90 degrees clockwise from the artwork.
  function sliceStartAngle(i) {
    return root.sectorAngle * (i - 0.5)
  }

  function sliceCenterAngle(i) {
    return root.sectorAngle * i
  }

  //
  // Hyprland dispatchers.
  //
  // This Hyprland (0.56.2, Lua-configured) routes the classic `/dispatch` IPC
  // request through `hl.dispatch(<args joined by spaces>)`, so every dispatcher
  // name comes back as a Lua syntax error and *no* dispatcher works. The
  // supported path on this build is the `hl.dsp` table, reached with
  // `hyprctl eval`, so a hypr action is a Lua snippet rather than a pair.
  // hyprctl exits 7 on a Lua error and 0 on success, so failures are visible.
  function argvFor(slice) {
    if (!slice) return null
    if (slice.chain) {
      for (var i = 0; i < slice.chain.length; i++) {
        var step = slice.chain[i]
        if (root.chainEntryAvailable(step)) return step.argv
      }
      return null
    }
    if (slice.argv) return slice.argv
    if (slice.hypr) return ["hyprctl", "eval", "hl.dispatch(" + slice.hypr + ")"]
    return null
  }

  // Run one slice. Plugin actions never leave the shell; app actions go
  // through the shell's own AppLibrary rather than spawning a launcher.
  function runSlice(slice) {
    if (!slice) return
    if (slice.plugin) { root.runPluginAction(slice.plugin); return }
    if (slice.app) {
      var entry = DesktopEntries.byId(String(slice.app.id || ""))
      if (!entry) {
        root.reportFailure("app not found: '" + slice.label + "'")
        return
      }
      entry.execute()
      return
    }
    var argv = root.argvFor(slice)
    if (!argv) {
      var why = root.availabilityReason(slice)
      root.reportFailure("'" + slice.label + "' cannot run: " + (why !== "" ? why : "no action"))
      return
    }
    root.spawn(argv, slice.label)
  }

  // Whether a resolved slice can actually run right now, so the pie can dim it
  // instead of letting a tap fail.
  function sliceAvailable(slice) {
    if (!slice) return false
    if (slice.chain) {
      for (var i = 0; i < slice.chain.length; i++)
        if (root.chainEntryAvailable(slice.chain[i])) return true
      return false
    }
    if (slice.requires || slice.requiresAny || slice.requiresPlugin)
      return root.entryAvailable(slice)
    if (slice.argv) return root.commandAvailable(slice.argv[0])
    return true   // hypr / plugin / app actions
  }

  function runPluginAction(name) {
    if (name === "edit") { root.enterEdit(); return }
    if (name === "recenter") { root.recenter(); return }
    if (name === "reset") { root.resetConfig(); return }
    if (name === "commander") { root.commander(); return }
    root.reportFailure("unknown plugin action '" + name + "'")
  }

  // -------------------------------------------------------------- Dot Commander
  //
  // The Commander easter eggs: a slice, a hidden IPC call, and a first-run
  // salute.
  readonly property var commanderQuips: [
    "All systems nominal, Commander.",
    "The bridge is yours, Commander.",
    "Course plotted. Standing by.",
    "Engage.",
    "No anomalies detected, Commander.",
    "Aye, Commander."
  ]

  function commanderLine() {
    var i = Math.floor(Math.random() * root.commanderQuips.length)
    return "Dot Commander. " + root.commanderQuips[i]
  }

  // Hidden IPC: omarchy-shell shell call io.github.shaggyd.dotcom commander
  function commander() {
    var line = root.commanderLine()
    root.sendNotification("Dot Commander", line)
    return JSON.stringify({ name: "Dot Commander", line: line })
  }

  function sendNotification(summary, body) {
    root.spawn(["omarchy-notification-send", "-u", "low", String(summary), String(body)], "notify")
  }

  property bool greetedOnce: false

  function maybeGreet() {
    if (root.greetedOnce) return
    root.greetedOnce = true
    if (root.config.greeted === true) return
    var next = {}
    for (var k in root.config) next[k] = root.config[k]
    next.greeted = true
    root.config = next
    root.persist()
    root.sendNotification("Dot Commander", "Reporting for duty.")
  }

  // -------------------------------------------------------------- edit mode
  //
  // Everything is edited on a draft and written to dot.json only on Done, so
  // Cancel is real and the trashcan is safe to press.

  // Reduce a resolved slice back to its storable form. Catalog-backed slices
  // keep only the key (plus a label override), so they go on tracking the
  // catalog as it changes.
  function sliceToStored(slice) {
    if (!slice) return null
    if (slice.key !== "") {
      var s = { key: slice.key }
      // Store the label only when it overrides the catalog's, so a catalog
      // rename propagates instead of being pinned by an old copy.
      var cat = root.catalogByKey(slice.key)
      if (!cat || cat.label !== slice.label) s.label = slice.label
      return s
    }
    var o = { label: slice.label, glyph: slice.glyph }
    if (slice.icon) o.icon = slice.icon
    if (slice.app) o.app = slice.app
    if (slice.hypr) o.hypr = slice.hypr
    if (slice.argv) o.argv = slice.argv
    if (slice.plugin) o.plugin = slice.plugin
    if (slice.repeat) o.repeat = true
    return o
  }

  // Right-click on the bar icon lands here: open the Command Deck on Settings,
  // the plugin's "settings button".
  function settings() {
    root.enterEdit()
    root.deckTab = "settings"
    return "ok"
  }

  function enterEdit() {
    root.draftSlices = root.activeSlices.slice()
    root.editDirty = false
    root.settingsDirty = false
    root.confirmCancel = false
    root.pickIndex = -1
    // Snapshot settings so Cancel can revert the live edits the panel makes.
    var backup = {}
    for (var bk in root.config) backup[bk] = root.config[bk]
    root.configBackup = backup
    root.deckTab = "slices"
    root.setStableIds(root.draftSlices)
    root.mode = "edit"
    root.opened = true
    root.hoveredSlice = -1
    root.pieProgress = 1
    root.buildAppCatalog()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function commitEdit() {
    if (root.editDirty || root.settingsDirty) {
      var stored = []
      for (var i = 0; i < root.draftSlices.length; i++) stored.push(root.sliceToStored(root.draftSlices[i]))
      var next = {}
      for (var k in root.config) next[k] = root.config[k]
      next.slices = stored
      root.config = next
      root.persist()
    }
    root.mode = "use"
    root.pickIndex = -1
    root.editDirty = false
    root.settingsDirty = false
    root.confirmCancel = false
    root.configBackup = null
    root.syncStableIds()
  }

  // Escape: back out of the picker, otherwise act as the deck's Cancel (which
  // asks before discarding unsaved slices), or dismiss the pie in use mode.
  // Previously Escape dismissed the overlay outright, which threw away the
  // slice edits without a word.
  function escapeAction() {
    if (root.mode === "pick") { root.mode = "edit"; root.pickIndex = -1; return }
    if (root.mode === "edit") { root.cancelEdit(); return }
    root.dismiss()
  }

  // First outside tap arms the discard; a second within the window does it.
  function cancelEdit() {
    if (root.editDirty && !root.confirmCancel) {
      root.confirmCancel = true
      confirmTimer.restart()
      return
    }
    root.confirmCancel = false
    // Revert the live settings edits the panel made while open.
    if (root.configBackup) {
      root.config = root.configBackup
      root.configBackup = null
      root.persist()
    }
    root.draftSlices = []
    root.pickIndex = -1
    root.mode = "use"
    root.editDirty = false
    root.settingsDirty = false
    root.syncStableIds()
    root.dismiss()
  }

  // `>>` advances the ring so the next slice takes the first position (the
  // content moves counter-clockwise, like paging forward through a carousel);
  // `<<` steps back.
  //
  // No animation code here any more: reordering changes each delegate's slot,
  // which changes its `angle` binding, and the Behavior on `angle` animates
  // that. The old implementation animated a single global offset and then
  // swapped the array underneath it, which only worked because a rotation
  // happens to be uniform. A drag-shuffle is not, so it needed this instead.
  function rotateDraft(dir) {
    if (root.draftSlices.length < 2) return
    var a = root.draftSlices.slice()
    if (dir > 0) a.push(a.shift())
    else a.unshift(a.pop())
    root.draftSlices = a
    root.editDirty = true
  }

  // ---- identity helpers ---------------------------------------------------

  function setStableIds(list) {
    var out = []
    for (var i = 0; i < list.length; i++) out.push(list[i].id)
    root.stableIds = out
  }

  // Keep the identity order stable across reorders: ids still present keep
  // their relative order, new ones append, removed ones drop.
  function syncStableIds() {
    var current = root.displaySlices.map(function (x) { return x.id })
    var out = []
    for (var i = 0; i < root.stableIds.length; i++)
      if (current.indexOf(root.stableIds[i]) !== -1) out.push(root.stableIds[i])
    for (var j = 0; j < current.length; j++)
      if (out.indexOf(current[j]) === -1) out.push(current[j])
    root.stableIds = out
  }

  function slotOfId(id) {
    var list = root.displaySlices
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return i
    return -1
  }

  function sliceForId(id) {
    var list = root.displaySlices
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  // ---- drag-to-reorder ---------------------------------------------------

  // Move the dragged slice to whichever slot is nearest the finger. Called on
  // every move; it no-ops unless the finger has crossed into a new slot, so
  // the array is only rewritten when the gap actually needs to move.
  function reorderDrag() {
    var list = root.draftSlices
    var from = -1
    for (var i = 0; i < list.length; i++) if (list[i].id === root.dragId) { from = i; break }
    if (from < 0 || list.length < 2) return
    var target = Math.round(root.dragAngle / root.sectorAngle) % list.length
    if (target < 0) target += list.length
    if (target === from) return
    var a = list.slice()
    var item = a.splice(from, 1)[0]
    a.splice(target, 0, item)
    root.draftSlices = a
    root.editDirty = true
  }

  function endDrag() {
    if (root.dragId === "") return
    root.dragId = ""
    root.dragAngle = 0
  }

  function openPickerFor(index) {
    root.refreshCapabilities()
    root.pickIndex = index
    root.pickQuery = ""
    // The field is not bound to pickQuery (binding it would fight the user's
    // typing), so clear it explicitly.
    pickSearch.text = ""
    root.buildAppCatalog()
    root.mode = "pick"
  }

  function addSlice() {
    if (root.draftSlices.length >= 9) return
    root.openPickerFor(-1)
  }

  function chooseEntry(entry) {
    if (!entry) return
    // The picker never opens for the editor slice, so this is belt and braces.
    if (root.pickIndex >= 0 && root.isEditorSlice(root.draftSlices[root.pickIndex])) {
      root.notify("Settings cannot be replaced")
      return
    }
    // App entries are not catalog-stable (an app can be uninstalled), so they
    // store their launch target inline; everything else stores the key.
    var stored = (String(entry.key).indexOf("app.") === 0)
      ? { label: entry.label, glyph: "", icon: entry.icon, app: entry.app }
      : { key: entry.key }
    var resolved = root.resolveSlice(stored)
    if (!resolved) { root.reportFailure("cannot resolve " + entry.key); return }
    var a = root.draftSlices.slice()
    if (root.pickIndex >= 0) a[root.pickIndex] = resolved
    else a.push(resolved)
    root.draftSlices = a
    root.syncStableIds()
    root.editDirty = true
    root.mode = "edit"
    root.pickIndex = -1
  }

  function deleteSlice() {
    if (root.pickIndex < 0) return
    if (root.isEditorSlice(root.draftSlices[root.pickIndex])) {
      root.notify("Settings cannot be removed")
      return
    }
    if (root.draftSlices.length <= 3) return
    var a = root.draftSlices.slice()
    a.splice(root.pickIndex, 1)
    root.draftSlices = a
    root.syncStableIds()
    root.editDirty = true
    root.mode = "edit"
    root.pickIndex = -1
  }

  // ---- Command Deck panel helpers ----------------------------------------

  // Move a draft slice by delta slots. The panel uses this for its up/down
  // buttons; rotating the whole ring is just n of these, so the old floating
  // << + >> rotate buttons are gone.
  function moveDraftSlice(index, delta) {
    var a = root.draftSlices.slice()
    var to = index + delta
    if (index < 0 || index >= a.length || to < 0 || to >= a.length) return
    var item = a.splice(index, 1)[0]
    a.splice(to, 0, item)
    root.draftSlices = a
    root.editDirty = true
  }

  function removeDraftSlice(index) {
    if (index < 0) return
    if (root.isEditorSlice(root.draftSlices[index])) {
      root.notify("Settings cannot be removed")
      return
    }
    if (root.draftSlices.length <= 3) { root.notify("Keep at least three slices"); return }
    var a = root.draftSlices.slice()
    a.splice(index, 1)
    root.draftSlices = a
    root.syncStableIds()
    root.editDirty = true
  }

  // Settings apply immediately and autosave, so the panel is a live preview;
  // enterEdit snapshots the old config so Cancel can still revert them.
  function setConfig(key, value) {
    var next = {}
    for (var k in root.config) next[k] = root.config[k]
    next[String(key)] = value
    root.config = next
    root.settingsDirty = true
  }

  function toggleConfig(key) {
    root.setConfig(key, root.config[String(key)] !== true)
  }

  // Slice label/glyph rendering shared by the panel list and the pie: an app
  // slice carries an image, a menu slice a Nerd Font glyph, everything else a
  // Material Symbols glyph.
  function sliceFontFamily(slice) {
    return (slice && slice.font === "menu") ? Style.font.menuFamily : root.iconFamily
  }

  // Exposed for `omarchy-shell shell call io.github.shaggyd.dotcom debugGeometry`.
  // Handy for checking the invariant that the pie centre is identical in every
  // mode -- entering edit mode must not move it.
  function debugGeometry() {
    return JSON.stringify({
      mode: root.mode,
      dotX: Math.round(root.dotX),
      dotY: Math.round(root.dotY),
      screenW: Math.round(root.screenW),
      screenH: Math.round(root.screenH),
      comfortInset: Math.round(root.comfortInset),
      outerRadius: Math.round(root.outerRadius),
      barY: Math.round(root.editBarY),
      barBelow: root.editBarBelow,
      slices: root.sliceCount,
      order: root.displaySlices.map(function (x) { return x.label }).join(">"),
      stableIds: root.stableIds.length,
      pickCategory: root.pickCategory,
      probed: root.capabilitiesProbed,
      probeExits: root.probeExits,
      catalogCommands: root.catalogCommands().length,
      probeArgc: cmdProbe.command.length,
      commands: Object.keys(root.availableCommands).length,
      plugins: Object.keys(root.enabledPlugins).length,
      keyboardChain: root.entryAvailable(root.catalogByKey("sys.keyboard")),
      keyboardOmarchy: root.entryAvailable(root.catalogByKey("sys.keyboard_omarchy")),
      editNotice: root.editNotice,
      pickIndex: root.pickIndex,
      pickSections: root.pickSections.map(function (x) { return x.title + "(" + x.entries.length + ")" }),
      dragId: root.dragId,
      appLibrary: !!(root.shell && root.shell.appLibrary),
      desktopEntries: (DesktopEntries.applications.values || []).length,
      appSample: root.appCatalog.slice(0, 3).map(function (a) {
        return a.label + " => " + a.icon
      }),
      menuEntries: root.menuCatalog.length,
      appEntries: root.appCatalog.length,
      pluginEntries: root.pluginCatalog.length,
      keyboardEntries: Catalog.KEYBOARDS.length,
      keyboards: Catalog.KEYBOARDS.map(function (e) { return e.label + "=" + root.entryAvailable(e) }),
      keyboardSliceOk: !!root.resolveSlice({ key: "sys.keyboard" }),
      omarchyFix: (function () { var f = root.fixFor(root.catalogByKey("sys.keyboard_omarchy")); return f ? f.label : "" })(),
      dotOn: root.dotOn
    })
  }

  // Opens the picker on a given category. Handy for driving the UI from a
  // terminal: omarchy-shell shell call io.github.shaggyd.dotcom debugPick Apps
  function debugPick(category) {
    root.enterEdit()
    root.openPickerFor(-1)
    root.pickCategory = String(category || "Apps")
    root.buildAppCatalog()
  }

  // Drives the real add path from a terminal: passes the catalog entry object
  // the picker tile would pass, which IPC cannot do (it only sends strings).
  function debugAddKey(key) {
    var e = root.catalogByKey(String(key))
    if (!e) { root.reportFailure("no such catalog key: " + key); return }
    root.openPickerFor(-1)
    root.chooseEntry(e)
  }

  // A one-shot pulse at a slice, used on tap/ramp for feedback. Position is
  // recomputed from the slice's slot, which is where it was pressed.
  function rippleAt(slot) {
    if (!root.config.physics) return
    var rad = (root.sectorAngle * slot) * Math.PI / 180
    var r = root.outerRadius * 0.6
    ripple.x = Math.round(root.pieCentre.x + Math.sin(rad) * r - ripple.width / 2)
    ripple.y = Math.round(root.pieCentre.y - Math.cos(rad) * r - ripple.height / 2)
    rippleAnim.restart()
  }

  function recenter() {
    var next = {}
    for (var k in root.config) next[k] = root.config[k]
    next.fx = 0.5
    next.fy = 0.5
    root.config = next
    root.persist()
  }

  function resetConfig() {
    var next = {}
    for (var k in root.config) next[k] = root.config[k]
    next.slices = null
    root.config = next
    root.persist()
  }

  // Group a catalog into [{ title, entries }]. Search filters within the
  // sections rather than flattening them, so a hit still shows where it lives.
  function groupedEntries(list) {
    var q = String(root.pickQuery || "").toLowerCase()
    var order = []
    var byTitle = ({})
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (q !== "") {
        var hay = String(e.label).toLowerCase() + " " + String(e.key).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      var title = String(e.section || "")
      if (title === "") title = "Other"
      if (!(title in byTitle)) { byTitle[title] = { title: title, entries: [] }; order.push(title) }
      byTitle[title].entries.push(e)
    }
    // "Other" always last, so it never interrupts the named sections.
    var out = []
    var other = null
    for (var j = 0; j < order.length; j++) {
      if (order[j] === "Other") other = byTitle[order[j]]
      else out.push(byTitle[order[j]])
    }
    if (other) out.push(other)
    return out
  }

  readonly property var pickSections: root.groupedEntries(root.catalogFor(root.pickCategory))

  // ---------------------------------------------------------------- spawning
  //
  // A ring of Process objects rather than Util.execArgv, which is
  // Quickshell.execDetached and therefore cannot report anything: no exit
  // code, no stderr. A slice that did nothing looked exactly like a slice that
  // worked. `hyprctl eval` exits 7 on a Lua error, so the exit code alone is
  // enough to catch a mistyped dispatcher.
  property var procPool: [actionProc0, actionProc1, actionProc2]
  property int procNext: 0

  function spawn(argv, label) {
    var proc = root.procPool[root.procNext]
    root.procNext = (root.procNext + 1) % root.procPool.length
    if (proc.running) return false
    proc.label = label
    proc.out = ""
    proc.err = ""
    // Same `exec "$@"` guard Util.execArgv uses: argv never reaches a shell
    // parser, so a value containing $(id) or a space stays one argument.
    proc.command = ["bash", "-lc", 'exec "$@"', "bash"].concat(argv)
    proc.running = true
    return true
  }

  function onProcExited(proc, exitCode) {
    if (exitCode === 0) return
    var detail = String(proc.err || "").trim()
    if (detail === "") detail = String(proc.out || "").trim()
    if (detail === "") detail = "no output"
    root.reportFailure("'" + proc.label + "' exited " + exitCode + ": " + detail)
  }

  property string lastError: ""
  property bool failed: false

  function notify(message) {
    root.editNotice = String(message || "")
    noticeTimer.restart()
  }

  // The one slice that must always exist: it is the only way into edit mode
  // from the pie, so losing it would lock the user out of the editor.
  function isEditorSlice(slice) {
    return !!slice && slice.plugin === "edit"
  }

  function reportFailure(message) {
    root.lastError = String(message || "")
    root.failed = true
    console.warn("io.github.shaggyd.dotcom: " + root.lastError)
    // A failed ramp would otherwise keep firing into a broken command.
    repeatTimer.stop()
    errorTimer.restart()
  }

  Timer {
    id: errorTimer
    interval: 1800
    onTriggered: root.failed = false
  }

  Process {
    id: actionProc0
    property string label: ""
    property string out: ""
    property string err: ""
    stdout: SplitParser { function onStreamFinished() { actionProc0.out = text } }
    stderr: SplitParser { function onStreamFinished() { actionProc0.err = text } }
    function onExited(exitCode, exitStatus) { root.onProcExited(actionProc0, exitCode) }
  }

  Process {
    id: actionProc1
    property string label: ""
    property string out: ""
    property string err: ""
    stdout: SplitParser { function onStreamFinished() { actionProc1.out = text } }
    stderr: SplitParser { function onStreamFinished() { actionProc1.err = text } }
    function onExited(exitCode, exitStatus) { root.onProcExited(actionProc1, exitCode) }
  }

  Process {
    id: actionProc2
    property string label: ""
    property string out: ""
    property string err: ""
    stdout: SplitParser { function onStreamFinished() { actionProc2.out = text } }
    stderr: SplitParser { function onStreamFinished() { actionProc2.err = text } }
    function onExited(exitCode, exitStatus) { root.onProcExited(actionProc2, exitCode) }
  }

  // ------------------------------------------------------------- capabilities
  //
  // One probe asks the machine which candidate commands exist, and the candidate
  // list is derived from the catalog itself, so it cannot drift out of sync.
  // Re-run when the picker opens so installing something shows up without a
  // shell restart -- the same idea as the menu's volatile providers.

  function catalogCommands() {
    var names = ({})
    var lists = [Catalog.WINDOW, Catalog.SYSTEM, Catalog.KEYBOARDS, Catalog.PIE, root.menuCatalog, root.appCatalog, root.pluginCatalog]
    for (var i = 0; i < lists.length; i++) {
      var list = lists[i]
      if (!list) continue
      for (var j = 0; j < list.length; j++) {
        var e = list[j]
        if (!e) continue
        root.registerProbeName(names, e)
        if (e.chain) {
          for (var k = 0; k < e.chain.length; k++) root.registerProbeName(names, e.chain[k])
        }
      }
    }
    var out = []
    for (var n in names) out.push(n)
    return out
  }

  // Everything the probe must test: the command an entry RUNS and anything it
  // DECLARES it requires. Those differ -- the wvkbd entries run `bash -lc ...`
  // but require `wvkbd-deskintl` -- and probing only argv[0] left every such
  // entry permanently "unavailable", so tapping it offered to install instead
  // of choosing it. The adaptive chain only worked because its first step's
  // command happens to be an argv[0].
  function registerProbeName(names, e) {
    if (!e) return
    if (e.argv && e.argv.length > 0 && e.argv[0]) names[String(e.argv[0])] = true
    var reqs = []
    if (e.requires) reqs = reqs.concat(Array.isArray(e.requires) ? e.requires : [e.requires])
    if (e.requiresAny) reqs = reqs.concat(e.requiresAny)
    for (var i = 0; i < reqs.length; i++) if (reqs[i]) names[String(reqs[i])] = true
  }

  function refreshCapabilities() {
    if (cmdProbe.running) return
    cmdProbe.command = ["bash", "-lc",
      'out="$1"; shift; { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && echo "cmd:$c"; done; echo "---"; omarchy plugin list --json 2>/dev/null; } > "$out"',
      "bash", root.capsPath].concat(root.catalogCommands())
    cmdProbe.running = true
  }

  function parseCommandList(text) {
    var out = ({})
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].replace(/^\s+|\s+$/g, "")
      if (l !== "") out[l] = true
    }
    return out
  }

  // Optimistic before the probe lands, so nothing looks broken during startup.
  function commandAvailable(name) {
    var n = String(name || "")
    if (n === "") return false
    if (n === "bash" || n === "sh") return true
    if (!root.capabilitiesProbed) return true
    return root.availableCommands[n] === true
  }

  function chainEntryAvailable(step) {
    if (!step || !step.argv) return false
    if (step.requires) {
      var req = Array.isArray(step.requires) ? step.requires : [step.requires]
      for (var i = 0; i < req.length; i++) if (!root.commandAvailable(req[i])) return false
      return true
    }
    // No explicit requirement: the command itself has to be present. (Chain
    // steps that wrap a real command in a shell should declare `requires`, or
    // they would look available merely because the shell is.)
    return root.commandAvailable(step.argv[0])
  }

  function entryAvailable(entry) {
    if (!entry) return false
    if (entry.chain) {
      for (var k = 0; k < entry.chain.length; k++)
        if (root.chainEntryAvailable(entry.chain[k])) return true
      return false
    }
    if (entry.requires) {
      var req = Array.isArray(entry.requires) ? entry.requires : [entry.requires]
      for (var i = 0; i < req.length; i++) if (!root.commandAvailable(req[i])) return false
    }
    if (entry.requiresAny) {
      var any = false
      for (var j = 0; j < entry.requiresAny.length; j++)
        if (root.commandAvailable(entry.requiresAny[j])) { any = true; break }
      if (!any) return false
    }
    if (entry.requiresPlugin && !root.enabledPlugins[String(entry.requiresPlugin)]) return false
    return true
  }

  // A suggested remedy for an unavailable entry, so the picker offers it
  // rather than only reporting what is missing. Null when nothing sensible
  // can be suggested.
  function fixFor(entry) {
    if (!entry) return null
    if (entry.requiresPlugin && !root.enabledPlugins[String(entry.requiresPlugin)])
      return { label: "Enable plugin", argv: ["omarchy", "plugin", "enable", String(entry.requiresPlugin)], privileged: false }
    if (entry.install)
      return { label: "Install " + entry.install, argv: ["omarchy", "pkg", "add", String(entry.install)], privileged: true }
    if (entry.installAur)
      return { label: "Install " + entry.installAur + " (AUR)", argv: ["omarchy", "pkg", "aur", "add", String(entry.installAur)], privileged: true }
    return null
  }

  function runFix(entry) {
    var fix = root.fixFor(entry)
    if (!fix) return
    if (fix.privileged) {
      // A package install needs a password, so it runs in a terminal. foot is
      // the only terminal installed here, and omarchy pkg handles its own
      // elevation once it has a tty.
      Util.execArgv(["foot", "bash", "-lc",
        fix.argv.join(" ") + "; echo; echo Done. Press Enter to close.; read _"])
    } else {
      Util.execArgv(fix.argv)
    }
    root.notify(fix.label + " started")
  }

  // Why an entry is unavailable, for the dimmed tile to say so rather than
  // silently refusing a tap.
  function availabilityReason(entry) {
    if (!entry) return "unavailable"
    if (entry.chain) {
      var names = []
      for (var k = 0; k < entry.chain.length; k++) {
        var st = entry.chain[k]
        if (st && st.argv) names.push(st.requires || st.argv[0])
      }
      return "needs " + names.join(" or ")
    }
    if (entry.requires) {
      var req = Array.isArray(entry.requires) ? entry.requires : [entry.requires]
      for (var i = 0; i < req.length; i++)
        if (!root.commandAvailable(req[i])) return "needs " + req[i]
    }
    if (entry.requiresAny) {
      var any = false
      for (var j = 0; j < entry.requiresAny.length; j++)
        if (root.commandAvailable(entry.requiresAny[j])) { any = true; break }
      if (!any) return "needs " + entry.requiresAny.join(" or ")
    }
    if (entry.requiresPlugin && !root.enabledPlugins[String(entry.requiresPlugin)])
      return "needs plugin " + entry.requiresPlugin
    return ""
  }

  // The probe writes to a file and a FileView reads it, rather than capturing
  // stdout. Neither StdioCollector nor SplitParser delivered anything here
  // (verified: the process exited having written output, and the captured text
  // was empty), whereas FileView is already proven on this machine for both
  // dot.json and the menu definition.
  readonly property string capsPath: Quickshell.env("XDG_RUNTIME_DIR") + "/io.github.shaggyd.dotcom.caps"
  property int probeExits: 0

  Process {
    id: cmdProbe
    // "$1" is the output path; the rest are the command names to test.
    command: ["bash", "-lc",
      'out="$1"; shift; { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && echo "cmd:$c"; done; echo "---"; omarchy plugin list --json 2>/dev/null; } > "$out"',
      "bash", root.capsPath].concat(root.catalogCommands())
    onExited: root.probeExits += 1
  }

  FileView {
    id: capsFile
    path: root.capsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseCapabilities(text())
    onFileChanged: reload()
  }

  // One file, two sections: "cmd:<name>" lines, then "---", then the plugin
  // list as JSON.
  function parseCapabilities(raw) {
    var text = String(raw || "")
    var sep = text.indexOf("---")
    var cmdPart = sep >= 0 ? text.substring(0, sep) : text
    var plugPart = sep >= 0 ? text.substring(sep + 3) : ""

    var cmds = ({})
    var lines = cmdPart.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].replace(/^\s+|\s+$/g, "")
      if (l.indexOf("cmd:") === 0 && l.length > 4) cmds[l.substring(4)] = true
    }
    root.availableCommands = cmds

    // The plugin list feeds two things: which plugins are enabled (so entries
    // that need one can dim), and the Plugins catalog itself.
    var list = null
    try { list = JSON.parse(String(plugPart || "[]")) } catch (e) { list = null }
    if (Array.isArray(list)) {
      var enabled = ({})
      for (var j = 0; j < list.length; j++)
        if (list[j] && list[j].id && list[j].enabled === true) enabled[String(list[j].id)] = true
      root.enabledPlugins = enabled
      root.pluginCatalog = root.buildPluginCatalog(list)
    }
    root.capabilitiesProbed = true
  }

  // Shell plugins that can be summoned, i.e. the loader-backed kinds. Services
  // are excluded -- they have no panel to open -- and the pie excludes itself,
  // since a slice that opened the pie would be a loop.
  function buildPluginCatalog(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p || !p.id) continue
      var id = String(p.id)
      if (id === root.pluginId) continue
      var kinds = Array.isArray(p.kinds) ? p.kinds : []
      var section = ""
      if (kinds.indexOf("overlay") !== -1) section = "Overlays"
      else if (kinds.indexOf("menu") !== -1) section = "Menus"
      else if (kinds.indexOf("panel") !== -1) section = "Panels"
      else continue
      out.push({
        key: "plugin." + id,
        label: String(p.name || id),
        glyph: Catalog.g(0xE1BD),
        group: "Plugins",
        section: section,
        // The action needs that plugin enabled, so a disabled one dims with a
        // reason rather than offering a tap that cannot work.
        requiresPlugin: id,
        argv: ["omarchy-shell", "shell", "toggle", id]
      })
    }
    return out
  }

  // ---------------------------------------------------------------- lifecycle

  function resolveScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    if (name === "") return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === name) return screens[i]
    }
    return null
  }

  // Point the window at the focused monitor, but only when it is genuinely a
  // different one. resolveScreen() hands back a fresh wrapper object every
  // call, and assigning that unconditionally re-binds PanelWindow.screen --
  // which tears the layer surface down and back up. During that rebuild the
  // window briefly reports a zero size, the dot's computed position collapses
  // to the top-left margin, and the whole pie is drawn in the corner. So this
  // compares names and does nothing when they already agree.
  function syncScreen() {
    var want = root.resolveScreen()
    if (!want) return
    if (root.targetScreen && String(root.targetScreen.name) === String(want.name)) return
    root.targetScreen = want
    // A different screen means different bounds, so the cached size is now a
    // lie. Without this the dot clamps and sizes the pie against the old
    // monitor's dimensions.
    root.invalidateGeometry()
  }

  function open(payloadJson) {
    root.syncScreen()
    root.hoveredSlice = -1
    root.opened = true
    root.moved = false
    root.dragArmed = false
    root.pressedWhileOpen = false
    root.holdProgress = 0
    holdTimer.stop()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  // Dismissal is always local-first: opened false makes the scrim and the pie
  // collapse immediately, and the shell is told afterwards so the host's
  // open-panel bookkeeping agrees.
  function dismiss() {
    if (!root.opened) return
    root.opened = false
    root.hoveredSlice = -1
    repeatTimer.stop()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function close() {
    root.dismiss()
  }

  // Routed through the host so its open-panel bookkeeping agrees with ours.
  // Setting `opened` directly left the host believing the pie was closed, so
  // an external `omarchy-shell shell toggle` (and therefore the SUPER+PERIOD
  // binding) always took the summon branch and could re-open but never close.
  //
  // No recursion: shell.toggle reaches open() via the host's loader, and
  // open() does not call back into the host.
  function toggle() {
    if (root.shell && typeof root.shell.toggle === "function")
      return root.shell.toggle(root.pluginId, "{}")
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  onOpenedChanged: {
    pieProgress = opened ? 1 : 0
    if (!opened) { repeatTimer.stop(); wobbleAnim.stop(); wobbleAngle = 0 }
    if (opened && root.config.physics && root.config.wobble) wobbleAnim.restart()
  }

  Behavior on pieProgress {
    // Physics on: OutBack overshoots past 1 and settles, so the pie pops out
    // of the dot. Close uses an accelerating ease so it never swings below
    // zero -- a spring there would mirror the pie through the origin.
    NumberAnimation {
      duration: root.opened
        ? (root.config.physics && root.config.springOpen ? 340 : 190)
        : 170
      easing.type: root.opened
        ? ((root.config.physics && root.config.springOpen) ? Easing.OutBack : Easing.OutCubic)
        : Easing.InCubic
    }
  }

  // Damped spin, kicked on open: OutElastic decays from the kick to zero, so
  // the ring rotates out and wobbles back into place.
  NumberAnimation {
    id: wobbleAnim
    target: root
    property: "wobbleAngle"
    from: root.wobbleKick
    to: 0
    duration: 900
    easing.type: Easing.OutElastic
    easing.amplitude: 1.1
    easing.period: 0.3
  }

  Behavior on squashX {
    SpringAnimation { spring: 4.5; damping: 0.4; epsilon: 0.002 }
  }
  Behavior on squashY {
    SpringAnimation { spring: 4.5; damping: 0.4; epsilon: 0.002 }
  }

  // ------------------------------------------------------------------ config

  function applyState(raw) {
    if (!raw) return
    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      return
    }
    if (!parsed || typeof parsed !== "object") return
    var merged = {}
    for (var key in root.config) merged[key] = root.config[key]
    for (var k in parsed) {
      if (Object.prototype.hasOwnProperty.call(root.config, k)) merged[k] = parsed[k]
    }
    root.config = merged
    root.maybeGreet()
  }

  function persist() {
    var payload = {}
    for (var key in root.config) payload[key] = root.config[key]
    stateFile.setText(JSON.stringify(payload, null, 2) + "\n")
  }

  // ----------------------------------------------------------------- geometry

  readonly property real dotSize: Math.max(28, Number(config.dotSize) || 48)
  readonly property real iconSize: Math.max(18, Number(config.iconSize) || 30)
  readonly property real holdMs: Math.max(150, Number(config.holdMs) || 600)
  readonly property real innerRadius: dotSize * 0.62

  // Pointer position in screen coordinates, valid only while dragging.
  property real dragX: 0
  property real dragY: 0
  // Where the finger sat inside the touch target when the press began, so the
  // dot does not jump to centre itself under a finger that landed off-centre.
  property real grabOffsetX: 0
  property real grabOffsetY: 0

  readonly property real edgeMargin: dotSize / 2 + Style.space(8)

  // Cached screen size. Held because a screen switch briefly reports a zero
  // size, and clamping against zero is what put the dot in the corner -- but
  // it must be invalidated when the size genuinely changes, or the dot clamps
  // and sizes the pie against the previous monitor's bounds forever. That is
  // what onWidthChanged/onHeightChanged and syncScreen() are for.
  property real screenW: 0
  property real screenH: 0

  // The idle touch target, and the size of the input region that must be
  // opened up for the dot to be pressable at all.
  readonly property real dotPad: Style.space(16)
  readonly property real closedSize: dotSize + dotPad * 2

  // Last position computed while the window had a real size. Held so a
  // transient zero-size window (a screen switch, a layer rebuild) leaves the
  // dot where the user put it instead of collapsing it to the top-left margin.
  property real stableX: 0
  property real stableY: 0
  property bool haveGeometry: false

  function invalidateGeometry() {
    if (root.screenW === 0 && root.screenH === 0 && !root.haveGeometry) return
    root.screenW = 0
    root.screenH = 0
    root.haveGeometry = false
    geometryWatch.running = true
  }

  function computeFromFraction(fraction, extent, fallback) {
    if (!(extent > 0)) return fallback
    var lo = root.comfortInset
    var hi = Math.max(lo, extent - lo)
    var f = Util.clamp(Number(fraction) || 0, 0, 1)
    return Util.clamp(f * extent, lo, hi)
  }

  function captureGeometry() {
    var w = panel.width > 0 ? panel.width : root.screenW
    var h = panel.height > 0 ? panel.height : root.screenH
    if (w > 0 && h > 0) {
      root.screenW = w
      root.screenH = h
      stableX = computeFromFraction(config.fx, w, stableX)
      stableY = computeFromFraction(config.fy, h, stableY)
      haveGeometry = true
    }
  }

  function clampToScreen(x, y) {
    var w = root.screenW > 0 ? root.screenW : panel.width
    var h = root.screenH > 0 ? root.screenH : panel.height
    var lo = root.comfortInset
    return Qt.point(
      Util.clamp(x, lo, Math.max(lo, w - lo)),
      Util.clamp(y, lo, Math.max(lo, h - lo)))
  }


  // The dot's centre, in window coordinates. The window covers the screen, so
  // these are screen coordinates too: the pointer while dragging, otherwise
  // the stored fractions of the screen.
  readonly property real dotX: root.dragging
    ? root.dragX
    : (root.screenW > 0 ? computeFromFraction(config.fx, root.screenW, stableX) : stableX)
  readonly property real dotY: root.dragging
    ? root.dragY
    : (root.screenH > 0 ? computeFromFraction(config.fy, root.screenH, stableY) : stableY)

  function rememberPosition() {
    // Only meaningful with a sized window; without one the fractions would be
    // garbage, so the previous spot is kept instead.
    if (!(root.screenW > 0 && root.screenH > 0)) return
    var next = {}
    for (var key in root.config) next[key] = root.config[key]
    next.fx = Util.clamp(root.dotX / root.screenW, 0, 1)
    next.fy = Util.clamp(root.dotY / root.screenH, 0, 1)
    root.config = next
    // The stored spot and the live position now agree, so refresh the cached
    // geometry too rather than leaving it one drag behind.
    root.stableX = root.dotX
    root.stableY = root.dotY
    root.haveGeometry = true
    root.persist()
  }

  // How far the pie reaches past its radius: the outer rim and a little slack
  // so a slice never sits flush against the screen edge.
  readonly property real rimSlack: Style.space(26)

  // The pie is always centred exactly on the dot. An earlier version instead
  // slid the whole pie inward whenever the dot neared an edge, which kept the
  // slices on screen but left the hub somewhere the finger was not -- the
  // centre has to be the dot, or the control stops feeling like one object.
  //
  // A second version kept the centre on the dot and shrank the radius to
  // whatever still fit. That also solved the edge, but it meant the wedges
  // resized and slid under the finger as the dot was dragged near a border,
  // which is worse than the dot being slightly less free to move.
  //
  // So the constraint moves to the dot instead: it is confined to a rect inset
  // by the full pie radius, and the pie is then always full size. `comfort:
  // false` in the state file restores the shrinking behaviour.
  readonly property real configuredRadius: Math.max(90, Number(config.radius) || 132)

  // The << + >> bar sits outside the ring, below it when there is room and
  // above it otherwise. Reserving space for it out of the screen edge was the
  // first attempt and it was wrong: it re-clamped the dot, so entering edit
  // mode visibly shifted the pie off the spot the dot was on. The bar moves
  // instead; the centre never does.
  readonly property real editBarHeight: Style.space(46)
  readonly property real editBarGap: Style.space(12)
  readonly property real editBarRoomBelow: (root.screenH > 0 ? root.screenH : panel.height)
    - root.dotY - root.outerRadius - root.editBarGap - Style.space(8)
  readonly property bool editBarBelow: root.editBarRoomBelow >= root.editBarHeight
  readonly property real editBarY: root.editBarBelow
    ? (root.dotY + root.outerRadius + root.editBarGap)
    : (root.dotY - root.outerRadius - root.editBarGap - root.editBarHeight)

  readonly property real comfortInset: {
    var base = root.edgeMargin
    if (root.config.comfort === false) return base
    if (!(root.screenW > 0 && root.screenH > 0)) return base
    // Never let the inset exceed half the shorter side, or lo > hi and the
    // clamp inverts on a small display.
    var cap = Math.max(base, Math.min(root.screenW, root.screenH) / 2)
    return Math.min(root.configuredRadius + root.rimSlack, cap)
  }

  // Safety net only. With the comfort rect in force this rarely binds, but it
  // still guards a screen too small to hold a full-size pie.
  readonly property real fitRadius: Math.max(56, Math.min(
    dotX - rimSlack,
    root.screenW - dotX - rimSlack,
    dotY - rimSlack,
    root.screenH - dotY - rimSlack))

  readonly property real outerRadius: Math.min(configuredRadius, fitRadius)

  // Keep the icons proportional on a shrunken pie, or they overlap each other.
  readonly property real effectiveIconSize: Math.max(16, Math.min(iconSize, outerRadius * 0.34))

  readonly property point pieCentre: Qt.point(dotX, dotY)

  // Sector under a point, or -1 for the hub / the void outside the ring.
  function sliceAt(x, y) {
    var dx = x - root.pieCentre.x
    var dy = y - root.pieCentre.y
    var dist = Math.sqrt(dx * dx + dy * dy)
    if (dist < root.innerRadius || dist > root.outerRadius + Style.space(14)) return -1
    // Compass degrees, 0 at the top, increasing clockwise -- the same frame
    // sliceStartAngle() draws in, which is what makes the drawn slice and the
    // tapped slice the same slice.
    var deg = Math.atan2(dy, dx) * 180 / Math.PI + 90
    while (deg < 0) deg += 360
    while (deg >= 360) deg -= 360
    return Math.round(deg / root.sectorAngle) % root.sliceCount
  }

  function sectorPath(ctx, cx, cy, rOuter, rInner, startDeg, endDeg) {
    var toRad = Math.PI / 180
    var a0 = (startDeg - 90) * toRad
    var a1 = (endDeg - 90) * toRad
    ctx.beginPath()
    ctx.arc(cx, cy, rOuter, a0, a1)
    ctx.arc(cx, cy, rInner, a1, a0, true)
    ctx.closePath()
  }

  Connections {
    target: Hyprland
    function onFocusedMonitorChanged() {
      if (!root.opened) root.syncScreen()
    }
  }

  // Canvas is retained-mode: it does not repaint when a bound colour merely
  // changes. The theme is applied by reassigning Color's properties, so the
  // pie and the hold ring would otherwise keep drawing the old palette until
  // some unrelated change happened to trigger a paint. `themeRevision` is the
  // broadcast the per-slice and chrome canvases listen to for that repaint.
  property int themeRevision: 0

  Connections {
    target: Color
    function onAccentChanged() { root.themeRevision += 1; holdRing.requestPaint() }
    function onForegroundChanged() { root.themeRevision += 1; holdRing.requestPaint() }
    function onBackgroundChanged() { root.themeRevision += 1 }
    function onUrgentChanged() { root.themeRevision += 1; holdRing.requestPaint() }
  }

  onTargetScreenChanged: if (targetScreen === null) root.syncScreen()

  // In use mode the display order and the identity order are the same thing,
  // so keep them in step. Reorders only ever happen while editing, and there
  // syncStableIds() is called explicitly instead.
  onActiveSlicesChanged: root.syncStableIds()

  // DesktopEntries scans asynchronously. buildAppCatalog() caches on
  // length > 0, so a build that ran before the scan finished would leave a
  // short (or empty) app list for the rest of the session. Rebuild when the
  // scan reports in.
  Connections {
    target: DesktopEntries
    function onApplicationsChanged() {
      root.appCatalog = []
      root.buildAppCatalog()
    }
  }

  // A resize (resolution change, added/removed monitor, rotation) invalidates
  // the cached bounds. Without these the geometryWatch timer had already
  // stopped on its first success and nothing ever re-measured the surface.
  Connections {
    target: panel
    function onWidthChanged() { root.invalidateGeometry() }
    function onHeightChanged() { root.invalidateGeometry() }
  }

  // One place that turns the current pointer position into a dot position, so
  // the drag cannot end up driven by two different code paths.
  //
  // It is called both from mouse motion and from the hold timer, because a
  // drag that relies only on motion events stops dead the moment those events
  // go missing; sampling on a timer keeps following the finger either way.
  function sampleDrag() {
    if (!dotInput.pressed || !root.dragArmed) return
    var p = dotInput.mapToItem(screenSpace, dotInput.mouseX, dotInput.mouseY)
    var c = root.clampToScreen(p.x + root.grabOffsetX, p.y + root.grabOffsetY)
    if (Math.abs(c.x - root.dotX) > Style.space(3) || Math.abs(c.y - root.dotY) > Style.space(3))
      root.moved = true
    // Low-passed velocity, px/s, for the release glide. Sampling runs on both
    // motion events and the hold timer, so it stays fed even when motion events
    // dry up mid-drag.
    var t = Date.now()
    if (root.lastSampleT > 0) {
      var dt = (t - root.lastSampleT) / 1000
      if (dt > 0.001) {
        root.vX = 0.6 * ((c.x - root.dragX) / dt) + 0.4 * root.vX
        root.vY = 0.6 * ((c.y - root.dragY) / dt) + 0.4 * root.vY
      }
    }
    root.lastSampleT = t
    root.dragX = c.x
    root.dragY = c.y
  }

  // Project the flick and glide to a stop, bouncing off an edge with
  // Easing.OutBounce when the projection would leave the screen. Returns false
  // for a slow release, which just lands where the finger left it.
  function startInertia() {
    var speed = Math.sqrt(root.vX * root.vX + root.vY * root.vY)
    if (speed < 500) return false
    var px = root.dotX + root.vX * 0.30
    var py = root.dotY + root.vY * 0.30
    var c = root.clampToScreen(px, py)
    var bounced = Math.abs(c.x - px) > 0.5 || Math.abs(c.y - py) > 0.5
    var dur = Util.clamp(700 - speed / 8, 260, 700)
    inertiaAnimX.to = c.x
    inertiaAnimY.to = c.y
    inertiaAnimX.duration = dur
    inertiaAnimY.duration = dur
    inertiaAnimX.easing.type = bounced ? Easing.OutBounce : Easing.OutCubic
    inertiaAnimY.easing.type = bounced ? Easing.OutBounce : Easing.OutCubic
    inertiaAnim.restart()
    return true
  }

  // ---- radial drag-select -------------------------------------------------
  //
  // A quick outward drag from the idle dot fans the pie and highlights whatever
  // slice the finger is over; releasing runs it. This is deliberately the
  // opposite timing to moving the dot: the move needs a hold in the centre,
  // while this fires the moment the finger travels outward, so the two never
  // compete.

  function beginRadialSelect() {
    holdTimer.stop()
    root.radialSelecting = true
    // The hold was arming a drag; that is cancelled outright, so the dot stays
    // put and the select takes over.
    root.dragging = false
    root.dragArmed = false
    root.moved = false
    root.holding = false
    root.holdProgress = 0
    root.squashX = 1
    root.squashY = 1
    root.pressedWhileOpen = false
    root.open("{}")
    root.updateRadialSelect()
  }

  function updateRadialSelect() {
    var p = dotInput.mapToItem(screenSpace, dotInput.mouseX, dotInput.mouseY)
    var dx = p.x - root.pieCentre.x
    var dy = p.y - root.pieCentre.y
    var d = Math.sqrt(dx * dx + dy * dy)
    // Past the hub the slice under the finger lights up (and, being pressed,
    // springs out); inside the hub nothing is selected.
    root.hoveredSlice = (d >= root.innerRadius) ? root.sliceAt(p.x, p.y) : -1
    root.slicePressed = root.hoveredSlice >= 0
  }

  function endRadialSelect() {
    var index = root.hoveredSlice
    root.radialSelecting = false
    root.slicePressed = false
    root.hoveredSlice = -1
    if (index < 0 || index >= root.displaySlices.length) { root.dismiss(); return }
    var slice = root.displaySlices[index]
    if (!slice) { root.dismiss(); return }
    // Editor commands act on the pie itself, so they must not collapse it first.
    if (slice.plugin) { root.runSlice(slice); return }
    // Let the pie collapse before the action runs, as a tap does.
    root.dismiss()
    root.pendingSlice = slice
    actionDelay.restart()
  }

  // The release glide. Runs while `dragging` is still true, so dotX/dotY keep
  // reading dragX/dragY; on finish it persists the resting spot and clears the
  // drag state. remembersPosition() must run before dragging clears, or it
  // would read the stale stored fractions.
  ParallelAnimation {
    id: inertiaAnim
    NumberAnimation { id: inertiaAnimX; target: root; property: "dragX" }
    NumberAnimation { id: inertiaAnimY; target: root; property: "dragY" }
    onFinished: {
      root.rememberPosition()
      root.dragging = false
      root.dragArmed = false
      root.holding = false
      root.moved = false
    }
  }

  Timer {
    id: holdTimer
    // Fine enough for the ring to look continuous. The arming decision reads
    // elapsed wall-clock time rather than counting ticks, so the hold is
    // holdMs regardless of how this interval is tuned -- accumulating a fixed
    // fraction per tick overshot by a whole extra tick and stretched 2000ms
    // out to 2331ms.
    interval: 50
    repeat: true
    onTriggered: {
      if (root.radialSelecting) return
      if (root.dragArmed) {
        // Keep sampling for as long as the finger is down.
        if (root.dragging) root.sampleDrag()
        return
      }
      var elapsed = Date.now() - root.holdStartedAt
      root.holdProgress = Math.min(1, elapsed / root.holdMs)
      if (root.holdProgress >= 1) {
        root.dragArmed = true
        // Only now does the dot start reading a drag position. Seeding it
        // from the dot's current centre means arming mid-gesture cannot
        // teleport it, and `clampToScreen` keeps it on the display.
        root.dragX = root.dotX
        root.dragY = root.dotY
        root.dragging = true
        // Deliberately not stopped: the timer is what keeps the drag fed.
      }
    }
  }

  // ------------------------------------------------------------------- window

  PanelWindow {
    id: panel
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "io-github-shaggyd-dotcom"
    WlrLayershell.layer: WlrLayer.Overlay
    // Only take the keyboard while the pie is up. The idle dot must never
    // hold focus, or it would swallow every keystroke aimed at the desktop.
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // This surface covers the whole screen all the time, and a layer-shell
    // surface with no mask takes the entire area as its input region -- which
    // is why the desktop stopped responding to the mouse and to fingers. The
    // mask is the input region, so while the pie is closed it is shrunk to the
    // dot's own touch target and every other pixel falls through to whatever
    // is underneath. Omarchy's own OSD does the same thing with an empty
    // Region; this one is empty except where the dot is.
    mask: hitRegion

    // No full-screen scrim. The pie is drawn as translucent slices over the
    // desktop rather than dimming it, so what is behind stays legible and
    // the dot never blacks out the screen it is meant to sit on top of.
    // `pieInput` below still covers the window, so a tap outside a slice is
    // swallowed and dismissed instead of landing on the window underneath.

    // A plain, empty Item filling the window, used only as a mapToItem target.
    //
    // PanelWindow cannot be one: its C++ type is
    // qs::wayland::layershell::WaylandPanelInterface, and mapToItem()'s first
    // parameter is a QQuickItem*, so every call with `panel` threw
    //   "Could not convert argument 0 from ...WaylandPanelInterface to const
    //    QQuickItem*"
    // at runtime. Inside dotInput.onPressed that exception aborted the handler
    // before holdTimer.restart(), so the hold never armed, sampleDrag() always
    // bailed out, and the dot could not be dragged at all -- a long press just
    // opened the pie. Mapping into this Item instead gives the same
    // window-relative coordinates (it is anchored to the same rect, and the
    // window covers the screen, so they are screen coordinates).
    Item {
      id: screenSpace
      anchors.fill: parent
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      visible: root.opened
      focus: root.opened
      onCloseRequested: root.escapeAction()
    }

    // ------------------------------------------------------------------- pie

    Item {
      id: pie
      anchors.fill: parent
      visible: root.pieProgress > 0.01
      opacity: root.pieProgress
      // Open/close is a transform on the whole pie, not a repaint of every
      // wedge. The wedges are drawn once at full size and this scales the pie
      // out of the dot, so the 190ms animation costs nothing per frame -- a
      // transform is a GPU operation. The origin is the dot, so it grows from
      // there, exactly as the old radius ramp did.
      transform: [
        Scale {
          origin.x: root.pieCentre.x
          origin.y: root.pieCentre.y
          xScale: root.pieProgress
          yScale: root.pieProgress
        },
        Rotation {
          origin.x: root.pieCentre.x
          origin.y: root.pieCentre.y
          angle: root.wobbleAngle
        }
      ]

      // One delegate per slice IDENTITY, not per slot. That is the whole point
      // of this structure: reordering changes each delegate's `slot`, which
      // changes its `angle` binding, and the Behavior below animates it. With
      // an index-keyed model the delegates never move -- each index keeps its
      // position and merely shows different data -- so there is nothing to
      // animate, which is why rotation used to need a separate global offset
      // and why a drag-shuffle could not have been animated at all.
      Repeater {
        model: root.stableIds

        delegate: Item {
          id: sliceItem
          required property var modelData          // slice id

          readonly property var slice: root.sliceForId(modelData)
          readonly property int slot: root.slotOfId(modelData)
          readonly property bool hot: root.hoveredSlice === slot
          // The slice being dragged follows the finger; everything else sits
          // in its slot. On release dragId clears and the small difference
          // between the two animates away.
          // Not readonly: Behavior on angle writes to it while animating.
          property real angle: (root.dragId === modelData)
            ? root.dragAngle
            : root.sectorAngle * slot
          readonly property real rad: angle * Math.PI / 180
          readonly property real labelR: root.outerRadius * 0.6
          // Dimmed rather than failing on tap, so a slice whose dependency has
          // gone is visibly unusable before you press it.
          readonly property bool available: root.sliceAvailable(sliceItem.slice)

          anchors.fill: parent
          visible: sliceItem.slice !== null

          // Reorder neighbours spring aside instead of sliding linearly.
          Behavior on angle {
            SpringAnimation {
              spring: root.config.physics ? 2.6 : 400
              damping: root.config.physics ? 0.4 : 1.0
              epsilon: 0.5
            }
          }

          // Each wedge paints itself, so it can move independently of its
          // neighbours (a drag-shuffle animates each wedge's angle). Sized to
          // the pie rather than the screen: a full-window canvas per slice
          // meant up to nine screen-sized rasters being rasterised. A wedge
          // never reaches past the outer rim, so the pie's diameter is enough.
          Canvas {
            id: wedge
            width: Math.ceil(root.outerRadius * 2 + Style.space(6))
            height: width
            x: Math.round(root.pieCentre.x - width / 2)
            y: Math.round(root.pieCentre.y - height / 2)

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var cx = width / 2
              var cy = height / 2
              var innerR = root.innerRadius
              var outerR = root.outerRadius
              var half = root.sectorAngle / 2
              // Inset each edge a little so neighbouring wedges read as
              // separate segments rather than one solid disc.
              root.sectorPath(ctx, cx, cy, (sliceItem.hot ? Math.max(1, outerR - 3) : outerR), innerR,
                              sliceItem.angle - half + 0.7, sliceItem.angle + half - 0.7)
              ctx.fillStyle = sliceItem.hot
                ? Util.alpha(Color.accent, 0.92)
                : Util.alpha(Color.background, 0.78)
              ctx.fill()

              // Leading spoke, hub to outer radius, stopping at the rim.
              var deg = (sliceItem.angle - half) * Math.PI / 180
              var sin = Math.sin(deg), cos = Math.cos(deg)
              ctx.beginPath()
              ctx.moveTo(cx + sin * innerR, cy - cos * innerR)
              ctx.lineTo(cx + sin * outerR, cy - cos * outerR)
              ctx.lineWidth = Style.space(1)
              ctx.strokeStyle = Util.alpha(Color.foreground, 0.45)
              ctx.stroke()
            }

            onVisibleChanged: if (visible) requestPaint()
            Connections {
              target: sliceItem
              function onAngleChanged() { wedge.requestPaint() }
              function onHotChanged() { wedge.requestPaint() }
            }
            // No onPieProgressChanged repaint: open/close is the container
            // transform above, so the wedge is painted once and scaled, not
            // repainted on every animation frame.
            Connections {
              target: root
              function onSectorAngleChanged() { wedge.requestPaint() }
              function onOuterRadiusChanged() { wedge.requestPaint() }
              function onInnerRadiusChanged() { wedge.requestPaint() }
              function onThemeRevisionChanged() { wedge.requestPaint() }
            }
          }

          Column {
            id: sliceBody
            spacing: Style.space(3)

            // Collapsed, every slice sits on the dot itself; opening walks each
            // one out along its own radius, and dismissing walks them back in.
            //
            // Compass -> screen: a compass angle of 0 means straight up, but
            // plain cos/sin puts 0 on the +x axis, i.e. due right. Using them
            // raw rotated every icon a quarter turn clockwise from the wedge it
            // belongs to, so tapping what looked like "Close" ran whatever sat
            // 90 degrees round. sin drives x and cos drives y, negated.
            // Positioned at the full radius; the pie container transform does
            // the growing, so no pieProgress here or it would scale twice.
            x: root.pieCentre.x + Math.sin(sliceItem.rad) * sliceItem.labelR - width / 2
            y: root.pieCentre.y - Math.cos(sliceItem.rad) * sliceItem.labelR - height / 2
            opacity: sliceItem.available ? 1 : 0.35
            // Hover grows a slice; a press springs it out further (the
            // magnet), which reads as the slice rising to meet the finger.
            readonly property bool magnet: root.config.physics
              && root.slicePressed && root.hoveredSlice === sliceItem.slot
            scale: (sliceItem.hot ? 1.12 : 1) * (magnet ? 1.22 : 1)

            Behavior on scale {
              SpringAnimation {
                spring: root.config.physics ? 3.0 : 400
                damping: root.config.physics ? 0.35 : 1.0
                epsilon: 0.005
              }
            }

            // App slices carry an image; everything else a glyph. Menu-catalog
            // glyphs are Nerd Font, so they use the menu family -- rendering
            // them in Material Symbols gives tofu.
            Image {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: sliceItem.slice !== null && !!sliceItem.slice.icon
              source: sliceItem.slice ? sliceItem.slice.icon : ""
              sourceSize.width: root.effectiveIconSize
              sourceSize.height: root.effectiveIconSize
              width: root.effectiveIconSize
              height: root.effectiveIconSize
              fillMode: Image.PreserveAspectFit
              smooth: true
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: sliceItem.slice !== null && !sliceItem.slice.icon
              text: sliceItem.slice ? sliceItem.slice.glyph : ""
              color: sliceItem.hot ? root.labelActiveColor : Color.foreground
              font.family: (sliceItem.slice && sliceItem.slice.font === "menu")
                ? Style.font.menuFamily : root.iconFamily
              font.pixelSize: root.effectiveIconSize
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.config.showLabels && root.pieProgress > 0.6
              text: sliceItem.slice ? sliceItem.slice.label : ""
              color: sliceItem.hot ? root.labelActiveColor : root.labelColor
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              // The label must never spill into the neighbouring wedge, which
              // it starts to do once a short label sits next to a long one.
              elide: Text.ElideRight
              width: Math.min(implicitWidth, root.outerRadius * 0.5)
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }

      // Hub and rims. Declared after the wedges so the outer rim overlays the
      // wedge edges, which is the order the old single canvas painted in.
      // Pie-sized like the wedges, and drawn once: the container transform
      // animates it out of the dot.
      Canvas {
        id: pieChrome
        width: Math.ceil(root.outerRadius * 2 + Style.space(6))
        height: width
        x: Math.round(root.pieCentre.x - width / 2)
        y: Math.round(root.pieCentre.y - height / 2)

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var cx = width / 2
          var cy = height / 2

          // Hub, so the pie reads as one object with a centre rather than a
          // ring of loose segments.
          ctx.beginPath()
          ctx.arc(cx, cy, root.innerRadius, 0, Math.PI * 2)
          ctx.fillStyle = Util.alpha(Color.background, 0.86)
          ctx.fill()

          // Outer rim: the theme's popup/card border, which Omarchy wires to
          // the Hyprland active-border colour, so the ring matches window
          // borders and follows theme switches.
          ctx.beginPath()
          ctx.arc(cx, cy, root.outerRadius, 0, Math.PI * 2)
          ctx.lineWidth = Style.space(1)
          ctx.strokeStyle = Util.alpha(root.ringBorderColor, 1)
          ctx.stroke()

          ctx.beginPath()
          ctx.arc(cx, cy, root.innerRadius, 0, Math.PI * 2)
          ctx.lineWidth = Style.space(1)
          ctx.strokeStyle = Util.alpha(Color.foreground, 0.28)
          ctx.stroke()
        }

        onVisibleChanged: if (visible) requestPaint()
        Connections {
          target: root
          function onOuterRadiusChanged() { pieChrome.requestPaint() }
          function onInnerRadiusChanged() { pieChrome.requestPaint() }
          function onThemeRevisionChanged() { pieChrome.requestPaint() }
        }
      }

      // Selection ripple: a one-shot ring pulse where a slice was tapped.
      Rectangle {
        id: ripple
        width: Style.space(30)
        height: width
        radius: width / 2
        color: "transparent"
        border.width: Style.space(2)
        border.color: Color.accent
        opacity: 0
        visible: opacity > 0.01
        z: 30

        ParallelAnimation {
          id: rippleAnim
          NumberAnimation {
            target: ripple; property: "scale"
            from: 0.4; to: 2.4; duration: 430; easing.type: Easing.OutCubic
          }
          NumberAnimation {
            target: ripple; property: "opacity"
            from: 0.9; to: 0; duration: 430; easing.type: Easing.OutCubic
          }
        }
      }

      // A single surface over the whole window owns pie interaction, so a
      // drag that wanders off a slice keeps tracking instead of falling
      // through to the scrim and closing the menu mid-gesture.
      MouseArea {
        id: pieInput
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true

        // Whether the press landed on a slice that ramps, and which one.
        // Both are decided on press, not release, so sliding off the wedge
        // mid-hold cannot hand the release to a different slice. The index is
        // kept because repeatTimer reads it on every tick.
        property bool pressRamps: false
        property int pressIndex: -1

        // Drag-to-reorder bookkeeping (edit mode only). `dragged` is
        // deliberately not cleared on release: Qt delivers released before
        // clicked, so onClicked needs it to know a drag is not a tap.
        property bool pressActive: false
        property bool dragged: false
        property real pressX: 0
        property real pressY: 0

        // The picker card owns input while it is up, including the area
        // outside the card (its scrim handles that).
        enabled: root.mode !== "pick"

        function angleAt(x, y) {
          var deg = Math.atan2(y - root.pieCentre.y, x - root.pieCentre.x) * 180 / Math.PI + 90
          while (deg < 0) deg += 360
          while (deg >= 360) deg -= 360
          return deg
        }

        onPositionChanged: function (mouse) {
          if (root.opened) root.hoveredSlice = root.sliceAt(mouse.x, mouse.y)
          if (!pieInput.pressActive || root.mode !== "edit") return
          var dx = mouse.x - pieInput.pressX
          var dy = mouse.y - pieInput.pressY
          if (!pieInput.dragged) {
            // A tap opens the picker, so the drag only begins once the finger
            // has actually travelled -- same tap-vs-drag split as the dot.
            if (Math.sqrt(dx * dx + dy * dy) < Style.space(12)) return
            var from = root.sliceAt(pieInput.pressX, pieInput.pressY)
            if (from < 0) return
            var s = root.displaySlices[from]
            if (!s) return
            pieInput.dragged = true
            root.dragId = s.id
          }
          root.dragAngle = pieInput.angleAt(mouse.x, mouse.y)
          root.reorderDrag()
        }

        onPressed: function (mouse) {
          pieInput.pressActive = true
          pieInput.dragged = false
          pieInput.pressX = mouse.x
          pieInput.pressY = mouse.y
          var index = root.sliceAt(mouse.x, mouse.y)
          pieInput.pressRamps = false
          pieInput.pressIndex = -1
          root.slicePressed = index >= 0
          if (root.mode === "use" && index >= 0) root.rippleAt(index)
          if (root.mode !== "use" || index < 0) return
          var slice = root.displaySlices[index]
          if (slice && slice.repeat === true) {
            pieInput.pressRamps = true
            pieInput.pressIndex = index
            // Fire on press, not release, and keep firing while held. This is
            // what makes a +5% step usable: tap for one notch, hold to ramp.
            // The pie stays up so the OSD underneath stays visible and the
            // release is still delivered to this area.
            root.runSlice(slice)
            repeatTimer.restart()
          }
        }

        onReleased: {
          repeatTimer.stop()
          pieInput.pressActive = false
          root.slicePressed = false
          if (pieInput.dragged) root.endDrag()
        }

        onCanceled: {
          repeatTimer.stop()
          pieInput.pressActive = false
          pieInput.pressRamps = false
          pieInput.pressIndex = -1
          root.slicePressed = false
          if (pieInput.dragged) { pieInput.dragged = false; root.endDrag() }
        }

        onClicked: function (mouse) {
          repeatTimer.stop()
          // A drag is not a tap, and must not fall through to "open the
          // picker" or to firing an action.
          if (pieInput.dragged) {
            pieInput.dragged = false
            return
          }
          // A ramping slice already fired on press and has been repeating
          // since. Releasing anywhere -- including outside the wedge -- just
          // puts the pie away, and must not fire a second, different action
          // the finger happened to come to rest on.
          if (pieInput.pressRamps) {
            pieInput.pressRamps = false
            pieInput.pressIndex = -1
            root.dismiss()
            return
          }
          var index = root.sliceAt(mouse.x, mouse.y)

          // Editing: a tap on a slice opens the picker for it, a tap in the
          // void discards (with a confirm if the draft is dirty).
          if (root.mode === "edit") {
            if (index < 0) {
              root.cancelEdit()
              return
            }
            var editing = root.displaySlices[index]
            // The editor slice is always present and cannot be changed, so
            // opening a picker for it would offer only a way to break that.
            if (root.isEditorSlice(editing)) {
              root.notify("Settings is always present and cannot be changed")
              return
            }
            root.openPickerFor(index)
            return
          }

          if (index < 0) {
            root.dismiss()
            return
          }
          var slice = root.displaySlices[index]
          // Editor commands act on the pie itself, so they must not collapse
          // it first -- "Settings" opens the editor and stays open.
          if (slice.plugin) {
            root.runSlice(slice)
            return
          }
          root.dismiss()
          // Let the pie collapse before the action runs, so something that
          // wants the keyboard or a fullscreen surface finds a clean layer
          // stack rather than ours on top of it.
          root.pendingSlice = slice
          actionDelay.restart()
        }
      }
    }

    // The live input region. Collapsed to the dot's touch target while idle,
    // but opened to the whole surface the instant a finger lands -- and while
    // the pie is up.
    //
    // That widening is what makes dragging possible at all. A layer-shell
    // input region also decides where pointer events are delivered, so with
    // the region pinned to the 80px dot, the first movement that carried the
    // finger outside that box stopped delivering motion, `moved` never became
    // true, and the gesture ended up being read as a tap that opened the pie.
    Region {
      id: hitRegion
      readonly property bool wide: root.opened || root.holding || root.dragging
      // Switched off means nothing to press: an empty region, so every touch
      // falls through to whatever is underneath. The pie itself still opens
      // (via the bar icon, the keybind, or the editor) because `wide` wins.
      x: wide ? 0 : (root.dotOn ? Math.round(root.dotX - root.closedSize / 2) : -1)
      y: wide ? 0 : (root.dotOn ? Math.round(root.dotY - root.closedSize / 2) : -1)
      width: wide ? Math.max(1, panel.width) : (root.dotOn ? root.closedSize : 0)
      height: wide ? Math.max(1, panel.height) : (root.dotOn ? root.closedSize : 0)
    }

    Timer {
      id: actionDelay
      interval: 120
      onTriggered: {
        if (root.pendingSlice) root.runSlice(root.pendingSlice)
        root.pendingSlice = null
      }
    }

    // Repeat cadence for a held slice. Long enough that a stray press does not
    // jump the value, short enough that a ramp feels continuous.
    Timer {
      id: repeatTimer
      interval: 110
      repeat: true
      onTriggered: {
        if (!root.opened || !pieInput.pressRamps) { repeatTimer.stop(); return }
        var slice = root.displaySlices[pieInput.pressIndex]
        if (!slice || slice.repeat !== true) { repeatTimer.stop(); return }
        root.runSlice(slice)
      }
    }

    // ------------------------------------------------------------------- dot

    Item {
      id: dot
      // Hidden while editing (the hub is the Done control then) and when the
      // dot has been switched off from the bar.
      visible: root.mode === "use" && root.dotOn
      width: root.dotSize
      height: root.dotSize
      x: Math.round(root.dotX - width / 2)
      y: Math.round(root.dotY - height / 2)
      opacity: root.currentOpacity
      scale: root.hovering || root.dragArmed ? 1.12 : (root.failed ? 1.2 : 1)
      // Squash and stretch: a press squashes the coin, and the spring
      // Behaviors on squashX/squashY give it a bouncy return.
      transform: Scale {
        origin.x: dot.width / 2
        origin.y: dot.height / 2
        xScale: root.squashX
        yScale: root.squashY
      }

      Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Rectangle {
        id: dotBody
        anchors.fill: parent
        radius: width / 2
        // A failed action used to be indistinguishable from a successful one:
        // the pie closed and nothing happened, with nothing in the log. The
        // dot turning urgent-coloured is the only feedback available without
        // stealing focus for a toast.
        color: Util.alpha(root.failed ? Color.urgent : Color.accent, root.opened ? 0.55 : 0.28)
        border.width: 1
        border.color: Util.alpha(root.failed ? Color.urgent : Color.accent,
          root.failed ? 1 : (root.opened ? 0.9 : 0.45))
        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        Rectangle {
          anchors.centerIn: parent
          width: parent.width * 0.28
          height: width
          radius: width / 2
          color: Util.alpha(root.failed ? Color.urgent : Color.accent, 0.95)
        }
      }

      // Hold-to-arm ring. Fills while the press is held and stays full once
      // the dot will follow the finger, so the delay is never a surprise.
      Canvas {
        id: holdRing
        anchors.fill: parent
        visible: root.holding || root.holdProgress > 0.01

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var cx = width / 2
          var cy = height / 2
          var r = width / 2 + Style.space(4)
          ctx.beginPath()
          ctx.arc(cx, cy, r, 0, Math.PI * 2)
          ctx.lineWidth = Style.space(2)
          ctx.strokeStyle = Util.alpha(Color.foreground, 0.2)
          ctx.stroke()

          if (root.holdProgress > 0) {
            ctx.beginPath()
            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * root.holdProgress)
            ctx.lineWidth = Style.space(2)
            ctx.strokeStyle = root.dragArmed
              ? Util.alpha(Color.accent, 0.95)
              : Util.alpha(Color.foreground, 0.7)
            ctx.stroke()
          }
        }

        Connections {
          target: root
          function onHoldProgressChanged() { holdRing.requestPaint() }
          function onDragArmedChanged() { holdRing.requestPaint() }
          function onHoldingChanged() { holdRing.requestPaint() }
        }
        onVisibleChanged: if (visible) requestPaint()
      }

      MouseArea {
        id: dotInput
        anchors.fill: parent
        // The enlarged hit area is the whole point of a touch target; without
        // it the dot is a 48px coin you have to aim at.
        anchors.margins: -Style.space(12)
      preventStealing: true
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true

      // Where the press began, so a radial select is measured as finger travel
      // rather than distance from the dot centre (an off-centre press should
      // not trigger it on the first pixel of movement).
      property real downX: 0
      property real downY: 0

      onContainsMouseChanged: root.hovering = containsMouse

        onPressed: {
          root.moved = false
          root.dragArmed = false
          root.dragging = false
          root.holding = true
          root.holdStartedAt = Date.now()
          root.holdProgress = 0
          root.vX = 0
          root.vY = 0
          root.lastSampleT = 0
          root.radialSelecting = false
          dotInput.downX = dotInput.mouseX
          dotInput.downY = dotInput.mouseY
          if (root.config.physics) { root.squashX = 1.16; root.squashY = 0.86 }
          // Pressing the dot always collapses the pie, whether or not the hold
          // goes on to arm a drag. Deciding that here -- rather than letting a
          // press reach the position bindings at all -- is what keeps a press
          // from being able to move the dot: `dragging` stays false, so the
          // dot keeps reading its stored fractions and not a drag position.
          root.pressedWhileOpen = root.opened
          if (root.opened) root.dismiss()
          // Remember the finger's offset from the dot's centre so the drag
          // picks up exactly where the dot already was. Read from the
          // MouseArea's own mouseX/mouseY rather than the handler's event
          // argument, and map into screenSpace rather than `panel` -- passing
          // `panel` threw a C++ argument type error here, which aborted this
          // handler before holdTimer.restart() and left the dot undraggable.
          var start = dotInput.mapToItem(screenSpace, dotInput.mouseX, dotInput.mouseY)
          root.grabOffsetX = root.dotX - start.x
          root.grabOffsetY = root.dotY - start.y
          holdTimer.restart()
        }

        onPositionChanged: function (mouse) {
          if (root.radialSelecting) { root.updateRadialSelect(); return }
          // A quick outward drag before the hold arms is a radial select; the
          // hold is still what gates moving the dot, so the two never compete.
          if (!root.dragArmed && !root.opened && !root.pressedWhileOpen) {
            var mx = dotInput.mouseX - dotInput.downX
            var my = dotInput.mouseY - dotInput.downY
            if (Math.sqrt(mx * mx + my * my) > root.radialThreshold) {
              root.beginRadialSelect()
              return
            }
          }
          // Movement before the hold completes is ignored on purpose: the dot
          // must not chase a finger that was only aiming for a tap.
          root.sampleDrag()
        }

        onReleased: {
          holdTimer.stop()
          if (root.radialSelecting) { root.endRadialSelect(); return }
          var wasDrag = root.moved
          root.holding = false
          root.holdProgress = 0
          root.squashX = 1
          root.squashY = 1
          // A flick keeps `dragging` set and lets the glide finish the gesture;
          // its onFinished persists the spot and clears the state.
          if (wasDrag && root.config.physics && root.config.inertia && root.startInertia())
            return
          // Persist while `dragging` is still true: rememberPosition() reads
          // dotX, which only reflects the drag while dragging is set. Clearing
          // it first would snap the reading back to the old stored spot and
          // throw the move away.
          if (wasDrag) root.rememberPosition()
          root.dragging = false
          root.dragArmed = false
          root.moved = false
          if (wasDrag) return
          // A press that only collapsed the pie must not immediately reopen
          // it, or a tap on an open dot would flicker shut and back open.
          if (root.pressedWhileOpen) {
            root.pressedWhileOpen = false
            return
          }
          // A short tap, and a hold that armed but never travelled, both mean
          // "open the pie".
          root.toggle()
        }

        onCanceled: {
          holdTimer.stop()
          root.radialSelecting = false
          root.slicePressed = false
          root.dragging = false
          root.dragArmed = false
          root.holding = false
          root.holdProgress = 0
          root.squashX = 1
          root.squashY = 1
          root.moved = false
          root.pressedWhileOpen = false
        }
      }
    }
    // -------------------------------------------------------- command deck
    //
    // The always-active configuration surface while editing: a card docked to
    // the side opposite the dot, so it never covers the pie, with a Slices page
    // for building the ring and a Settings page for the live knobs. The pie
    // beside it is the WYSIWYG preview. This replaces the old floating
    // << + >> bar, which only ever did one of those jobs.
    Item {
      id: commandDeck
      visible: root.mode === "edit" || root.mode === "pick"
      z: 15
      width: Style.space(330)
      height: Math.min(panel.height - Style.space(40), Style.space(600))
      x: root.deckRight ? panel.width - width - Style.space(16) : Style.space(16)
      y: Math.round((panel.height - height) / 2)

      Rectangle {
        anchors.fill: parent
        radius: Style.space(14)
        color: Util.alpha(Color.background, 0.97)
        border.width: Math.max(1, Style.space(1))
        border.color: root.ringBorderColor

        Column {
          id: deckColumn
          anchors.fill: parent
          anchors.margins: Style.space(14)
          spacing: Style.space(10)

          Item {
            width: parent.width
            height: Style.space(38)

            Column {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              Text {
                text: "Command Deck"
                color: Color.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.title
              }
              Text {
                text: "DOT COMMANDER"
                color: Util.alpha(Color.foreground, 0.5)
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: [ { tab: "slices", label: "Slices" }, { tab: "settings", label: "Settings" } ]
              delegate: Rectangle {
                required property var modelData
                readonly property bool sel: root.deckTab === modelData.tab
                width: (deckColumn.width - Style.space(8)) / 2
                height: Style.space(30)
                radius: height / 2
                color: sel ? Util.alpha(Color.accent, 0.9) : Util.alpha(Color.foreground, 0.08)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(sel ? Color.accent : Color.foreground, 0.5)
                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: sel ? Color.background : Color.foreground
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                }
                MouseArea { anchors.fill: parent; onClicked: root.deckTab = modelData.tab }
              }
            }
          }

          Flickable {
            width: parent.width
            height: deckColumn.height - y - deckFooter.height - Style.space(10)
            contentWidth: width
            contentHeight: deckBody.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: deckBody
              width: parent.width
              spacing: Style.space(8)

              // ---------------------------------------------------- Slices
              Column {
                visible: root.deckTab === "slices"
                width: parent.width
                spacing: Style.space(6)

                // Rotate the whole ring, which is distinct from moving one
                // slice: the old floating bar's rotate buttons, reborn here.
                // An Item, not a Row: the label and buttons need left/right
                // anchors, which a Row forbids on its children.
                Item {
                  width: parent.width
                  height: Style.space(34)

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Rotate ring"
                    color: Util.alpha(Color.foreground, 0.8)
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)
                    DeckRowButton { glyph: Catalog.g(0xE5CB); onTapped: root.rotateDraft(-1) }
                    DeckRowButton { glyph: Catalog.g(0xE5CC); onTapped: root.rotateDraft(1) }
                  }
                }

                Repeater {
                  model: root.draftSlices.length

                  delegate: Rectangle {
                    id: deckRow
                    required property int index
                    readonly property var slice: root.draftSlices[index] || null
                    readonly property bool locked: root.isEditorSlice(deckRow.slice)
                    width: deckBody.width
                    height: Style.space(42)
                    radius: Style.space(8)
                    color: Util.alpha(Color.foreground, 0.06)

                    Item {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(24)
                      height: Style.space(24)

                      Image {
                        anchors.centerIn: parent
                        visible: !!(deckRow.slice && deckRow.slice.icon)
                        source: (deckRow.slice && deckRow.slice.icon) ? deckRow.slice.icon : ""
                        sourceSize.width: Style.space(18)
                        sourceSize.height: Style.space(18)
                        width: Style.space(18)
                        height: Style.space(18)
                        fillMode: Image.PreserveAspectFit
                      }
                      Text {
                        anchors.centerIn: parent
                        visible: !(deckRow.slice && deckRow.slice.icon)
                        text: deckRow.slice ? deckRow.slice.glyph : ""
                        color: Color.foreground
                        font.family: root.sliceFontFamily(deckRow.slice)
                        font.pixelSize: Style.space(18)
                        renderType: Text.NativeRendering
                      }
                    }

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(38)
                      anchors.right: rowButtons.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      text: deckRow.slice ? deckRow.slice.label : ""
                      color: Color.foreground
                      elide: Text.ElideRight
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Row {
                      id: rowButtons
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      DeckRowButton { glyph: Catalog.g(0xE5D8); dim: index === 0; onTapped: root.moveDraftSlice(index, -1) }
                      DeckRowButton { glyph: Catalog.g(0xE5DB); dim: index === root.draftSlices.length - 1; onTapped: root.moveDraftSlice(index, 1) }
                      DeckRowButton { glyph: Catalog.g(0xE5D5); dim: deckRow.locked; onTapped: root.openPickerFor(index) }
                      DeckRowButton { glyph: Catalog.g(0xE872); tint: Color.urgent; dim: deckRow.locked || root.draftSlices.length <= 3; onTapped: root.removeDraftSlice(index) }
                    }
                  }
                }

                Rectangle {
                  width: deckBody.width
                  height: Style.space(42)
                  radius: Style.space(8)
                  color: Util.alpha(Color.accent, 0.14)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(Color.accent, 0.6)
                  opacity: root.draftSlices.length >= 9 ? 0.4 : 1

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(6)
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: Catalog.g(0xE145)
                      color: Color.accent
                      font.family: root.iconFamily
                      font.pixelSize: Style.space(18)
                      renderType: Text.NativeRendering
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Add slice"
                      color: Color.accent
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: root.draftSlices.length < 9
                    onClicked: root.addSlice()
                  }
                }
              }

              // -------------------------------------------------- Settings
              Column {
                visible: root.deckTab === "settings"
                width: parent.width
                spacing: Style.space(8)

                DeckSection { text: "Motion" }
                DeckSwitch { text: "Physics"; value: root.config.physics; onToggled: root.toggleConfig("physics") }
                DeckSwitch { text: "Spring open"; value: root.config.springOpen; onToggled: root.toggleConfig("springOpen") }
                DeckSwitch { text: "Open wobble"; value: root.config.wobble; onToggled: root.toggleConfig("wobble") }
                DeckSwitch { text: "Flick inertia"; value: root.config.inertia; onToggled: root.toggleConfig("inertia") }

                DeckSection { text: "Appearance" }
                DeckSwitch { text: "Show labels"; value: root.config.showLabels; onToggled: root.toggleConfig("showLabels") }
                DeckSwitch { text: "Comfort inset"; value: root.config.comfort; onToggled: root.toggleConfig("comfort") }
                DeckSlider { text: "Dot size"; value: Number(root.config.dotSize); from: 28; to: 96; onMoved: function (v) { root.setConfig("dotSize", Math.round(v)) } }
                DeckSlider { text: "Pie radius"; value: Number(root.config.radius); from: 80; to: 220; onMoved: function (v) { root.setConfig("radius", Math.round(v)) } }
                DeckSlider { text: "Icon size"; value: Number(root.config.iconSize); from: 18; to: 48; onMoved: function (v) { root.setConfig("iconSize", Math.round(v)) } }
                DeckSlider { text: "Idle opacity"; value: Number(root.config.idleOpacity); from: 0.2; to: 1; decimals: 2; onMoved: function (v) { root.setConfig("idleOpacity", v) } }

                DeckSection { text: "Actions" }
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  DeckAction { text: "Recenter"; onTapped: root.recenter() }
                  DeckAction { text: "Reset all"; tint: Color.urgent; onTapped: root.resetConfig() }
                }
              }
            }
          }

          // Footer. Cancel on the left, Save (primary) on the right -- the way
          // a dialog footer reads.
          Row {
            id: deckFooter
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              width: (deckFooter.width - Style.space(8)) / 2
              height: Style.space(38)
              radius: Style.space(8)
              color: Util.alpha(Color.foreground, 0.12)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(Color.foreground, 0.5)
              Text {
                anchors.centerIn: parent
                text: "Cancel"
                color: Color.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; onClicked: root.cancelEdit() }
            }

            Rectangle {
              width: (deckFooter.width - Style.space(8)) / 2
              height: Style.space(38)
              radius: Style.space(8)
              color: Util.alpha(Color.accent, 0.9)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(Color.accent, 0.9)
              Text {
                anchors.centerIn: parent
                text: "Save"
                color: Color.background
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
              }
              MouseArea { anchors.fill: parent; onClicked: root.commitEdit() }
            }
          }
        }
      }
    }

    // The hub while editing is drawn by the pie chrome; saving and cancelling
    // live in the Command Deck header, not on the dot, so the dot stays the
    // preview's centre.

    // Transient notice, e.g. refusing to delete the Settings slice.
    Text {
      visible: root.editNotice !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.editBarBelow
        ? Math.max(Style.space(8), root.dotY - root.outerRadius - Style.space(52))
        : Math.min(panel.height - Style.space(52), root.dotY + root.outerRadius + Style.space(30))
      text: root.editNotice
      color: Color.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      z: 14
    }

    // Armed-discard hint. The first outside tap arms it, a second discards.
    Text {
      visible: root.confirmCancel
      anchors.horizontalCenter: parent.horizontalCenter
      y: root.editBarBelow
        ? Math.max(Style.space(8), root.dotY - root.outerRadius - Style.space(30))
        : Math.min(panel.height - Style.space(30), root.dotY + root.outerRadius + Style.space(8))
      text: "Tap outside again to discard changes"
      color: Color.urgent
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      z: 14
    }

    // ---------------------------------------------------------------- picker
    //
    // Docked to the Command Deck's inner side while adding or changing a slice,
    // so the whole config flow stays on one surface instead of a centred modal
    // with a full-screen scrim. Styled as the same card.
    Rectangle {
      id: picker
      visible: root.mode === "pick"
      z: 20
      width: Math.min(Style.space(460),
        Math.max(Style.space(300), panel.width - commandDeck.width - Style.space(48)))
      height: commandDeck.height
      y: commandDeck.y
      x: root.deckRight
        ? (commandDeck.x - width - Style.space(8))
        : (commandDeck.x + commandDeck.width + Style.space(8))
      radius: Style.space(14)
      color: Util.alpha(Color.background, 0.97)
      border.width: Math.max(1, Style.space(1))
      border.color: root.ringBorderColor

      Item {
        id: pickBody
        anchors.fill: parent
        anchors.margins: Style.space(14)

        Item {
          id: pickHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(34)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.pickIndex >= 0 ? "Change this slice" : "Add a slice"
            color: Color.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            // Trashcan. Only meaningful for an existing slice, and never below
            // the three-slice floor sanitizeSlices enforces.
            Rectangle {
              visible: root.pickIndex >= 0 && root.draftSlices.length > 3
              width: Style.space(34)
              height: width
              radius: width / 2
              color: Util.alpha(Color.urgent, 0.18)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(Color.urgent, 0.7)

              Text {
                anchors.centerIn: parent
                text: Catalog.g(0xE872)
                color: Color.urgent
                font.family: root.iconFamily
                font.pixelSize: Style.space(18)
                renderType: Text.NativeRendering
              }
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onClicked: root.deleteSlice()
              }
            }

            Rectangle {
              width: Style.space(34)
              height: width
              radius: width / 2
              color: Util.alpha(Color.foreground, 0.08)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(Color.foreground, 0.35)

              Text {
                anchors.centerIn: parent
                text: Catalog.g(0xE14C)
                color: Color.foreground
                font.family: root.iconFamily
                font.pixelSize: Style.space(18)
                renderType: Text.NativeRendering
              }
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onClicked: { root.mode = "edit"; root.pickIndex = -1 }
              }
            }
          }
        }

        Flow {
          id: pickRail
          anchors.top: pickHeader.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(6)

          Repeater {
            model: root.catalogCategories

            delegate: Rectangle {
              required property var modelData
              readonly property bool sel: root.pickCategory === modelData
              height: Style.space(30)
              width: railLabel.width + Style.space(20)
              radius: height / 2
              color: sel ? Util.alpha(Color.accent, 0.85) : Util.alpha(Color.foreground, 0.07)
              border.width: Math.max(1, Style.space(1))
              border.color: sel ? Util.alpha(Color.accent, 1.0) : Util.alpha(Color.foreground, 0.25)

              Text {
                id: railLabel
                anchors.centerIn: parent
                text: modelData
                color: sel ? Color.background : root.labelColor
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onClicked: {
                  root.pickCategory = modelData
                  root.pickQuery = ""
                  pickSearch.text = ""
                }
              }
            }
          }
        }

        TextField {
          id: pickSearch
          anchors.top: pickRail.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          placeholderText: "Search " + root.pickCategory
          font.pixelSize: Style.font.body
          onTextChanged: root.pickQuery = text
        }

        // Sections rather than a flat grid: the menu catalog is 300+ routes
        // across 42 parents and the app list is 60 entries, and a single
        // undifferentiated wall of tiles is unreadable at that size.
        ListView {
          id: tileList
          anchors.top: pickSearch.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          clip: true
          spacing: Style.space(12)
          model: root.pickSections

          delegate: Column {
            id: section
            required property var modelData          // { title, entries }

            // Columns derived from the width so the last tile in a row is flush
            // with the right edge. A fixed cell width left up to a whole column
            // of dead space.
            readonly property int cols: Math.max(2, Math.round(width / Style.space(104)))
            readonly property real tileW: (width - spacing * (cols - 1)) / cols

            width: tileList.width
            spacing: Style.space(6)

            Text {
              text: section.modelData.title
              color: root.labelColor
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
            }

            Flow {
              width: section.width
              spacing: section.spacing

              Repeater {
                model: section.modelData.entries

                delegate: Item {
                  id: tileItem
                  required property var modelData
                  readonly property bool avail: root.entryAvailable(modelData)
                  width: section.tileW
                  height: Style.space(98)

                  Rectangle {
                    id: tile
                    anchors.fill: parent
                    opacity: tileItem.avail ? 1 : 0.4
                    anchors.margins: Style.space(3)
                    radius: Style.space(10)
                    color: tileMouse.containsMouse
                      ? Util.alpha(Color.accent, 0.28) : Util.alpha(Color.foreground, 0.06)
                    border.width: Math.max(1, Style.space(1))
                    border.color: tileMouse.containsMouse
                      ? Util.alpha(Color.accent, 0.9) : Util.alpha(Color.foreground, 0.18)

                    Column {
                      anchors.centerIn: parent
                      width: parent.width - Style.space(10)
                      spacing: Style.space(4)

                      // The glyph draws underneath and the image on top, so an
                      // icon that is missing or fails to load degrades to the
                      // glyph instead of leaving a blank square.
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !tileIcon.visible
                        text: modelData.glyph
                        color: Color.foreground
                        font.family: modelData.font === "menu" ? Style.font.menuFamily : root.iconFamily
                        font.pixelSize: Style.space(22)
                        renderType: Text.NativeRendering
                      }

                      Image {
                        id: tileIcon
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !!modelData.icon && tileIcon.status !== Image.Error
                        source: modelData.icon || ""
                        sourceSize.width: Style.space(24)
                        sourceSize.height: Style.space(24)
                        width: Style.space(24)
                        height: Style.space(24)
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                      }

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        text: modelData.label
                        color: root.labelColor
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.caption
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                      }

                      // Shown only when the entry cannot run, so the reason is
                      // visible rather than the tile just refusing.
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !tileItem.avail
                        width: parent.width
                        text: root.availabilityReason(modelData)
                          + (root.fixFor(modelData) ? "  - tap to fix" : "")
                        color: root.fixFor(modelData) ? root.labelActiveColor : Color.urgent
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.caption
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                      }
                    }
                  }

                  MouseArea {
                    id: tileMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    // Still tappable when unavailable, so the tap can say why.
                    onClicked: {
                      if (tileItem.avail) root.chooseEntry(modelData)
                      else if (root.fixFor(modelData)) root.runFix(modelData)
                      else root.notify(modelData.label + ": " + root.availabilityReason(modelData))
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------- state

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: {}
    onFileChanged: reload()
  }

  // One handler only: QML keeps the last Component.onCompleted and warns
  // "Property value set multiple times" for the rest, so a second one here
  // would silently drop the geometry seeding below.
  Component.onCompleted: {
    stateFile.reload()
    menuFile.reload()
    root.refreshCapabilities()
    root.syncScreen()
    // The window has no size on the first frame, so the position is seeded
    // once the layer has actually been mapped.
    geometryWatch.running = true
  }

  // Re-measures until the cached bounds match the live surface, then stops.
  // It re-arms from invalidateGeometry() on a screen switch or resize, so
  // stopping here is safe -- the previous version also stopped, but nothing
  // could ever restart it, which left the dot clamped to the first monitor's
  // dimensions forever.
  Timer {
    id: geometryWatch
    interval: 200
    repeat: true
    onTriggered: {
      root.syncScreen()
      root.captureGeometry()
      if (root.haveGeometry
          && Math.abs(root.screenW - panel.width) < 1
          && Math.abs(root.screenH - panel.height) < 1)
        geometryWatch.running = false
    }
  }

  Timer {
    id: noticeTimer
    interval: 2400
    onTriggered: root.editNotice = ""
  }

  Timer {
    id: confirmTimer
    interval: 3000
    onTriggered: root.confirmCancel = false
  }

  // First-run salute. applyState() calls maybeGreet() once the state file
  // lands; this covers a fresh install, where there is no dot.json yet.
  Timer {
    interval: 2500
    running: true
    onTriggered: root.maybeGreet()
  }

  // Omarchy's menu definition, read once and mapped to tiles. Read rather than
  // hardcoded so the Menu category stays in sync with the installed Omarchy.
  FileView {
    id: menuFile
    path: "/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: root.menuCatalog = Catalog.menuEntries(text())
    onLoadFailed: root.menuCatalog = []
    onFileChanged: reload()
  }

  // --------------------------------------------------- Command Deck controls
  //
  // Small self-contained controls for the panel above. They only depend on the
  // theme singletons and emit signals, so they stay usable from anywhere in the
  // file without reaching back into root.

  component DeckRound: Rectangle {
    id: round
    property string glyph: ""
    property color tint: Color.foreground
    signal tapped()
    width: Style.space(34)
    height: width
    radius: width / 2
    color: Util.alpha(tint, 0.16)
    border.width: Math.max(1, Style.space(1))
    border.color: Util.alpha(tint, 0.7)
    Text {
      anchors.centerIn: parent
      text: round.glyph
      color: round.tint
      font.family: "Material Symbols Rounded"
      font.pixelSize: Style.space(18)
      renderType: Text.NativeRendering
    }
    MouseArea { anchors.fill: parent; onClicked: round.tapped() }
  }

  component DeckRowButton: Rectangle {
    id: rb
    property string glyph: ""
    property color tint: Color.foreground
    property bool dim: false
    signal tapped()
    width: Style.space(26)
    height: width
    radius: Style.space(6)
    color: Util.alpha(tint, dim ? 0.04 : 0.12)
    opacity: dim ? 0.4 : 1
    Text {
      anchors.centerIn: parent
      text: rb.glyph
      color: rb.tint
      font.family: "Material Symbols Rounded"
      font.pixelSize: Style.space(15)
      renderType: Text.NativeRendering
    }
    MouseArea { anchors.fill: parent; enabled: !rb.dim; onClicked: rb.tapped() }
  }

  component DeckSection: Item {
    id: sec
    property string text: ""
    width: parent ? parent.width : 0
    height: Style.space(26)
    Text {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      text: sec.text.toUpperCase()
      color: Util.alpha(Color.foreground, 0.5)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
  }

  component DeckSwitch: Item {
    id: sw
    property string text: ""
    property bool value: false
    signal toggled()
    width: parent ? parent.width : Style.space(280)
    height: Style.space(30)
    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: sw.text
      color: Color.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
    }
    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(40)
      height: Style.space(22)
      radius: height / 2
      color: sw.value ? Util.alpha(Color.accent, 0.9) : Util.alpha(Color.foreground, 0.16)
      border.width: Math.max(1, Style.space(1))
      border.color: Util.alpha(sw.value ? Color.accent : Color.foreground, 0.6)
      Rectangle {
        width: parent.height - Style.space(4)
        height: width
        radius: width / 2
        y: Style.space(2)
        x: sw.value ? parent.width - width - Style.space(2) : Style.space(2)
        color: Color.background
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
      MouseArea { anchors.fill: parent; onClicked: sw.toggled() }
    }
  }

  component DeckSlider: Item {
    id: sl
    property string text: ""
    property real value: 0
    property real from: 0
    property real to: 1
    property int decimals: 0
    signal moved(real v)
    width: parent ? parent.width : Style.space(280)
    height: Style.space(36)

    function update(mx) {
      var t = Math.max(0, Math.min(1, mx / track.width))
      sl.moved(sl.from + t * (sl.to - sl.from))
    }

    Text {
      anchors.left: parent.left
      anchors.top: parent.top
      text: sl.text
      color: Color.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      anchors.right: parent.right
      anchors.top: parent.top
      text: sl.value.toFixed(sl.decimals)
      color: Util.alpha(Color.foreground, 0.7)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
    }
    Rectangle {
      id: track
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(4)
      radius: height / 2
      color: Util.alpha(Color.foreground, 0.18)

      readonly property real frac: Math.max(0, Math.min(1,
        (sl.value - sl.from) / Math.max(0.0001, sl.to - sl.from)))

      Rectangle {
        width: parent.width * track.frac
        height: parent.height
        radius: parent.radius
        color: Util.alpha(Color.accent, 0.9)
      }
      Rectangle {
        width: Style.space(14)
        height: width
        radius: width / 2
        y: (track.height - height) / 2
        x: Math.max(0, Math.min(track.width - width, track.width * track.frac - width / 2))
        color: Color.foreground
        border.width: 1
        border.color: Color.background
      }
      MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(26)
        onPressed: function (m) { sl.update(m.x) }
        onPositionChanged: function (m) { if (pressed) sl.update(m.x) }
      }
    }
  }

  component DeckAction: Rectangle {
    id: act
    property string text: ""
    property color tint: Color.accent
    signal tapped()
    width: Style.space(145)
    height: Style.space(34)
    radius: Style.space(8)
    color: Util.alpha(tint, 0.14)
    border.width: Math.max(1, Style.space(1))
    border.color: Util.alpha(tint, 0.6)
    Text {
      anchors.centerIn: parent
      text: act.text
      color: act.tint
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
    }
    MouseArea { anchors.fill: parent; onClicked: act.tapped() }
  }

}
