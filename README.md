# Tako 🐙

Tako is a fast, lightweight, GPU-accelerated terminal for macOS, and a remote-only SSH terminal client for iOS. The shared terminal engine is implemented in Rust and rendered with Metal, but the macOS app runs local shells on-device while the iOS app connects to a remote host over SSH.

[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](https://apple.com/macos)
[![iOS 17+](https://img.shields.io/badge/iOS-17.0%2B-green.svg)](https://apple.com/ios)
[![Rust](https://img.shields.io/badge/Rust-1.88%2B-orange.svg)](https://rust-lang.org)
[![Metal](https://img.shields.io/badge/Renderer-Metal-purple.svg)](https://developer.apple.com/metal/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Highlights

- **Pure-Rust Engine (`tako_core`)**:
  - Full VT100, xterm, and modern terminal sequence support.
  - Kitty Keyboard Protocol (progressive enhancements, disambiguation, event queries).
  - Kitty Graphics Protocol images: RGB, RGBA and PNG over direct transmission. Query replies
    are not implemented yet, so `kitten icat` does not detect the support.
  - Asynchronous PTY execution with non-blocking multi-threaded pipeline.
  - Embedded SSH client support (`features = ["ssh"]`).
  - Shell command records from OSC 133 marks: each search hit says which command printed
    it, with its command line, working directory, exit code and start time. Only rows a
    single command wrote are attributed; a row holding a prompt and output, or two
    commands' output, belongs to none. A finished command without an exit code is not
    reported as a success.

- **Hardware-Accelerated Metal Renderer (`TakoCoreUI`)**:
  - GPU rendering with Metal vertex and fragment shaders (`TerminalShaders.metal`).
  - Sub-cell smooth scrolling at 60/120 Hz synchronized with `CADisplayLink`.
  - Row-level damage tracking (`memcmp` over packed cells), so an idle or
    mostly static screen does no redundant GPU work.
  - CoreText font shaping with fallback to system fonts and Nerd Font symbols.

- **Getting back to work**:
  - Each tab's screen and scrollback come back after a relaunch, marked with when they were saved;
    the new shell is never presented as the old one.
  - Find in All Tabs (<kbd>Cmd</kbd> + <kbd>Shift</kbd> + <kbd>F</kbd>) searches every open
    terminal's history and jumps to the match. Where the shell marks its commands (shell
    integration), matches are grouped under the command that printed them, with the exit status
    and directory the shell reported, and the start time Tako recorded.
  - A long command that finishes or fails while you are elsewhere marks its tab and can send a
    notification.
  - Experimental: `session-persistence = true` keeps each shell running across a quit and
    reattaches it on the next launch (not the Quick Terminal). Output from before the relaunch is
    searchable but not grouped by command.

- **Native macOS Experience**:
  - Native tabs, split panes (horizontal & vertical), Quick Terminal dropdown.
  - Scriptable from the command line: `takoctl` drives tabs, splits, input and output over a local socket.
  - Window transparency and customizable titlebar styling.

- **Cross-Platform Swift Component**:
  - Shared view layer: `TakoTerminalNSView` for macOS (AppKit) and `TakoTerminalView` for iOS (UIKit).
  - The iOS surface is a remote terminal view used with SSH; it does not run a local shell on device.

---

## Platform Notes

### macOS

Tako is a full local terminal on macOS. It runs shells and terminal jobs on-device, integrates with macOS input and windowing behavior, and uses a PTY-backed execution model.

### iOS

Tako on iOS is not a standalone local terminal environment. The iOS app is designed around SSH sessions to a remote host because iOS does not allow the local shell execution model used by the macOS app. If you are expecting an iPhone or iPad app that runs a local shell on-device, that is not what this project provides.

The iOS surface is a terminal client for remote access.

---

## Quick Start: Building the macOS App

### Prerequisites

- macOS 14.0 or later on Apple Silicon
- [Rust toolchain](https://rustup.rs) (`rustup default stable`)
- Xcode 15+ and Command Line Tools (`xcode-select --install`)
- Python 3.10+

### Build & Run

```bash
# 1. Clone the repository
git clone https://github.com/alex09x/tako.git
cd tako

# 2. Build the macOS application bundle (target/macapp/Tako.app)
python3 scripts/build-macapp.py

# 3. Run automated headless verification (keys, shell input, smooth scroll)
./scripts/selftest-macapp.sh

# 4. Install to /Applications/Tako.app
./scripts/install-macapp.sh
```

You can now launch Tako from Spotlight, Launchpad, or the terminal:
```bash
open -a Tako
```

---

## Automated Self-Tests

Tako ships with an end-to-end integration test runner that exercises real macOS events, PTY streams, and Metal presentation callbacks:

```bash
# Run the macOS app self-test suite
./scripts/selftest-macapp.sh
```

```text
== keys: an NSEvent must produce the bytes it stands for ==
a          chars=a -> 61 (a)
shift+a    chars=A -> 41 (A)
ctrl+c     chars=  -> 03 ( )
ctrl+c cyr chars=с -> 03 ( )

== input: typing must reach the real shell and come back on screen ==
expected the last line to contain: hello world (space test)
╰ ❯ hello world

== scroll: a precise delta must move the grid by a fraction of a row ==
ok    after 1 of 3 points up             presented=0.3333 expected=0.3333
ok    after 2 of 3 points up             presented=0.6667 expected=0.6667
ok    after 3 of 3 points up             presented=1.0000 expected=1.0000

frames submitted=12 presented=10
macapp self-test: ok
```

To run the Rust engine test suite:
```bash
cargo test
```

The Swift suites need the engine built locally first:
```bash
./scripts/build-xcframework.sh
./scripts/swift-test.sh
```

---

## Configuration

Tako reads its configuration from `~/.config/tako/config`.

Press <kbd>Cmd</kbd> + <kbd>,</kbd> inside Tako to automatically create and open this file in your default editor.

### Example `~/.config/tako/config`

```ini
# Theme & Appearance
theme = TokyoNight
font-family = JetBrains Mono
font-size = 13.5
background-opacity = 0.95
background-blur-radius = 20

# Window layout
window-padding-x = 8
window-padding-y = 8
macos-titlebar-style = transparent

# Getting back to work: restore screen and scrollback after a relaunch,
# keeping at most 64 MB for all tabs together
window-save-content = true
window-save-content-limit = 64
# When a command of 10 s or more ends while its tab is not focused, mark the tab,
# ring the bell and send a system notification (never, unfocused or always)
notify-on-command-finish = unfocused
notify-on-command-finish-after = 10s
notify-on-command-finish-action = bell,notify
# Experimental: keep shells running across a quit and reattach them
session-persistence = false

# Keybindings
keybind = super+t=new_tab
keybind = super+d=new_split:right
keybind = super+shift+d=new_split:down
keybind = super+w=close_surface
```

---

## Swift Package Integration

Tako can be embedded in any macOS or iOS application as a Swift Package:

```swift
import TakoCoreUI

// Create terminal surface
let terminal = TakoTerminalNSView(frame: view.bounds)
terminal.delegate = self
view.addSubview(terminal)

// Send data received from PTY or SSH
terminal.feed(data: incomingBytes)
```

Implement `TakoTerminalNSViewDelegate` to forward user input and resize events back to your backend transport.

Runnable samples for macOS, iOS and the C ABI, what the host is responsible for, limits and
compatibility, and the versioning policy: [docs/takocore.md](docs/takocore.md).

---

## Architecture

For an in-depth breakdown of the internal layers, UniFFI bridging, PTY pipeline, and GPU rendering architecture, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## License & Attribution

Tako is licensed under the [MIT License](LICENSE).

- The bundled JetBrains Mono Nerd Font is under the SIL Open Font License 1.1 ([`swift/Resources/fonts/OFL.txt`](swift/Resources/fonts/OFL.txt)).
- Reference test fixtures adapted from [Alacritty](https://github.com/alacritty/alacritty) (Apache 2.0 License, © The Alacritty Project).
- Full third-party notices and licenses are documented in [NOTICE.md](NOTICE.md).

---

## Citation

If you use Tako in your research or project, please cite the software archive using the metadata below or via [CITATION.cff](CITATION.cff):

```bibtex
@software{panasenko_2026_23028534,
  author       = {Panasenko, Alexander},
  title        = {Tako: GPU-accelerated terminal for macOS and iOS},
  month        = sep,
  year         = 2026,
  publisher    = {Zenodo},
  version      = {0.1.2},
  doi          = {10.5281/zenodo.23028534},
  url          = {https://zenodo.org/records/23028534}
}
```
