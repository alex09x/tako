# Embedding TakoCore

TakoCore is the terminal engine behind Tako.app: a parser and screen model in
Rust, with a Metal view for macOS and iOS on top. The engine never starts a
process or opens a connection; what runs on the other side of the terminal --
a local shell, an SSH session, a program in your app -- is the host's.

There are three ways in:

| You write | Use | Start from |
|---|---|---|
| A macOS or iOS app | the `TakoCoreUI` Swift package (`TakoTerminalNSView`, `TakoTerminalView`) | [`examples/macos-sample`](../examples/macos-sample), [`examples/ios-sample`](../examples/ios-sample) |
| Anything that links C | the static library and `include/prod_vt.h`, `include/prod_vt_checkpoint.h` | [`examples/c`](../examples/c) |
| Rust | the `tako-core` crate | [`examples/headless.rs`](../examples/headless.rs) |

## The samples

**macOS** -- a window with your login shell in it, about 120 lines. The host
opens a pseudo-terminal (`forkpty`), feeds what the shell writes to the view,
and writes what the view produces (keys, paste, mouse, replies to the
program's queries) back to the shell.

    cd examples/macos-sample && swift run

**iOS** -- iOS runs no local shells, so the program on the other side is a few
lines of Swift that echo a line back. Replace it with your SSH session.

    cd examples/ios-sample && xcodegen -s project.yml && open TakoSample.xcodeproj

**C, no window** -- feeds escape sequences, answers the terminal's queries,
prints the screen, saves the whole terminal to a checkpoint and restores it
into a second one.

    examples/c/build.sh && examples/c/headless

The Swift samples depend on this repository's root package, which pins the
engine to the last release. To try them against engine changes not yet
released, build the engine (`scripts/build-xcframework.sh`) and set
`TAKO_LOCAL_XCFRAMEWORK=1` when building.

## What the host does

- **Bytes in:** everything the program writes goes to `feed` (`prod_vt_write`
  in C), in order.
- **Bytes out:** keys and paste come from the view's delegate; replies to the
  program's queries (cursor position, device attributes) come from
  `sendDeviceReplyData` (`prod_vt_drain_responses`). Both go to the program's
  input.
- **Size:** tell the program the new size when the view reports one (on a
  pty, `TIOCSWINSZ`).
- **Events:** title, bell, clipboard requests (OSC 52), working directory
  (OSC 7) and command start and end (OSC 133) arrive as delegate calls or
  events. A host that ignores them in C calls `prod_vt_discard_events` so
  they do not pile up. Writing to the system clipboard on a program's request
  is a policy decision the engine leaves to the host.
- **Threads:** one terminal is used from one thread at a time. The Swift
  views do this for you; in C it is your lock.

## Limits and compatibility

**Platforms.** The Swift package: macOS 14 and iOS 17 or later, Apple
silicon (arm64 slices only; exclude x86_64 for the simulator). The Rust crate
builds on macOS and Linux with Rust 1.88 or later. Prebuilt engines are
published for macOS arm64, iOS and the iOS simulator.

**Terminal.** VT100/xterm sequences, 256 colours and 24-bit colour,
alternate screen, scroll regions and left/right margins, mouse reporting
(X10, UTF-8, SGR), bracketed paste, focus events, OSC 8 hyperlinks, OSC 52
clipboard, OSC 7 and OSC 133 shell integration, the Kitty keyboard protocol
and Kitty graphics (RGB, RGBA and PNG by direct transmission). Grapheme
clusters (emoji sequences, combining marks) take their presentation width.
The terminal reports itself as `xterm-256color`; XTVERSION answers `tako`.

Not supported: Sixel, Kitty graphics query replies (so `kitten icat` does not
detect support), ReGIS, Tektronix, and anything that needs a font or a
renderer from the engine (it has neither).

**Sizes.**

| | Limit |
|---|---|
| Grid width or height in a checkpoint | 10,000 cells |
| Scrollback in a checkpoint | 1,000,000 lines |
| Checkpoint container | 64 MiB |
| Memory a checkpoint import may allocate | 512 MiB |
| Extra text in one grapheme cluster | 256 bytes |
| Shell command records kept (OSC 133) | 10,000, 2 MB of text |
| Command line kept per command | 512 characters |
| Search step | the rows and matches the caller asks for |

A checkpoint the engine writes is always one it can read back: export refuses
a state whose import would exceed these limits instead of writing it.

**Checkpoints.** A checkpoint holds the whole terminal -- screen, history,
cursor, modes, in-flight parser state, colours and shell command records --
in a versioned, checksummed container. This build writes version 4 and reads
1 to 4; it can also write 2 or 3 for a peer that reads no newer
(`prod_vt_checkpoint_supports`, `export3`). A newer container than the reader
knows fails as an unsupported version, never as corruption.

## Versioning

TakoCore follows semantic versioning from 1.0. Until then (0.x):

- A **patch** release (0.1.x) does not remove or change the meaning of
  anything public in the Swift package, the C headers or the crate. It may
  add.
- A **minor** release (0.x.0) may change public API. Every change is listed
  in the release notes with what to do instead.
- **The C ABI is additive.** An exported C function keeps its signature and
  meaning; a different behaviour gets a new name (`*2`, `*3`), and the old
  one stays. `prod_vt_checkpoint_abi_version()` says which checkpoint surface
  a library has.
- **Checkpoints are compatible across versions.** A new container version is
  added only alongside the ability to read every older one and to write the
  previous one, so two sides can always agree on a version.
- **The Swift bindings and the engine are released together.** The Swift
  package pins the engine build it was generated against; mixing a package
  revision with another revision's engine is not supported.
- Behaviour that only fixes a deviation from xterm or the relevant spec is a
  fix, not a change, and can ship in a patch release.
