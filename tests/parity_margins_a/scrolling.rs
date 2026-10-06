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

/// Upstream test: "Terminal: insertLines left/right scroll region"
#[test]
fn insert_lines_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC123\nD   56\nGEF489\n HI7");
}

/// Upstream test: "Terminal: scrollUp left/right scroll region"
#[test]
fn scroll_up_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    let cursor = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1S");
    assert_eq!(cursor, term.cursor());

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "AEF423\nDHI756\nG   89");
}

/// Upstream test: "Terminal: scrollUp left/right scroll region hyperlink"
#[test]
fn scroll_up_left_right_scroll_region_hyperlink() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\n");
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"DEF456");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1S");

    assert_eq!(term.plain_string(), "AEF423\nDHI756\nG   89");

    let grid = term.active_grid();
    for x in 0..1 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 1..4 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 4..6 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }

    for x in 0..1 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 1..4 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 4..6 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
}

/// Upstream test: "Terminal: scrollUp full top/bottomleft/right scroll region"
#[test]
fn scroll_up_full_top_bottomleft_right_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"top");
    term.feed(b"\x1b[5;1H");
    term.feed(b"ABCDE");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;5r");
    term.feed(b"\x1b[2;4s");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[4S");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "top\n\n\n\nA   E");
}

/// Upstream test: "Terminal: scrollUp with max_scrollback_bytes zero and left/right margin"
#[test]
fn scroll_up_with_max_scrollback_bytes_zero_and_left_right_margin() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"AAAAABBBBB\r\nCCCCCDDDDD\r\nEEEEEFFFFF");
    term.feed(b"\x1b[?69h\x1b[2;6s");

    term.feed(b"\x1b[1S");

    assert_eq!(term.plain_string(), "ACCCCDBBBB\nCEEEEFDDDD\nE     FFFF");
}

/// Upstream test: "Terminal: scrollDown left/right scroll region"
#[test]
fn scroll_down_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    let cursor = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    assert_eq!(cursor, term.cursor());

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A   23\nDBC156\nGEF489\n HI7");
}

/// Upstream test: "Terminal: scrollDown left/right scroll region hyperlink"
#[test]
fn scroll_down_left_right_scroll_region_hyperlink() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"ABC123");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1T");

    assert_eq!(term.plain_string(), "A   23\nDBC156\nGEF489\n HI7");

    let grid = term.active_grid();
    for x in 0..1 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 1..4 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 4..6 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }

    for x in 0..1 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 1..4 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 4..6 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}

/// Upstream test: "Terminal: scrollDown outside of left/right scroll region"
#[test]
fn scroll_down_outside_of_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[1;1H");

    let cursor = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    assert_eq!(cursor, term.cursor());

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A   23\nDBC156\nGEF489\n HI7");
}

/// Upstream test: "Terminal: reverseIndex left/right margins"
#[test]
fn reverse_index_left_right_margins() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\x1b[2;1H");
    term.feed(b"DEF");
    term.feed(b"\x1b[3;1H");
    term.feed(b"GHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;3s");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1bM");

    assert_eq!(term.plain_string(), "A\nDBC\nGEF\n HI");
}
