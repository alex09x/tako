/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::Terminal;

/// Upstream test: "OSC 4 set and reset palette"
#[test]
fn osc_4_set_and_reset_palette() {
    let mut term = Terminal::new(10, 10);
    let default_color_0 = term.palette().get(0);

    term.feed(b"\x1b]4;0;rgb:ff/00/00\x1b\\");
    assert_eq!(term.palette().get(0), (0xff, 0x00, 0x00));

    term.feed(b"\x1b]104;0\x1b\\");
    assert_eq!(term.palette().get(0), default_color_0);
}

/// Upstream test: "OSC 104 reset all palette colors"
#[test]
fn osc_104_reset_all_palette_colors() {
    let mut term = Terminal::new(10, 10);
    let orig0 = term.palette().get(0);
    let orig1 = term.palette().get(1);
    let orig2 = term.palette().get(2);

    term.feed(b"\x1b]4;0;rgb:ff/00/00\x1b\\");
    term.feed(b"\x1b]4;1;rgb:00/ff/00\x1b\\");
    term.feed(b"\x1b]4;2;rgb:00/00/ff\x1b\\");

    term.feed(b"\x1b]104\x1b\\");
    assert_eq!(term.palette().get(0), orig0);
    assert_eq!(term.palette().get(1), orig1);
    assert_eq!(term.palette().get(2), orig2);
}

/// Upstream test: "OSC 10 set and reset foreground color"
#[test]
fn osc_10_set_and_reset_foreground_color() {
    let mut term = Terminal::new(10, 10);
    assert_eq!(term.default_colors().0, None);

    term.feed(b"\x1b]10;rgb:ff/00/00\x1b\\");
    assert_eq!(term.default_colors().0, Some((0xff, 0x00, 0x00)));

    term.feed(b"\x1b]110\x1b\\");
    assert_eq!(term.default_colors().0, None);
}

/// Upstream test: "OSC 11 set and reset background color"
#[test]
fn osc_11_set_and_reset_background_color() {
    let mut term = Terminal::new(10, 10);
    assert_eq!(term.default_colors().1, None);

    term.feed(b"\x1b]11;rgb:00/ff/00\x1b\\");
    assert_eq!(term.default_colors().1, Some((0x00, 0xff, 0x00)));

    term.feed(b"\x1b]111\x1b\\");
    assert_eq!(term.default_colors().1, None);
}

/// Upstream test: "OSC 12 set and reset cursor color"
#[test]
fn osc_12_set_and_reset_cursor_color() {
    let mut term = Terminal::new(10, 10);
    assert_eq!(term.default_colors().2, None);

    term.feed(b"\x1b]12;rgb:00/00/ff\x1b\\");
    assert_eq!(term.default_colors().2, Some((0x00, 0x00, 0xff)));

    term.feed(b"\x1b]112\x1b\\");
    assert_eq!(term.default_colors().2, None);
}

/// Upstream test: "OSC color query responses"
#[test]
fn osc_color_query_responses() {
    let mut term = Terminal::new(10, 10);

    term.feed(b"\x1b]10;?\x1b\\");
    assert_eq!(term.take_output(), b"");

    term.feed(b"\x1b]11;?\x1b\\");
    assert_eq!(term.take_output(), b"");

    term.feed(b"\x1b]4;2;rgb:12/34/56;2;?\x1b\\");
    assert_eq!(term.take_output(), b"\x1b]4;2;rgb:1212/3434/5656\x1b\\");

    term.feed(b"\x1b]10;rgb:01/02/03\x1b\\");
    term.feed(b"\x1b]11;rgb:04/05/06\x1b\\");
    term.feed(b"\x1b]12;rgb:07/08/09\x1b\\");
    term.feed(b"\x1b]10;?;?;?\x1b\\");
    assert_eq!(
        term.take_output(),
        b"\x1b]10;rgb:0101/0202/0303\x1b\\\x1b]11;rgb:0404/0505/0606\x1b\\\x1b]12;rgb:0707/0808/0909\x1b\\"
    );

    term.feed(b"\x1b]112\x1b\\");
    term.feed(b"\x1b]12;?\x07");
    assert_eq!(term.take_output(), b"\x1b]12;rgb:0101/0202/0303\x07");
}
