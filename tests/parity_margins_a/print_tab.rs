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

/// Upstream test: "Terminal: print right margin wrap"
#[test]
fn print_right_margin_wrap() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;5H");
    term.feed(b"XY");

    assert_eq!(term.plain_string(), "1234X6789\n  Y");
    // upstream: row.wrap assertion, internal state not modeled in active_grid
}

/// Upstream test: "Terminal: print right margin wrap dirty tracking"
#[test]
fn print_right_margin_wrap_dirty_tracking() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;5H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"X");
    // upstream: dirty-tracking assert, not modeled

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"Y");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "1234X6789\n  Y");
}

/// Upstream test: "Terminal: print right margin outside"
#[test]
fn print_right_margin_outside() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;6H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"XY");

    assert_eq!(term.plain_string(), "12345XY89");
    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print right margin outside wrap"
#[test]
fn print_right_margin_outside_wrap() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;10H");
    term.feed(b"XY");

    assert_eq!(term.plain_string(), "123456789X\n  Y");
}

/// Upstream test: "Terminal: print wide char at right margin does not create spacer head"
#[test]
fn print_wide_char_at_right_margin_does_not_create_spacer_head() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;5H");
    term.feed("😀".as_bytes());

    assert_eq!(term.cursor(), (1, 4));

    // upstream: dirty-tracking assert, not modeled

    let grid = term.active_grid();
    let cell0 = grid.get(0, 4).unwrap();
    assert_eq!(cell0.char, '\0');
    assert!(!cell0.is_wide_spacer);
    // upstream: row.wrap assertion, internal state not modeled in active_grid

    let cell1 = grid.get(1, 2).unwrap();
    assert_eq!(cell1.char, '😀');
    assert!(!cell1.is_wide_spacer);

    let cell2 = grid.get(1, 3).unwrap();
    assert!(cell2.is_wide_spacer);
}

/// Upstream test: "Terminal: carriage return origin mode moves to left margin"
#[test]
fn carriage_return_origin_mode_moves_to_left_margin() {
    let mut term = Terminal::new(5, 80);
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[?69h\x1b[3;5s");
    // Move cursor x to 0 in origin mode or absolute mode
    term.feed(b"\x1b[?6l\x1b[1;1H\x1b[?6h");
    term.feed(b"\r");
    assert_eq!(term.cursor().1, 2);
}

/// Upstream test: "Terminal: carriage return left of left margin moves to zero"
#[test]
fn carriage_return_left_of_left_margin_moves_to_zero() {
    let mut term = Terminal::new(5, 80);
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\r");
    assert_eq!(term.cursor().1, 0);
}

/// Upstream test: "Terminal: carriage return right of left margin moves to left margin"
#[test]
fn carriage_return_right_of_left_margin_moves_to_left_margin() {
    let mut term = Terminal::new(5, 80);
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[1;4H");
    term.feed(b"\r");
    assert_eq!(term.cursor().1, 2);
}

/// Upstream test: "Terminal: horizontal tabs with right margin"
#[test]
fn horizontal_tabs_with_right_margin() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b[?69h\x1b[3;6s");
    term.feed(b"\x1b[1;1H");
    term.feed(b"X");
    term.feed(b"\t");
    term.feed(b"A");

    assert_eq!(term.plain_string(), "X    A");
}

/// Upstream test: "Terminal: horizontal tabs with left margin in origin mode"
#[test]
fn horizontal_tabs_with_left_margin_in_origin_mode() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[?69h\x1b[3;6s");
    term.feed(b"\x1b[1;2H");
    term.feed(b"X");
    term.feed(b"\x1b[Z");
    term.feed(b"A");

    assert_eq!(term.plain_string(), "  AX");
}
