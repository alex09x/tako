// Upstream source: the upstream `erase_chars` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: eraseChars simple operation"
#[test]
fn erase_chars_simple_operation() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2X");
    term.feed(b"X");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "X C");
}

/// Upstream test: "Terminal: eraseChars minimum one"
#[test]
fn erase_chars_minimum_one() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[0X");
    term.feed(b"X");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "XBC");
}

/// Upstream test: "Terminal: eraseChars beyond screen edge"
#[test]
fn erase_chars_beyond_screen_edge() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"  ABC");
    term.feed(b"\x1b[1;4H");
    term.feed(b"\x1b[10X");

    assert_eq!(term.plain_string(), "  A");
}

/// Upstream test: "Terminal: eraseChars wide character"
#[test]
fn erase_chars_wide_character() {
    let mut term = Terminal::new(5, 5);
    term.feed("橋".as_bytes());
    term.feed(b"BC");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[1X");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X BC");
}

/// Upstream test: "Terminal: eraseChars resets pending wrap"
#[test]
fn erase_chars_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1X");
    assert!(!term.pending_wrap());
    term.feed(b"X");

    assert_eq!(term.plain_string(), "ABCDX");
}

/// Upstream test: "Terminal: eraseChars preserves background sgr"
#[test]
fn erase_chars_preserves_background_sgr() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[2X");

    assert_eq!(term.plain_string(), "  C");

    let cell0 = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell0.bg, Color::Rgb(255, 0, 0));

    let cell1 = term.active_grid().get(0, 1).unwrap();
    assert_eq!(cell1.bg, Color::Rgb(255, 0, 0));
}

/// Upstream test: "Terminal: eraseChars wide char boundary conditions"
#[test]
fn erase_chars_wide_char_boundary_conditions() {
    let mut term = Terminal::new(8, 1);
    term.feed("😀a😀b😀".as_bytes());
    assert_eq!(term.plain_string(), "😀a😀b😀");

    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[3X");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "     b😀");
}

/// Upstream test: "Terminal: eraseChars wide char splits proper cell boundaries"
#[test]
fn erase_chars_wide_char_splits_proper_cell_boundaries() {
    let mut term = Terminal::new(30, 1);
    term.feed("x食べて下さい".as_bytes());
    assert_eq!(term.plain_string(), "x食べて下さい");

    term.feed(b"\x1b[1;6H");
    term.feed(b"\x1b[4X");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "x食べ    さい");
}

/// Upstream test: "Terminal: eraseChars wide char wrap boundary conditions"
#[test]
fn erase_chars_wide_char_wrap_boundary_conditions() {
    let mut term = Terminal::new(8, 3);
    term.feed(".......😀abcde😀......".as_bytes());
    assert_eq!(term.plain_string(), ".......\n😀abcde\n😀......");

    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[3X");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), ".......\n    cde\n😀......");
}
