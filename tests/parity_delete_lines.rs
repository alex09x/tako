// Ported from the upstream `delete_lines` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: deleteLines simple"
#[test]
fn delete_lines_simple() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"ABC");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"DEF");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    term.feed(b"\x1b[1M");

    assert_eq!(term.plain_string(), "ABC\nGHI");
}

/// Upstream test: "Terminal: deleteLines colors with bg color"
#[test]
fn delete_lines_colors_with_bg_color() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"ABC");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"DEF");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");

    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[1M");

    assert_eq!(term.plain_string(), "ABC\nGHI");

    for x in 0..5 {
        let cell = term.active_grid().get(4, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(0xFF, 0, 0));
    }
}

// SKIPPED "Terminal: deleteLines hyperlink-dense row crosses page boundary": depends on internal page memory and hyperlink capacity APIs not present in pure-Rust core

/// Upstream test: "Terminal: deleteLines (legacy)"
#[test]
fn delete_lines_legacy() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"A");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"B");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"C");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"D");

    term.feed(b"\x1b[2A");
    term.feed(b"\x1b[1M");

    term.feed(b"E");
    term.feed(b"\r");
    term.feed(b"\n");

    let (y, x) = term.cursor();
    assert_eq!(x, 0);
    assert_eq!(y, 2);

    assert_eq!(term.plain_string(), "A\nE\nD");
}

/// Upstream test: "Terminal: deleteLines with scroll region"
#[test]
fn delete_lines_with_scroll_region() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"A");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"B");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"C");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"D");

    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[1;1H");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    term.feed(b"\x1b[1M");

    term.feed(b"E");
    term.feed(b"\r");
    term.feed(b"\n");

    assert_eq!(term.plain_string(), "E\nC\n\nD");
}

/// Upstream test: "Terminal: deleteLines with scroll region, large count"
#[test]
fn delete_lines_with_scroll_region_large_count() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"A");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"B");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"C");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"D");

    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[1;1H");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    term.feed(b"\x1b[5M");

    term.feed(b"E");
    term.feed(b"\r");
    term.feed(b"\n");

    assert_eq!(term.plain_string(), "E\n\n\nD");
}

/// Upstream test: "Terminal: deleteLines with scroll region, cursor outside of region"
#[test]
fn delete_lines_with_scroll_region_cursor_outside_of_region() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"A");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"B");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"C");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"D");

    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[4;1H");

    // upstream: dirty-tracking assert, not modeled

    term.feed(b"\x1b[1M");

    assert_eq!(term.plain_string(), "A\nB\nC\nD");
}

/// Upstream test: "Terminal: deleteLines resets pending wrap"
#[test]
fn delete_lines_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"ABCDE");
    assert!(term.pending_wrap());

    term.feed(b"\x1b[1M");
    assert!(!term.pending_wrap());

    term.feed(b"B");

    assert_eq!(term.plain_string(), "B");
}

/// Upstream test: "Terminal: deleteLines resets wrap"
#[test]
fn delete_lines_resets_wrap() {
    let mut term = Terminal::new(3, 3);

    term.feed(b"1");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"ABCDEF");

    term.feed(b"\x1b[1;2r");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[1M");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "XBC\n\nDEF");

    // upstream: row.wrap assert, not modeled
}

/// Upstream test: "Terminal: deleteLines wide character spacer head"
#[test]
fn delete_lines_wide_character_spacer_head() {
    let mut term = Terminal::new(5, 3);

    term.feed("AAAAABBBB😀CCC".as_bytes());

    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[1M");

    assert_eq!(term.plain_string(), "BBBB\n😀CCC");
}

/// Upstream test: "Terminal: deleteLines zero"
#[test]
fn delete_lines_zero() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[0M");
}
