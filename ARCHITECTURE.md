# Architecture

Tako is a terminal for macOS and iOS: a Rust VT engine, a Swift view layer
that draws it with Metal, and two apps on top.

```
 macOS app (swift/Sources/TakoApp)          iOS app (swift/Sources/iOSApp)
 windows, tabs, splits, quick terminal,     session list, SSH forms,
 AppleScript                                 key row, host-key prompts
        |                                          |
 Tako.* adapter (_TakoShim) + TakoKit               |
        |                                          |
        +------------------+-----------------------+
                           |
          TakoCoreUI (swift/Sources/TakoCoreUI)
          TakoTerminalNSView / TakoTerminalView, Metal renderer,
          CoreText fallback, glyph atlas, sub-cell scrolling
                           |
                 UniFFI (TakoCore class)
                           |
               tako_core (Rust, src/)
          parser -> terminal -> grid/scrollback
          optional: pty (feature "pty"), SSH (feature "ssh", russh)
```

## Rust engine (`src/`)

| Module | Role |
|---|---|
| `parser` | VT escape-sequence state machine (ESC, CSI, OSC, DCS, APC) |
| `terminal` | The emulator: modes, cursor, margins, tabs, charsets, OSC handling, reports; `checkpoint.rs` serializes and restores full state |
| `grid` | Cells, the active screen and the scrollback |
| `key_encode`, `mouse_encode`, `kitty_keyboard`, `paste` | Input encoding (legacy, modifyOtherKeys, kitty keyboard protocol, bracketed paste) |
| `graphics` | Kitty graphics protocol |
| `ffi` | The UniFFI surface Swift uses: the `TakoCore` object and packed frame snapshots for the renderer |
| `capi` | A C ABI (`prod_vt_*`) for a Go host that links the engine directly |
| `pty` | POSIX pty spawning, behind the `pty` feature |
| `ssh` | An SSH client transport on russh, behind the `ssh` feature, so iOS can reach a shell without fork/exec |

`tests/parity_*` pin the engine's behaviour against an upstream terminal's
test suite, one test per upstream case. It is safe Rust except for the C ABI in
`capi.rs`, which necessarily works with raw pointers.

## Swift view layer (`swift/Sources/TakoCoreUI`)

`TakoTerminalNSView` (AppKit) and `TakoTerminalView` (UIKit) own a
`TakoCore`, feed it bytes from the host's transport, and present frames.
The host keeps ownership of its PTY or socket and receives encoded input and
resize events through the view's delegate.

Rendering takes a packed snapshot of the visible cells from the engine,
skips rows whose packed bytes did not change, and draws glyph quads and
backgrounds with vertex and fragment shaders (`TerminalShaders.metal`) from a
CoreText-rasterized glyph atlas. `TerminalRenderer` is a CoreText fallback.
Scrolling is presented at sub-row precision and frame pacing follows the
display link.

## macOS app (`swift/Sources/TakoApp`)

The app layer talks to the terminal through the `Tako.*` namespace in
`_TakoShim`, backed by `TakoCoreUI` and the Rust engine; `TakoKit` provides
the C-style API the app layer was written against. See
`macos_port/README.md` for what is wired and what is not.

The app is built by `scripts/build-macapp.py` with `swiftc` directly;
`swift/Package.swift` exists to run the test suites.

## iOS app (`swift/Sources/iOSApp`)

A SwiftUI app over `TakoTerminalView` that connects over SSH through the
engine's `ssh` feature. Built with XcodeGen from `ios/project.yml`.

## Distribution

`TakoCore.xcframework` carries the engine for macOS and iOS (device and
simulator) plus the generated Swift bindings. It is build output, not
committed: `scripts/build-xcframework.sh` builds it locally, and
`scripts/package-xcframework.sh` zips it for a GitHub release and points the
root `Package.swift`, which exposes `TakoCoreUI` to consumers, at that asset.

## Tests

- Rust: `cargo test` (engine, parity ports, C ABI, checkpoint), with
  `--features pty` / `ssh` for those modules; `scripts/coverage-gate.py`
  holds every engine file to a line-coverage floor.
- Swift: `scripts/swift-test.sh` (XCTest and Swift Testing), rebuilding
  the engine first when its sources changed; `scripts/swift-coverage-gate.py`
  for per-file coverage; `scripts/test-ios-surface.sh` runs TakoCoreUI's
  tests on the iOS simulator.
- Apps: `scripts/selftest-macapp.sh` drives the real macOS app;
  `scripts/simtest.py` runs iOS scenarios and an XCUITest walkthrough in the
  simulator against local SSH servers, and `scripts/ios-coverage-gate.py`
  reads the iOS app's coverage from that walkthrough; `macos_uitests/` holds
  the macOS XCUITest suite.
- `scripts/ci.sh` runs all of the above on a separate test Mac through
  `scripts/mac-remote.sh`, holding every engine file and the covered Swift
  directories to 80% line coverage; there is no hosted CI.
