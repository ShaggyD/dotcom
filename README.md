# Dot Com

A draggable on-screen dot that opens a radial menu of window, system, keyboard
and app actions, built for touch-first tablets on [Omarchy](https://omarchy.org).

The stock Omarchy tablet experience buries the handful of actions you actually
reach for behind small bar icons and hotkeys that assume a physical keyboard.
Dot Com puts them under your thumb: one always-available dot you can park
anywhere, and a pie that fans out on tap.

**Dot Com** is short for **Dot Commander** — the full title, which the invoice
truncated. The pie is your command wheel; the editor is the Command Deck.

![The Dot Com pie open over the desktop](preview.png)

## What it does

- **Tap the dot** to open the pie; **tap a slice** to run it; **tap away or press
  Esc** to dismiss.
- **Press and hold, then drag** to move the dot anywhere on screen. It stores its
  position as screen fractions, so it lands in the same relative spot on any
  display.
- **Build your own pie** in a WYSIWYG editor: add, remove and drag-reorder slices
  from the Window, System, Keyboard, Menu, Apps and Plugins catalogs.
- **A bar icon** (Touch pie) shows or hides the dot without opening the editor.
- **Theme-aware** — colours and label contrast come from the active Omarchy theme,
  and the dot fades to a configurable idle opacity until you touch it.
- **No dead taps** — a slice whose command or plugin is missing draws dimmed, with
  the reason, instead of failing when you press it.

## Requirements

- Omarchy Quattro (shell plugin support) on Hyprland with the Lua config.
- No root, no network, no background daemon. Everything runs inside the shell
  process you already have.

Individual slices may want extra tools (an on-screen-keyboard backend such as
`wvkbd` or `squeekboard`, or `texp-rotate`). Those slices dim when the tool is
absent, so the plugin works without them.

## Install

```sh
omarchy plugin add https://github.com/ShaggyD/dotcom.git --enable
```

Or by hand: copy this folder to
`~/.config/omarchy/plugins/io.github.shaggyd.dotcom/`, then

```sh
omarchy plugin enable io.github.shaggyd.dotcom
```

The dot appears at 72 % across and down from the top-left. Tap it.

### Bar placement

The bar icon installs in the **right** section by default. Move it anywhere the
shell's bar widgets go:

```sh
omarchy bar move io.github.shaggyd.dotcom --section left    # or center, right
```

### Optional keybinding

A keyboard is not required, but if the dot is ever parked under a fullscreen app,
a key is the way back in. Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + PERIOD",       "Touch pie menu",  "omarchy-shell shell toggle io.github.shaggyd.dotcom '{}'")
o.bind("SUPER + SHIFT + PERIOD", "Edit touch pie", "omarchy-shell shell call io.github.shaggyd.dotcom enterEdit '{}'")
```

## Using it

| Gesture | Action |
|---|---|
| Tap the dot | Open or close the pie |
| Tap a slice | Run it (hold a `+`/`-` slice to ramp: brightness, volume) |
| Press and hold, then drag | Move the dot; release to place it |
| Tap elsewhere, or `Esc` | Dismiss |

The default pie has five slices: **Fullscreen**, **Float**, **Keyboard**,
**Apps** and **Settings**. The Settings slice is the only way into the editor
from the pie, so it cannot be removed.

### The Command Deck

Open **Settings** (`pie.edit`) to edit the pie in place — every slice is drawn
exactly as it will be saved. The footer reads **Dot Commander · Command Deck**:
the editor is where you command the pie.

- The **`<<` `+` `>>`** bar below the ring adds a slice from the tile sheet.
  Pick a category (Window, System, Keyboard, Menu, Apps, Plugins) and a tile.
  Menu and Apps are built from your live Omarchy install, so they stay in sync.
- **Drag a slice** to reorder it around the ring.
- **Remove** a slice from its slot; the hub (**Done**) saves, or discard to
  cancel.
- Tiles that need a binary, backend or plugin you do not have draw dimmed.

![Editing the pie in place](preview-editor.png)

![Adding a slice from the tile sheet](preview-picker.png)

Changes are written to `dot.json` (below).

## Configure

State lives in `~/.local/state/omarchy/dot.json`. The editor writes it; you can
also edit it by hand, and the shell reloads it on save.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Show the dot (the bar icon toggles this) |
| `greeted` | `false` | Set after the one-time "reporting for duty" salute |
| `dotSize` | `48` | Dot diameter, px |
| `iconSize` | `30` | Glyph size inside the dot, px |
| `radius` | `132` | Pie radius from the dot centre, px |
| `idleOpacity` | `0.5` | Dot opacity when idle |
| `holdMs` | `600` | Hold time before a press becomes a drag |
| `showLabels` | `true` | Draw slice labels |
| `comfort` | `true` | Keep the whole pie on screen when the dot is near an edge |
| `fx`, `fy` | `0.72` | Position as screen fractions (set by dragging) |
| `slices` | `null` | Your pie; `null` uses the five default slices |

A stored slice references the catalog by `key`, so catalog fixes propagate to it
automatically. A slice can also be a raw entry carrying `label`, `glyph`, and one
of `hypr` (a Hyprland dispatch), `argv` (an argument vector), `app` (launched via
the shell's app library) or `plugin` (handled inside Dot Com), plus `repeat` for
ramping slices.

### Catalog keys

Built-in slices reference these keys (see [`Catalog.js`](Catalog.js)).

| Section | Keys |
|---|---|
| Window | `hypr.window.close`, `hypr.window.fullscreen`, `hypr.window.float`, `hypr.window.pin`, `hypr.window.center`, `hypr.window.kill` |
| System | `sys.apps`, `sys.screenshot`, `sys.record`, `sys.lock`, `sys.rotate`, `sys.nightlight`, `sys.brightup`, `sys.brightdown`, `sys.volup`, `sys.voldown`, `sys.theme`, `sys.setup`, `sys.commander` |
| Keyboard | `sys.keyboard` (auto), `kb.wvkbd_desktop`, `kb.wvkbd_mobile`, `kb.squeekboard`, `sys.keyboard_omarchy` |
| Pie | `pie.recenter`, `pie.edit`, `pie.reset` |
| Menu | every labelled route from Omarchy's menu, as `menu.<route>` |
| Apps | installed desktop applications |

### IPC

```sh
omarchy-shell shell toggle io.github.shaggyd.dotcom '{}'            # open / close the pie
omarchy-shell shell call io.github.shaggyd.dotcom toggleDot '{}'    # show / hide the dot
omarchy-shell shell call io.github.shaggyd.dotcom enterEdit '{}'    # open the editor
omarchy-shell shell call io.github.shaggyd.dotcom recenter '{}'     # put the dot back
omarchy-shell shell call io.github.shaggyd.dotcom commander '{}'    # Dot Commander, reporting for duty
omarchy-shell shell call io.github.shaggyd.dotcom debugGeometry     # diagnostics
```

`commander` is the easter egg: it returns the long name with a random salute and
shows it as a notification. There is also a pickable **Commander** tile in the
System catalog, so the bridge can be addressed from the pie itself.

## Remove

```sh
omarchy plugin remove io.github.shaggyd.dotcom
```

That disables the plugin and deletes its folder. Then remove any keybinding you
added, and optionally delete `~/.local/state/omarchy/dot.json`.

## Notes

- Everything runs in the Omarchy shell under your user. Nothing is backgrounded,
  nothing runs as root, and nothing talks to the network.
- Slices execute Omarchy's own CLI (`omarchy ...`), Hyprland dispatchers
  (`hl.dsp.*`), or the on-screen-keyboard wrappers. Commands are argv vectors run
  with `exec "$@"`, so no value is ever re-parsed by a shell.

## Development

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" Dot.qml BarIcon.qml
omarchy-shell shell rescanPlugins
```

Saving any file under the plugin folder hot-reloads it. If a change to the
overlay does not take effect, `omarchy restart shell` reloads it; the keep-loaded
overlay is not always picked up by `omarchy-shell shell rescanPlugins`.

## License

Apache-2.0.
