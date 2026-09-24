// Upstream source: the upstream `insert_blanks` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

// SKIPPED "Terminal: insertBlanks 0": upstream calls the API with a literal 0;
// the wire form (CSI 0 P / CSI 0 @) means 1 by spec, so the case is
// untranslatable via escape sequences.

/// Upstream test: "Terminal: insertBlanks"
#[test]
fn terminal_insert_blanks() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2@");
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "  ABC");
}

/// Upstream test: "Terminal: insertBlanks pushes off end"
#[test]
fn terminal_insert_blanks_pushes_off_end() {
    let mut term = Terminal::new(3, 2);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2@");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "  A");
}

/// Upstream test: "Terminal: insertBlanks more than size"
#[test]
fn terminal_insert_blanks_more_than_size() {
    let mut term = Terminal::new(3, 2);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[5@");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "");
}

/// Upstream test: "Terminal: insertBlanks no scroll region, fits"
#[test]
fn terminal_insert_blanks_no_scroll_region_fits() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2@");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "  ABC");
}

/// Upstream test: "Terminal: insertBlanks preserves background sgr"
#[test]
fn terminal_insert_blanks_preserves_background_sgr() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[2@");

    assert_eq!(term.plain_string(), "  ABC");
    let cell = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
}

/// Upstream test: "Terminal: insertBlanks shift off screen"
#[test]
fn terminal_insert_blanks_shift_off_screen() {
    let mut term = Terminal::new(5, 10);
    term.feed(b"  ABC");
    term.feed(b"\x1b[1;3H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2@");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"X");
    assert_eq!(term.plain_string(), "  X A");
}

/// Upstream test: "Terminal: insertBlanks split multi-cell character"
#[test]
fn terminal_insert_blanks_split_multi_cell_character() {
    let mut term = Terminal::new(5, 10);
    term.feed("123橋".as_bytes());
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1@");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), " 123");
}

/// Upstream test: "Terminal: insertBlanks split multi-cell character from tail"
#[test]
fn terminal_insert_blanks_split_multi_cell_character_from_tail() {
    let mut term = Terminal::new(5, 10);
    term.feed("橋123".as_bytes());
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[1@");
    assert_eq!(term.plain_string(), "   12");
}

/// Upstream test: "Terminal: insertBlanks shifts hyperlinks"
#[test]
fn terminal_insert_blanks_shifts_hyperlinks() {
    let mut term = Terminal::new(10, 2);
    term.feed(b"\x1b]8;;http://example.com\x1b\\ABC");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[2@");

    assert_eq!(term.plain_string(), "  ABC");

    for x in 2..5 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert!(cell.hyperlink.is_some());
    }
    for x in 0..2 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}

/// Upstream test: "Terminal: insertBlanks pushes hyperlink off end completely"
#[test]
fn terminal_insert_blanks_pushes_hyperlink_off_end_completely() {
    let mut term = Terminal::new(3, 2);
    term.feed(b"\x1b]8;;http://example.com\x1b\\ABC");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[3@");

    assert_eq!(term.plain_string(), "");

    for x in 0..3 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}
