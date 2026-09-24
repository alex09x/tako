# The macOS port

`swift/Sources/TakoApp` is the macOS application layer, together with its
interface files: MainMenu.xib, the window styles, About, QuickTerminal,
ClipboardConfirmation, ConfigurationErrors and the asset catalog. It keeps the
structure of the upstream app it was derived from; the auto-updater and App
Intents were removed.

What was replaced is upstream's Zig core library. That is the piece that
made a phone build impossible.

```
upstream:   Features/ + App/ + Helpers/  ->  namespace  ->  Zig core
ours:       Features/ + App/ + Helpers/  ->  Tako.*     ->  TakoKit + TakoCore (Rust)
```

`Tako.*` is not a runtime bridge. It is plain Swift compiled into the same
binary, in the same layering upstream uses -- the app talks to `Tako.App`,
`Tako.Config` and `Tako.SurfaceView`, and only what sits underneath changed.
`TakoKit` is a pure-Swift stand-in for the C API upstream imports.

## Layout

| Directory | What it is |
|---|---|
| `swift/Sources/TakoApp` | Upstream's app layer, renamed, with dead code removed and fixes of its own |
| `swift/Sources/TakoApp/_TakoShim` | The `Tako.*` adapter over the Rust core |
| `swift/Sources/TakoKit` | The C API the app layer calls, in Swift: config storage and parsing, and stubs for what has no counterpart here |
| `swift/Sources/TakoObjC` | The two Objective-C pieces upstream calls into |
| `swift/Sources/TakoCoreUI` | The terminal view (Metal, with a CoreText fallback) and the theme parser |

## Build and run

```
python3 scripts/build-macapp.py       # -> target/macapp/Tako.app
open target/macapp/Tako.app
```

The app links the Rust staticlib, the Objective-C helpers and all of
upstream's Swift into a single binary. Nothing loads at runtime that is
not in the bundle.

Two constraints the build has to respect, both learned the hard way:

- The Swift module name must match `customModule` in the xibs (`Tako`).
  MainMenu.xib resolves the app delegate through it; with a mismatch
  NSApplication gets no delegate, and therefore no window.
- Several of upstream's files have no `import Foundation` because their
  Xcode target uses an Objective-C bridging header. We keep the same
  header, which is what lets their files stay close to upstream.

## Verified

A window opens with a live `zsh` on the Rust engine: the shell's own
startup output, its prompt, and the theme resolved from the user's
config. Keyboard input is wired (`SurfaceView.keyDown` ->
`core.encodeKey` -> PTY) but has not been exercised by an automated test,
because macOS refuses synthetic keystrokes without Accessibility
permission.

## Not ported, deliberately

Auto-update. Upstream's updater needs Sparkle, an appcast feed and a
signing identity to check it against; a build from this repo has none, so
the update UI and its stub were removed rather than shipped doing nothing.

App Intents. Shortcuts only discovers intents from the metadata Xcode
extracts at build time, and this app is built with plain `swiftc`, so they
were never registered and were removed.

## Actions

Upstream sends menu items, keybindings, the command palette and AppleScript
`perform action` to its C surface. There is none here, so every action is
either carried out by `Tako.SurfaceView` (see
`_TakoShim/Tako+SurfaceActions.swift`) or refused: its menu item is disabled
and `performBindingAction` -- and so AppleScript -- reports failure.

| Action | State |
|---|---|
| `increase_font_size:N`, `decrease_font_size:N`, `reset_font_size` | Implemented. Per surface, relative to the configured size; the grid refits. |
| `reset` (Reset Terminal) | Implemented. `TakoCore.reset`, which keeps the theme's colors. |
| `start_search`, `search:TEXT`, `search_selection`, `navigate_search:next/previous`, `end_search`, `scroll_to_selection` | Implemented. Case-insensitive over scrollback and screen; a match is selected and scrolled to; next goes to older output and wraps. A match does not span a soft wrap. |
| `clear_screen`, `copy_to_clipboard`, `paste_from_clipboard`, `paste_from_selection`, `select_all` | Implemented. `clear_screen` clears the screen; scrollback is kept, since the engine has no scrollback erase. `paste_from_selection` pastes what `copy-on-select` last copied. |
| `scroll_to_top`, `scroll_to_bottom`, `scroll_page_up`, `scroll_page_down`, `scroll_page_lines:N` | Implemented. |
| `text:`, `csi:`, `esc:` | Implemented, with `\n \r \t \e \\ \xHH` escapes. |
| Window and app actions: `new_window`, `new_tab`, `close_surface`, `close_tab`, `close_window`, `close_all_windows`, `new_split:*`, `goto_split:*`, `resize_split:<dir>,10`, `equalize_splits`, `toggle_split_zoom`, `toggle_fullscreen`, `toggle_command_palette`, `reset_window_size`, `prompt_tab_title`, `open_config`, `reload_config`, `toggle_quick_terminal`, `toggle_visibility`, `toggle_secure_input`, `undo`, `redo` | Sent to the window's controller or the app delegate, as the menu does; false when neither implements it. |
| `inspector:*` (Terminal Inspector) | Unavailable: there is no inspector. Menu item disabled. |
| `toggle_readonly` | Unavailable: input is not gated. Menu item has no target and is disabled. |
| `resize_split` with an amount other than 10, `toggle_tab_overview`, `toggle_window_decorations`, `show_gtk_inspector`, anything else | Unavailable: `performBindingAction` returns false. |

## Keybindings

`keybind` lines set menu item shortcuts, which also label the tabs and the
command palette; the menu is what makes them fire. The trigger syntax is
upstream's: `super`/`cmd`, `ctrl`, `alt`/`opt` and `shift`, then a character
or a key name (`grave_accent`, `enter`, `arrow_up`, `page_down`, `f1`,
`key_k`, `digit_3`, ...). A trigger belongs to one action, so binding it
takes it from the action that had it; `...=unbind` frees it and
`keybind = clear` frees them all.

A line is skipped, and the action keeps its default, when the trigger has
an unknown key or modifier or is a leader sequence (`ctrl+a>n`), which no
menu item can carry. A binding for an action without a menu item does
nothing.

There are no global keybinds. The `all:`, `global:`, `unconsumed:` and
`performable:` prefixes are accepted and ignored, so a `global:` binding
works only while Tako is the active app: `tako_app_has_global_keybinds`
reports none, and the event tap in `Features/Global Keybinds` is never
installed.

## Configuration

The config is read from `~/Library/Application Support/com.tako-core.terminal/config`,
`~/.config/tako-core/config` and `~/.config/tako/config`, a later file
overriding an earlier one, or from the one file `TAKO_CONFIG_PATH` names.
Key names and syntax are upstream's. Reload Configuration applies the file
to the open windows and terminals: theme, font, colors and the terminal
keys below.

Keys whose meaning differs here:

- `scrollback-limit` is upstream's byte budget; Tako keeps one line of
  history per 1,000 bytes of it, so the default 10 MB is 10,000 lines. The
  limit survives a reset, RIS included.
- `copy-on-select` (default `true`) copies a finished selection to a
  pasteboard of the app's own, which `paste_from_selection` (Cmd+Shift+V)
  reads; `clipboard` copies it to the general clipboard as well.
- `cursor-style = block_hollow` draws a block: the cursor is already drawn
  hollow while its terminal is not focused.
- `adjust-cell-width`, `adjust-cell-height`, `adjust-font-baseline`,
  `adjust-underline-position` and `adjust-underline-thickness` work in
  points, and a percentage rounds to whole points.
- `font-feature`: the GPU renderer draws a cell at a time, so features that
  join cells (ligatures, contextual alternates) show only in the CPU
  fallback; per-glyph ones (`ss01`, `zero`, `cv01`) show everywhere.
  `font-style = false` is ignored for the regular face.
- `window-padding-x`, `window-padding-y` (one value or `leading,trailing`),
  `window-padding-balance` and `window-padding-color` apply to the macOS
  app's windows; the iOS view draws edge to edge.
- `macos-icon = custom-style` draws Tako's own crab: `macos-icon-ghost-color`
  colours the crab, `macos-icon-screen-color` the plate behind it and
  `macos-icon-frame` the rim.
- `custom-shader` files are Shadertoy-style GLSL translated to Metal when
  they load. Shaders that use GLSL outside what the translation covers
  (types, the usual built-ins, `out`/`inout`, the Shadertoy and cursor
  uniforms, `iChannel0` only) fail to load; as upstream does, one failure
  disables them all and the reason is logged.
- `grapheme-width-method = legacy` sizes a cluster by its codepoints, but
  zero-width codepoints still join the cell before them. A cell keeps at
  most 256 bytes of extra codepoints.
- `mouse-shift-capture` honours a program's XTSHIFTESCAPE request under
  `false` and `true`, and ignores it under `always` and `never`.

Accepted but not acted on -- they raise no error, so an upstream config
loads unchanged:

- `auto-update`, `auto-update-channel`: the app has no updater.
