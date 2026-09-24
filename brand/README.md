# Brand

The design system for this port: a pixel-crab mark, the Ember/Rust palette,
JetBrains Mono for anything monospaced and Space Grotesk for headings.

| Token | Hex | Used for |
|---|---|---|
| Ember | `#F4581C` | the mark's body, the active-tab bar, accents |
| Claw | `#FF7A3D` | the mark's claws, hover states |
| Rust | `#C23E0E` | the mark on light backgrounds |
| Ink | `#1A1512` | the macOS icon plate, dark chrome |
| Paper | `#FAF7F2` | light chrome, the mark on the iOS plate |

`takocore-mark.svg` is the mark. It is nothing but rounded rectangles, so
`make-icons.swift` draws it directly instead of pulling in an SVG renderer:

```
swiftc -O -o /tmp/make-icons brand/make-icons.swift && /tmp/make-icons
```

That writes `brand/out/{macos,ios}/icon_*.png`. At 32pt and below the two
oranges stop being distinguishable, so those sizes collapse to a single
colour, as the brand sheet calls for. `brand/out/TakoCore.icns` is what
the macOS build bundles.

## The prompt

`swift/Resources/shell-integration/` carries the two-line prompt from the
design system:

```
╭ tako git:(main*) ~2 ?2 · 3.0s · ✗ 1
╰ ❯
```

The duration and the status glyph appear only past two seconds, so `ls` and
`cd` leave the prompt clean; a fast failure still shows its code, because a
silent failure is worse than a noisy one. The arrow carries the exit state
when nothing else does.

fish gets it automatically — the file sits in the `vendor_conf.d` the app
puts on `XDG_DATA_DIRS`. zsh has to source it, since upstream's integration
hands control back to the user's own `.zshrc`:

```sh
source "$TAKO_RESOURCES_DIR/shell-integration/zsh/tako-prompt.zsh"
```

`TAKO_PROMPT=0` keeps your own prompt.

## iOS

`swift/Sources/iOSApp` is the phone shell: a session list and a session
screen, with the key row a phone keyboard lacks. Below the UI it is the
same Rust engine and the same CoreText renderer the Mac runs — that layer
carries no AppKit and no UIKit, which is what makes it portable at all.
Upstream's macOS app contributes nothing here: it is AppKit from top to
bottom, and its own iOS target is fifty lines.

```
python3 scripts/build-iosapp.py
xcrun simctl install <device> target/iosapp/TakoCore.app
xcrun simctl launch <device> com.tako-core.ios
```

Pass `--open-demo` to land straight in a session.

iOS forbids fork/exec, so a session here is remote, connecting via
the engine's built-in SSH client transport.

## The palette

The design's terminal is warm, not blue. The engine carries these as its
own defaults, so a host that never sends OSC 10/11 — the iOS app, an
embedder — still gets the product's look:

| role | hex |
|---|---|
| terminal body | `#14100E` |
| chrome, tabs | `#1A1512` |
| main text | `#EDE6DF` |
| secondary text, `╭ ╰ git:( )` | `#8A7F76` |
| directory in the prompt | `#FF7A3D` |
| branch | `#B294BB` |
| `+staged` `~modified` `−deleted` `⇡ahead` | `#7BD88F` `#F0C674` `#D54E53` `#8ABEB7` |
| the arrow, the cursor | `#F4581C` |

The ANSI palette is Tomorrow Night, which the engine already carried for
upstream parity and which the design's own colours come from.

`swift/Resources/themes/TakoCore` is the same palette as a theme file.
The palette is this app's identity. To pick another one, set `theme` in
`~/.config/tako/config`.

## Performance

`cargo bench --bench throughput` measures the engine alone. On an M-series
Mac, feeding 256 KB into an 80×24 terminal:

| workload | throughput |
|---|---:|
| plain text | 11 MiB/s |
| SGR-heavy (build logs, `ls --color`) | 29 MiB/s |
| cursor-heavy (a TUI repainting) | 8 MiB/s |
| wide characters and emoji | 17 MiB/s |

Reflowing an 80-column screen to 40 costs 227 µs.

The engine was never the bottleneck, though. Handing a frame to the
renderer was: a full screen of cells crossing the FFI as records cost about
seven microseconds per cell, which is 74 ms for a 200×50 viewport — twelve
frames a second before a single glyph was drawn. `viewport_packed` returns
the frame as one buffer of 16-byte records instead:

| per frame, 200×50 | before | after |
|---|---:|---:|
| grid transfer | 74.4 ms | 0.48 ms |

End to end, `cat` of a 20 MB file went from over 75 seconds to 0.11 s.

## Key encoding

Upstream's 90 key-encoding tests are ported verbatim into
`tests/parity_key_{legacy,kitty,ctrlseq}.rs`. A test we do not satisfy
is `#[ignore]`d with a factual reason rather than adjusted, so the gap is
visible instead of hidden.

Three bugs came straight out of that exercise, all of them things a user
hits daily:

- **Shift typed nothing.** fish turns on the Kitty keyboard protocol, and
  under its "disambiguate" flag a key whose purpose is text still sends
  that text -- only a modifier other than shift makes it an escape code. We
  escaped everything, so shifted keys arrived as a description of a
  keypress and fish discarded them.
- **`ctrl+c` did nothing on a Cyrillic layout.** That key types U+0441 and
  its unmodified form is U+0441 too, so nothing in the event said it was
  the `c` key. Events now carry the *physical* key -- the ASCII a US layout
  would type -- which upstream calls the logical key.
- **`ctrl+space` sent a space**, because space was never mapped as a key at
  all. Neither were Insert, F5-F12 or the keypad.

Reproducing a keyboard bug from outside the process needs Accessibility
permission a local build does not have, so the app tests itself:

```
open target/macapp/Tako.app --args --selftest-keys    # bytes per key
open target/macapp/Tako.app --args --selftest-input   # types into the shell, reads the screen back
```

The first writes `/tmp/tako-keytest.txt`, the second
`/tmp/tako-inputtest.txt`. Both were what finally found these; reading
the code had produced two wrong answers first.
