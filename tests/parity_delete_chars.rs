// Upstream tests: the upstream `delete_chars` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: deleteChars"
#[test]
fn delete_chars() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2P");
    assert_eq!(term.plain_string(), "ADE");
}

// SKIPPED "Terminal: deleteChars zero count": upstream calls the API with a literal 0;
// the wire form (CSI 0 P / CSI 0 @) means 1 by spec, so the case is
// untranslatable via escape sequences.

/// Upstream test: "Terminal: deleteChars more than half"
#[test]
fn delete_chars_more_than_half() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[3P");
    assert_eq!(term.plain_string(), "AE");
}

/// Upstream test: "Terminal: deleteChars more than line width"
#[test]
fn delete_chars_more_than_line_width() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[10P");
    assert_eq!(term.plain_string(), "A");
}

/// Upstream test: "Terminal: deleteChars should shift left"
#[test]
fn delete_chars_should_shift_left() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1P");
    assert_eq!(term.plain_string(), "ACDE");
}

/// Upstream test: "Terminal: deleteChars resets pending wrap"
#[test]
fn delete_chars_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1P");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDX");
}

/// Upstream test: "Terminal: deleteChars simple operation"
#[test]
fn delete_chars_simple_operation() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123");
    term.feed(b"\x1b[1;3H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2P");
    assert_eq!(term.plain_string(), "AB23");
}

/// Upstream test: "Terminal: deleteChars preserves background sgr"
#[test]
fn delete_chars_preserves_background_sgr() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123");
    term.feed(b"\x1b[1;3H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[2P");
    assert_eq!(term.plain_string(), "AB23");
    let grid = term.active_grid();
    for col in (10 - 2)..10 {
        let cell = grid.get(0, col).unwrap();
        assert_eq!(cell.bg, Color::Rgb(0xFF, 0, 0));
    }
}

/// Upstream test: "Terminal: deleteChars split wide character from spacer tail"
#[test]
fn delete_chars_split_wide_character_from_spacer_tail() {
    let mut term = Terminal::new(6, 10);
    term.feed("A橋123".as_bytes());
    term.feed(b"\x1b[1;3H");
    term.feed(b"\x1b[1P");
    assert_eq!(term.plain_string(), "A 123");
}

/// Upstream test: "Terminal: deleteChars split wide character tail"
#[test]
fn delete_chars_split_wide_character_tail() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;4H");
    term.feed("橋".as_bytes());
    term.feed(b"\r");
    term.feed(b"\x1b[4P");
    term.feed(b"0");
    assert_eq!(term.plain_string(), "0");
}

/// Upstream test: "Terminal: deleteChars wide char boundary conditions"
#[test]
fn delete_chars_wide_char_boundary_conditions() {
    let mut term = Terminal::new(8, 1);
    term.feed("😀a😀b😀".as_bytes());
    assert_eq!(term.plain_string(), "😀a😀b😀");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[3P");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "  b😀");
}

/// Upstream test: "Terminal: deleteChars wide char wrap boundary conditions"
#[test]
fn delete_chars_wide_char_wrap_boundary_conditions() {
    let mut term = Terminal::new(8, 3);
    term.feed(".......😀abcde😀......".as_bytes());
    assert_eq!(term.plain_string(), ".......\n😀abcde\n😀......");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[3P");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), ".......\n cde\n😀......");
}
