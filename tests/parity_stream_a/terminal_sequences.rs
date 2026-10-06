/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::{ScreenBuffer, Terminal};

/// Upstream test: "basic print"
#[test]
fn basic_print() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"Hello");
    assert_eq!(term.cursor(), (0, 5));
    assert_eq!(term.plain_string(), "Hello");
}

/// Upstream test: "cursor movement"
#[test]
fn cursor_movement() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"Hello\x1b[1;1H");
    assert_eq!(term.cursor(), (0, 0));

    term.feed(b"\x1b[2;3H");
    assert_eq!(term.cursor(), (1, 2));
}

/// Upstream test: "erase operations"
#[test]
fn erase_operations() {
    let mut term = Terminal::new(20, 10);
    term.feed(b"Hello World");
    assert_eq!(term.cursor(), (0, 11));

    term.feed(b"\x1b[1;6H");
    term.feed(b"\x1b[K");
    assert_eq!(term.plain_string(), "Hello");
}

/// Upstream test: "tabs"
#[test]
fn tabs() {
    let mut term = Terminal::new(80, 10);
    term.feed(b"A\tB");
    assert_eq!(term.cursor().1, 9);
    assert_eq!(term.plain_string(), "A       B");
}

/// Upstream test: "modes"
#[test]
fn modes() {
    let mut term = Terminal::new(80, 24);
    assert!(term.modes().autowrap);

    term.feed(b"\x1b[?7l");
    assert!(!term.modes().autowrap);

    term.feed(b"\x1b[?7h");
    assert!(term.modes().autowrap);
}

/// Upstream test: "scrolling regions"
#[test]
fn scrolling_regions() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[5;20r");
    // upstream: scrolling_region fields (top/bottom/left/right) not exposed in public API
}

/// Upstream test: "charsets"
#[test]
fn charsets() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b(0");
    term.feed(b"`");
    assert_eq!(term.plain_string(), "◆");
}

/// Upstream test: "alt screen"
#[test]
fn alt_screen() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"Primary");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);

    term.feed(b"\x1b[?1049h");
    assert_eq!(term.active_screen(), ScreenBuffer::Alternate);

    term.feed(b"Alt");

    term.feed(b"\x1b[?1049l");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);

    assert_eq!(term.plain_string(), "Primary");
}

/// Upstream test: "cursor save and restore"
#[test]
fn cursor_save_and_restore() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[10;15H");
    assert_eq!(term.cursor(), (9, 14));

    term.feed(b"\x1b7");

    term.feed(b"\x1b[1;1H");
    assert_eq!(term.cursor(), (0, 0));

    term.feed(b"\x1b8");
    assert_eq!(term.cursor(), (9, 14));
}

/// Upstream test: "attributes"
#[test]
fn attributes() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[1mBold\x1b[0m");
    assert_eq!(term.plain_string(), "Bold");
}

/// Upstream test: "DECALN screen alignment"
#[test]
fn decaln_screen_alignment() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b#8");
    assert_eq!(term.plain_string(), "EEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE");
    assert_eq!(term.cursor(), (0, 0));
}

/// Upstream test: "full reset"
#[test]
fn full_reset() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"Hello");
    term.feed(b"\x1b[10;20H");
    term.feed(b"\x1b[5;20r");
    term.feed(b"\x1b[?7l");
    term.feed(b"\x1b_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1b\\");
    // upstream: glyph_glossary assert, not modeled

    term.feed(b"\x1bc");

    assert_eq!(term.cursor(), (0, 0));
    // upstream: scrolling_region assert, not modeled
    assert!(term.modes().autowrap);
    // upstream: glyph_glossary assert, not modeled
}
