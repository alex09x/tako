// Ported from the upstream `insert_lines` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: insertLines simple"
#[test]
fn insert_lines_simple() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC\n\nDEF\nGHI");
}

/// Upstream test: "Terminal: insertLines colors with bg color"
#[test]
fn insert_lines_colors_with_bg_color() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[1L");

    assert_eq!(term.plain_string(), "ABC\n\nDEF\nGHI");

    for x in 0..5 {
        let cell = term.active_grid().get(1, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(0xFF, 0, 0));
    }
}

/// Upstream test: "Terminal: insertLines handles style refs"
#[test]
fn insert_lines_handles_style_refs() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"ABC\r\nDEF\r\n");
    term.feed(b"\x1b[1m");
    term.feed(b"GHI");
    term.feed(b"\x1b[0m");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1L");

    assert_eq!(term.plain_string(), "ABC\n\nDEF");

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: insertLines outside of scroll region"
#[test]
fn insert_lines_outside_of_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[3;4r");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: insertLines top/bottom scroll region"
#[test]
fn insert_lines_top_bottom_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI\r\n123");
    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC\n\nDEF\n123");
}

// SKIPPED "Terminal: insertLines hyperlink-dense row crosses page boundary": depends on internal paged grid storage and hyperlink manager APIs

/// Upstream test: "Terminal: insertLines (legacy test)"
#[test]
fn insert_lines_legacy_test() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"A\r\nB\r\nC\r\nD\r\nE");
    term.feed(b"\x1b[2;1H");
    term.feed(b"\x1b[2L");

    assert_eq!(term.plain_string(), "A\n\n\nB\nC");
}

/// Upstream test: "Terminal: insertLines zero"
#[test]
fn insert_lines_zero() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[0L");
}

/// Upstream test: "Terminal: insertLines with scroll region"
#[test]
fn insert_lines_with_scroll_region() {
    let mut term = Terminal::new(2, 6);

    term.feed(b"A\r\nB\r\nC\r\nD\r\nE");
    term.feed(b"\x1b[1;2r");
    term.feed(b"\x1b[1;1H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    term.feed(b"X");

    assert_eq!(term.plain_string(), "X\nA\nC\nD\nE");
}

/// Upstream test: "Terminal: insertLines more than remaining"
#[test]
fn insert_lines_more_than_remaining() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"A\r\nB\r\nC\r\nD\r\nE");
    term.feed(b"\x1b[2;1H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[20L");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A");
}

/// Upstream test: "Terminal: insertLines resets pending wrap"
#[test]
fn insert_lines_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1L");
    assert!(!term.pending_wrap());
    term.feed(b"B");

    assert_eq!(term.plain_string(), "B\nABCDE");
}

/// Upstream test: "Terminal: insertLines resets wrap"
#[test]
fn insert_lines_resets_wrap() {
    let mut term = Terminal::new(3, 3);

    term.feed(b"1\r\nABCDEF");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[1L");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X\n1\nABC");

    assert!(!term.active_grid().is_line_wrapped(2));
}
