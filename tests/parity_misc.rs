// Ported from the upstream `misc` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: input with no control characters"
#[test]
fn input_with_no_control_characters() {
    let mut term = Terminal::new(40, 40);
    term.feed(b"hello");
    assert_eq!(term.cursor().0, 0);
    assert_eq!(term.cursor().1, 5);
    assert_eq!(term.plain_string(), "hello");
    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: input that forces scroll"
#[test]
fn input_that_forces_scroll() {
    let mut term = Terminal::new(1, 5);
    term.feed(b"abcdef");
    assert_eq!(term.cursor().0, 4);
    assert_eq!(term.cursor().1, 0);
    assert_eq!(term.plain_string(), "b\nc\nd\ne\nf");
}

/// Upstream test: "Terminal: soft wrap"
#[test]
fn soft_wrap() {
    let mut term = Terminal::new(3, 80);
    term.feed(b"hello");
    assert_eq!(term.cursor().0, 1);
    assert_eq!(term.cursor().1, 2);
    assert_eq!(term.plain_string(), "hel\nlo");
}

/// Upstream test: "Terminal: tabClear single"
#[test]
fn tab_clear_single() {
    let mut term = Terminal::new(30, 5);
    term.feed(b"\t");
    term.feed(b"\x1b[0g");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1;1H");
    term.feed(b"\t");
    assert_eq!(term.cursor().1, 16);
}

/// Upstream test: "Terminal: tabClear all"
#[test]
fn tab_clear_all() {
    let mut term = Terminal::new(30, 5);
    term.feed(b"\x1b[3g");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1;1H");
    term.feed(b"\t");
    assert_eq!(term.cursor().1, 29);
}

// SKIPPED "Terminal: cursor defaults update current default cursor": depends on configurable default cursor style/blink init options and API methods not present in pure-Rust core

// SKIPPED "Terminal: cursor defaults do not override explicit cursor": depends on cursor style defaults and style state inspection APIs not present in pure-Rust core

/// Upstream test: "Terminal: fullReset with a non-empty pen"
#[test]
fn full_reset_with_a_non_empty_pen() {
    let mut term = Terminal::new(80, 80);
    term.feed(b"\x1b[38;2;255;0;127m");
    term.feed(b"\x1b[48;2;255;0;127m");
    // upstream: semantic_content input assert/field not modeled
    term.feed(b"\x1bc");

    let (row, col) = term.cursor();
    let cell = term.active_grid().get(row, col).unwrap();
    assert_eq!(cell.fg, Color::Default);
    assert_eq!(cell.bg, Color::Default);
}

/// Upstream test: "Terminal: fullReset hyperlink"
#[test]
fn full_reset_hyperlink() {
    let mut term = Terminal::new(80, 80);
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"\x1bc");
    let (row, col) = term.cursor();
    let cell = term.active_grid().get(row, col).unwrap();
    assert_eq!(cell.hyperlink, None);
}

/// Upstream test: "Terminal: fullReset with a non-empty saved cursor"
#[test]
fn full_reset_with_a_non_empty_saved_cursor() {
    let mut term = Terminal::new(80, 80);
    term.feed(b"\x1b[38;2;255;0;127m");
    term.feed(b"\x1b[48;2;255;0;127m");
    term.feed(b"\x1b7");
    term.feed(b"\x1bc");

    let (row, col) = term.cursor();
    let cell = term.active_grid().get(row, col).unwrap();
    assert_eq!(cell.fg, Color::Default);
    assert_eq!(cell.bg, Color::Default);
}

// SKIPPED "Terminal: fullReset status display": status display (DECSSDT) API not modeled
