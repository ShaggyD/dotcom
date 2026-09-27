.pragma library

// Catalog for the touch-pie picker.
//
// Glyphs are built with String.fromCharCode rather than \uXXXX escapes or raw
// Private Use Area bytes: both of those have been silently corrupted by tooling
// during this project, and fromCharCode cannot be. Every codepoint here was
// checked against MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf's cmap, and
// every Hyprland dispatcher was checked to exist with a side-effect-free
// `type(hl.dsp.window.x) == "function"` eval.

function g(cp) {
  return String.fromCharCode(cp)
}

// Action kinds a catalog entry (and therefore a saved slice) can carry:
//   hypr   - a Lua snippet, wrapped in hl.dispatch() at run time
//   argv   - an argument vector, run without shell re-tokenisation
//   app    - launched through the shell's AppLibrary
//   plugin - handled inside Dot.qml (recenter, reset, edit)

// ---------------------------------------------------------------- Window

var WINDOW = [
  { key: "hypr.window.close",      label: "Close",      glyph: g(0xE14C), section: "Window",
    hypr: 'hl.dsp.window.close()' },
  { key: "hypr.window.fullscreen", label: "Fullscreen", glyph: g(0xE5D0), section: "Window",
    hypr: 'hl.dsp.window.fullscreen({ mode = "fullscreen" })' },
  { key: "hypr.window.float",      label: "Float",      glyph: g(0xE911), section: "Window",
    hypr: 'hl.dsp.window.float({ action = "toggle" })' },
  { key: "hypr.window.pin",        label: "Pin",        glyph: g(0xE840), section: "Window",
    hypr: 'hl.dsp.window.pin()' },
  { key: "hypr.window.center",     label: "Center",     glyph: g(0xE3B4), section: "Window",
    hypr: 'hl.dsp.window.center()' },
  { key: "hypr.window.kill",       label: "Kill",       glyph: g(0xE872), section: "Window",
    hypr: 'hl.dsp.window.kill()' }
]

// ---------------------------------------------------------------- System
//
// Hand-curated because the menu catalog has these buried among 300+ routes.
// Overlap with the Menu category is deliberate: these are the frequent ones.
// `section` groups them in the picker.

var SYSTEM = [
  { key: "sys.apps",       label: "Launcher",   glyph: g(0xE8B9), section: "Launch",
    argv: ["omarchy", "menu", "toggle"] },
  { key: "sys.terminal",   label: "Terminal",   glyph: g(0xEB8E), section: "Launch",
    argv: ["omarchy-launch-terminal"] },
  { key: "sys.screenshot", label: "Screenshot", glyph: g(0xE412), section: "Capture",
    argv: ["omarchy", "capture", "screenshot", "fullscreen", "copy"] },
  { key: "sys.record",     label: "Record",     glyph: g(0xE04B), section: "Capture",
    argv: ["omarchy", "capture", "screenrecording", "--fullscreen"] },
  { key: "sys.lock",       label: "Lock",       glyph: g(0xE897), section: "Power",
    argv: ["omarchy", "system", "lock"] },
  { key: "sys.power",      label: "Power",      glyph: g(0xF8C7), section: "Power",
    argv: ["omarchy", "menu", "toggle", "system"] },
  { key: "sys.rotate",     label: "Rotate",     glyph: g(0xE1C1), section: "Display",
    argv: ["texp-rotate", "next"] },
  { key: "sys.nightlight", label: "Night light", glyph: g(0xE8B4), section: "Display",
    argv: ["omarchy", "toggle", "nightlight"] },
  { key: "sys.brightup",   label: "Bright +",   glyph: g(0xE1AB), section: "Display",
    argv: ["omarchy", "brightness", "display", "+10%"], repeat: true },
  { key: "sys.brightdown", label: "Bright -",   glyph: g(0xE335), section: "Display",
    argv: ["omarchy", "brightness", "display", "-10%"], repeat: true },
  { key: "sys.volup",      label: "Volume +",   glyph: g(0xE050), section: "Sound",
    argv: ["omarchy", "audio", "output", "volume", "+5"], repeat: true },
  { key: "sys.voldown",    label: "Volume -",   glyph: g(0xE04F), section: "Sound",
    argv: ["omarchy", "audio", "output", "volume", "-5"], repeat: true },
  { key: "sys.theme",      label: "Theme",      glyph: g(0xE3E9), section: "Appearance",
    argv: ["omarchy", "menu", "toggle", "style.theme"] },
  { key: "sys.setup",      label: "Setup",      glyph: g(0xE8B8), section: "System",
    argv: ["omarchy", "menu", "toggle", "settings"] },
  // The Commander easter egg: a pickable tile that has the bridge answer the
  // salute.
  { key: "sys.commander",  label: "Commander",  glyph: g(0xEA3F), section: "System",
    plugin: "commander" }
]


// ---------------------------------------------------------------- Keyboard
//
// Every keyboard this machine might have, as its own entry, so they can be
// found as a group instead of being hidden behind one adaptive choice -- on a
// tablet with no physical keyboard this is the most important slice there is.
// Each declares what it needs, so an uninstalled one dims with the reason
// rather than being a dead tap.
//
// Note the raw entries are deliberately less clever than texp-vk: they do not
// theme the keyboard or track visibility. They exist so a specific backend can
// be pinned to a slice; "Keyboard (auto)" remains the better default.
var KEYBOARDS = [
  // `chain` is tried in order and the first installed step wins, so this keeps
  // working if the wrapper or a backend disappears. texp-vk is first because it
  // starts the keyboard on demand and already falls back to squeekboard itself.
  // Chain steps declare an explicit `requires`, because a step wrapped in a
  // shell would otherwise look available merely because the shell is.
  { key: "sys.keyboard", label: "Keyboard (auto)", glyph: g(0xE312), section: "Keyboard",
    chain: [
      { argv: ["texp-vk", "toggle"] },
      { requires: "wvkbd-deskintl",
        argv: ["bash", "-lc", 'pgrep -x wvkbd-deskintl >/dev/null && pkill -RTMIN -x wvkbd-deskintl || exec "$HOME/.local/bin/texp-wvkbd"'] },
      { requires: "wvkbd-mobintl",
        argv: ["bash", "-lc", 'pgrep -x wvkbd-mobintl >/dev/null && pkill -RTMIN -x wvkbd-mobintl || exec wvkbd-mobintl --hidden -H 300 -L 220 -l "full,special"'] }
    ] },
  // Desktop-size wvkbd. This is the same command as the SUPER+SHIFT+K binding.
  { key: "kb.wvkbd_desktop", label: "wvkbd desktop", glyph: g(0xE312), section: "Keyboard",
    requires: "wvkbd-deskintl",
    argv: ["bash", "-lc", 'pgrep -x wvkbd-deskintl >/dev/null && pkill -RTMIN -x wvkbd-deskintl || exec "$HOME/.local/bin/texp-wvkbd"'] },
  { key: "kb.wvkbd_mobile", label: "wvkbd mobile", glyph: g(0xE312), section: "Keyboard",
    requires: "wvkbd-mobintl",
    argv: ["bash", "-lc", 'pgrep -x wvkbd-mobintl >/dev/null && pkill -RTMIN -x wvkbd-mobintl || exec wvkbd-mobintl --hidden -H 300 -L 220 -l "full,special"'] },
  // squeekboard needs starting before it will answer on D-Bus, and a real
  // toggle would need its visibility state -- which only texp-vk tracks, and
  // that file is shared across backends, so it is not a trustworthy source
  // here. Hence "show" rather than "toggle".
  { key: "kb.squeekboard", label: "squeekboard (show)", glyph: g(0xE312), section: "Keyboard",
    requires: "squeekboard",
    argv: ["bash", "-lc", 'pgrep -x squeekboard >/dev/null || (nohup squeekboard >/dev/null 2>&1 & sleep 1); busctl --user call sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b true'] },
  // Omarchy's own on-screen keyboard, if its plugin is ever enabled. Disabled
  // by default, so this dims with the reason until then.
  { key: "sys.keyboard_omarchy", label: "Keyboard (Omarchy)", glyph: g(0xE312), section: "Keyboard",
    requiresPlugin: "io.github.mtolhuys.onscreen-keyboard",
    argv: ["omarchy-shell", "onscreen-keyboard", "toggle"] }
]

// ---------------------------------------------------------------- Pie

var PIE = [
  { key: "pie.recenter", label: "Recenter", glyph: g(0xE55C), section: "Pie", plugin: "recenter" },
  { key: "pie.edit",     label: "Settings", glyph: g(0xE8B8), section: "Pie", plugin: "edit" },
  { key: "pie.reset",    label: "Reset all", glyph: g(0xE042), section: "Pie", plugin: "reset" }
]

// ---------------------------------------------------------------- JSONC

// Omarchy's menu file is JSONC: `//` comments (including inside URL strings),
// block comments, and trailing commas. A naive comment strip would corrupt
// 'https://omarchy.org/...', so the scanner tracks string and escape state.
function parseJsonc(text) {
  var src = String(text || "")
  var out = ""
  var inStr = false, esc = false, line = false, block = false
  for (var i = 0; i < src.length; i++) {
    var c = src.charAt(i), n = src.charAt(i + 1)
    if (line) { if (c === "\n") { line = false; out += c } continue }
    if (block) { if (c === "*" && n === "/") { block = false; i++ } continue }
    if (inStr) {
      out += c
      if (esc) esc = false
      else if (c === "\\") esc = true
      else if (c === '"') inStr = false
      continue
    }
    if (c === '"') { inStr = true; out += c; continue }
    if (c === "/" && n === "/") { line = true; i++; continue }
    if (c === "/" && n === "*") { block = true; i++; continue }
    out += c
  }
  out = out.replace(/,(\s*[}\]])/g, "$1")
  try { return JSON.parse(out) } catch (e) { return null }
}

// Every labelled route in the menu becomes a pickable tile. The action routes
// through `omarchy menu toggle <route>` rather than running the file's raw
// `action` string, so nothing here evaluates a shell command line: submenus
// open, leaf actions run, and it stays in sync with Omarchy automatically.
//
// Icons in that file are Nerd Font glyphs, not Material Symbols, so entries
// carry font:"menu" and the picker draws them with Style.font.menuFamily.
function menuEntries(text) {
  var obj = parseJsonc(text)
  if (!obj || typeof obj !== "object") return []

  // Parent route -> its label, so a section header reads "System" rather than
  // the raw "system" id.
  var labels = {}
  for (var r in obj) {
    var d = obj[r]
    if (d && typeof d === "object" && typeof d.label === "string") labels[r] = d.label
  }

  var out = []
  for (var k in obj) {
    var e = obj[k]
    if (!e || typeof e !== "object" || Array.isArray(e)) continue
    var label = (typeof e.label === "string" && e.label.length > 0) ? e.label : k
    // Dotted ids imply hierarchy, so the section is the immediate parent.
    var parts = String(k).split(".")
    var parent = parts.length > 1 ? parts.slice(0, parts.length - 1).join(".") : ""
    out.push({
      key: "menu." + k,
      label: String(label),
      glyph: String(e.icon || ""),
      font: "menu",
      group: "Menu",
      section: parent === "" ? "Root" : String(labels[parent] || parent),
      argv: ["omarchy", "menu", "toggle", String(k)]
    })
  }
  // Deliberately NOT sorted: the menu file's order is the menu's own order, and
  // with sections the natural grouping reads better than an alphabetical jumble
  // that scatters one section across the list.
  return out
}

// ---------------------------------------------------------------- colour
//
// WCAG relative luminance / contrast, so the label role can be checked against
// the theme instead of assumed. Inputs are 0..1 channel values, which is what
// QML's color.r/g/b give.

function channel(c) {
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

function contrastRGB(r1, g1, b1, r2, g2, b2) {
  var l1 = 0.2126 * channel(r1) + 0.7152 * channel(g1) + 0.0722 * channel(b1)
  var l2 = 0.2126 * channel(r2) + 0.7152 * channel(g2) + 0.0722 * channel(b2)
  var hi = Math.max(l1, l2), lo = Math.min(l1, l2)
  return (hi + 0.05) / (lo + 0.05)
}

// Raise the alpha of `fg` over `bg` until the composite clears `minRatio`, or
// give up at 1.0. This is the contrast guard: a theme whose secondary role is
// too dim can never leave labels unreadable.
function alphaForContrast(fg, bg, startAlpha, minRatio) {
  var a = startAlpha
  while (a < 1.0) {
    var r = fg.r * a + bg.r * (1 - a)
    var g = fg.g * a + bg.g * (1 - a)
    var b = fg.b * a + bg.b * (1 - a)
    if (contrastRGB(r, g, b, bg.r, bg.g, bg.b) >= minRatio) return a
    a += 0.04
  }
  return 1.0
}
