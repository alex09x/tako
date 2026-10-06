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

/// Upstream test: "Terminal: horizontal tab back with cursor before left margin"
#[test]
fn horizontal_tab_back_with_cursor_before_left_margin() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b7");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[5;0s");
    term.feed(b"\x1b8");
    term.feed(b"\x1b[Z");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X");
}

/// Upstream test: "Terminal: cursorPos relative to origin with left/right"
#[test]
fn cursor_pos_relative_to_origin_with_left_right() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;4r");
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[1;1H");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "\n\n  X");
}

/// Upstream test: "Terminal: cursorPos limits with full scroll region"
#[test]
fn cursor_pos_limits_with_full_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;4r");
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[500;500H");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "\n\n\n    X");
}

/// Upstream test: "Terminal: setLeftAndRightMargin simple"
#[test]
fn set_left_and_right_margin_simple() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[0;0s");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1X");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), " BC\nDEF\nGHI");
}

/// Upstream test: "Terminal: setLeftAndRightMargin left only"
#[test]
fn set_left_and_right_margin_left_only() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;0s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A\nDBC\nGEF\n HI");
}

/// Upstream test: "Terminal: setLeftAndRightMargin left and right"
#[test]
fn set_left_and_right_margin_left_and_right() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[1;2s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "  C\nABF\nDEI\nGH");
}

/// Upstream test: "Terminal: setLeftAndRightMargin left equal right"
#[test]
fn set_left_and_right_margin_left_equal_right() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;2s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: setLeftAndRightMargin mode 69 unset"
#[test]
fn set_left_and_right_margin_mode_69_unset() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69l");
    term.feed(b"\x1b[1;2s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");
}
