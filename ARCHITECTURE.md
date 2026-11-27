# Architecture

Tako is a terminal for macOS and iOS: two apps over a Rust VT engine and a
Swift view layer that draws it with Metal. The engine, the view layer and the
session runtime are [tako-core](https://github.com/alex09x/tako-core)'s; this
repository holds the apps and builds them against one exact tako-core release.

```
 macOS app (swift/Sources/TakoApp)          iOS app (swift/Sources/iOSApp)
 windows, tabs, splits, quick terminal,     session list, SSH forms,
 takoctl control socket, sessions           key row, host-key prompts
        |                                          |
 Tako.* adapter (_TakoShim) + TakoKit               |
        |                                          |
        +------------------+-----------------------+
                           |
   tako-core (pinned in swift/Package.swift)
          TakoCoreUI: TakoTerminalNSView / TakoTerminalView, Metal
          renderer, CoreText fallback, glyph atlas, sub-cell scrolling
                           |
          TakoCore.xcframework: the Rust engine (parser, terminal,
          grid/scrollback, input encoding, Kitty graphics, SSH)

 session runtime: tako-session from a tako-core release, bundled at
 Contents/Helpers/zmx (pinned in packaging/session-runtime.json)
```

## The engine and its views (tako-core)

`TakoTerminalNSView` (AppKit) and `TakoTerminalView` (UIKit) own the engine,
feed it bytes from the host's transport, and present frames. The host keeps
ownership of its PTY or socket and receives encoded input and resize events
through the view's delegate. How they work, and their tests, are in tako-core.

Tako takes them from one exact release: `swift/Package.swift` names the
version, `swift/Package.resolved` records its commit, and SwiftPM checks the
xcframework's checksum. `scripts/tako_core.py` resolves that release once and
hands its checkout (TakoCoreUI's sources and Metal shader) and framework (the
engine's static library and headers per platform) to the app builders.

## macOS app (`swift/Sources/TakoApp`)

The app layer talks to the terminal through the `Tako.*` namespace in
`_TakoShim`, backed by `TakoCoreUI`; `TakoKit` provides the C-style API the
app layer was written against. `TakoObjC` contains the Objective-C helpers
used by the native window layer. Current user-facing features are described
in [README.md](README.md).

The app is built by `scripts/build-macapp.py` with `swiftc` directly: it
compiles TakoCoreUI from the pinned release as its own module, then the app
against it, and links the release's engine library. `swift/Package.swift`
exists to run the test suites.

The direct build has two important constraints: its Swift module name must
match `customModule="Tako"` in the XIBs, and the app layer needs its bridging
header for the Foundation and Objective-C helper declarations. Keep those in
sync when changing the module or link order.

Sessions that outlive the app run in the session runtime, tako-session as
tako-core released it. `scripts/session_runtime.py` downloads it and checks it
against the hashes in `packaging/session-runtime.json`; the app bundles it at
the path the session protocol names, `Contents/Helpers/zmx`, and checks its
signed hash before it runs one.

## iOS app (`swift/Sources/iOSApp`)

A SwiftUI app over `TakoTerminalView` that connects over SSH through the
engine's SSH transport. Built with XcodeGen from `ios/project.yml`, which
takes TakoCoreUI from the same tako-core release as a Swift package.

## Tests

For development, use `scripts/check.sh` with explicit targets, for example
`scripts/check.sh swift:ThemePresetStoreTests e2e:theme-typography`.
Swift filters are regular expressions; combine alternatives with `|`.
E2E scenario names are comma-separated and persistence scenarios are routed
to their isolated runner. [scripts/README.md](scripts/README.md) maps the
build, test, release and manual diagnostic entry points.

- Swift: `scripts/swift-test.sh` (XCTest and Swift Testing) against the
  pinned tako-core release; `scripts/swift-coverage-gate.py` for per-file
  coverage of this repository's sources.
- `takoctl`: `mitts test --manifest-path takoctl/Cargo.toml`.
- Apps: `scripts/selftest-macapp.sh` drives the real macOS app;
  `scripts/e2e-macapp.sh` and `scripts/e2e-persist.sh` run its end-to-end
  and session-persistence scenarios; `scripts/simtest.py` runs iOS scenarios
  and an XCUITest walkthrough in the simulator against local SSH servers, and
  `scripts/ios-coverage-gate.py` reads the iOS app's coverage from that
  walkthrough; `macos_uitests/` holds the macOS XCUITest suite.
- `scripts/ci.sh` runs all of the above on a separate test Mac through
  `scripts/mac-remote.sh`, holding the covered Swift directories to 80% line
  coverage. This is the test gate; the GitHub Actions workflow packages macOS
  releases separately.
