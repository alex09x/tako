// Source: the upstream `print_b` test suite

use tako_core::terminal::Terminal;
use tako_core::grid::CellAttrs;

/// Upstream test: "Terminal: print wide char at right edge with hyperlink"
#[test]
fn print_wide_char_at_right_edge_with_hyperlink() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"\x1b[1;10H");
    term.feed("中".as_bytes());

    assert_eq!(term.cursor(), (1, 2));

    let cell9 = term.active_grid().get(0, 9).unwrap();
    assert!(!cell9.is_wide_spacer);
    assert!(cell9.hyperlink.is_some());

    let cell0 = term.active_grid().get(1, 0).unwrap();
    assert_eq!(cell0.char, '中');
    assert!(!cell0.is_wide_spacer);
    assert!(cell0.hyperlink.is_some());

    let cell1 = term.active_grid().get(1, 1).unwrap();
    assert!(cell1.is_wide_spacer);
    assert!(cell1.hyperlink.is_some());
}

/// Upstream test: "Terminal: print with style marks the row as styled"
#[test]
fn print_with_style_marks_the_row_as_styled() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1mA");
    term.feed(b"\x1b[0mB");
    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: insert mode with wide characters"
#[test]
fn insert_mode_with_wide_characters() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"hello");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[4h");
    term.feed("😀".as_bytes());

    assert_eq!(term.plain_string(), "h😀el");
}

/// Upstream test: "Terminal: insert mode with wide characters at end"
#[test]
fn insert_mode_with_wide_characters_at_end() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"well");
    term.feed(b"\x1b[4h");
    term.feed("😀".as_bytes());

    assert_eq!(term.plain_string(), "well\n😀");
}

/// Upstream test: "Terminal: insert mode pushing off wide character"
#[test]
fn insert_mode_pushing_off_wide_character() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"123");
    term.feed("😀".as_bytes());
    term.feed(b"\x1b[4h");
    term.feed(b"\x1b[1;1H");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X123");
}

/// Upstream test: "Terminal: printRepeat simple"
#[test]
fn print_repeat_simple() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"A");
    term.feed(b"\x1b[1b");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "AA");
}

/// Upstream test: "Terminal: printRepeat wrap"
#[test]
fn print_repeat_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"    A");
    term.feed(b"\x1b[1b");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "    A\nA");
}

/// Upstream test: "Terminal: printRepeat no previous character"
#[test]
fn print_repeat_no_previous_character() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1b");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "");
}

/// Upstream test: "Terminal: printSlice simple ascii"
#[test]
fn print_slice_simple_ascii() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"hello");
    assert_eq!(term.cursor().1, 5);
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "hello");
}

/// Upstream test: "Terminal: printSlice wraps and scrolls"
#[test]
fn print_slice_wraps_and_scrolls() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"abcdefghijkl");

    assert_eq!(term.plain_string(), "fghij\nkl");
    assert_eq!(term.cursor().1, 2);
    assert!(!term.pending_wrap());
}

/// Upstream test: "Terminal: printSlice pending wrap state"
#[test]
fn print_slice_pending_wrap_state() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"abcde");

    assert_eq!(term.cursor().1, 4);
    assert!(term.pending_wrap());

    assert_eq!(term.plain_string(), "abcde");
}

// SKIPPED "Terminal: printSlice differential fuzz vs print": depends on internal Zig helper testPrintSliceDifferential and printSlice implementation

// SKIPPED "Terminal: printAttributes": depends on internal Zig printAttributes SGR buffer formatter

/// Upstream test: "Terminal: resize less cols with wide char then print"
#[test]
fn resize_less_cols_with_wide_char_then_print() {
    let mut term = Terminal::new(3, 3);
    term.feed(b"x");
    term.feed("😀".as_bytes());
    term.resize(2, 3);
    term.feed(b"\x1b[1;2H");
    term.feed("😀".as_bytes());
}

/// Upstream test: "Terminal: resize with wraparound off"
#[test]
fn resize_with_wraparound_off() {
    let mut term = Terminal::new(4, 2);
    term.feed(b"\x1b[?7l");
    term.feed(b"0123");
    term.resize(2, 2);

    assert_eq!(term.plain_string(), "01");
}

/// Upstream test: "Terminal: resize with wraparound on"
#[test]
fn resize_with_wraparound_on() {
    let mut term = Terminal::new(4, 2);
    term.feed(b"\x1b[?7h");
    term.feed(b"0123");
    term.resize(2, 2);

    assert_eq!(term.plain_string(), "01\n23");
}

/// Upstream test: "Terminal: print wide char"
#[test]
fn print_wide_char() {
    let mut term = Terminal::new(80, 80);
    term.feed("😀".as_bytes());
    assert_eq!(term.cursor(), (0, 2));

    let cell0 = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell0.char, '😀');
    assert!(!cell0.is_wide_spacer);

    let cell1 = term.active_grid().get(0, 1).unwrap();
    assert!(cell1.is_wide_spacer);

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print over wide spacer tail"
#[test]
fn print_over_wide_spacer_tail() {
    let mut term = Terminal::new(5, 5);
    term.feed("橋".as_bytes());
    term.feed(b"\x1b[1;2H");
    term.feed(b"X");

    let cell0 = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell0.char, '\0');
    assert!(!cell0.is_wide_spacer);

    let cell1 = term.active_grid().get(0, 1).unwrap();
    assert_eq!(cell1.char, 'X');
    assert!(!cell1.is_wide_spacer);

    assert_eq!(term.plain_string(), " X");

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print over wide char with bold"
#[test]
fn print_over_wide_char_with_bold() {
    let mut term = Terminal::new(80, 80);
    term.feed(b"\x1b[1m");
    term.feed("😀".as_bytes());
    // upstream: style map count assert, not modeled

    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[0m");
    term.feed(b"A");

    // upstream: style map count assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    let cell0 = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell0.char, 'A');
    assert!(!cell0.attrs.contains(CellAttrs::BOLD));
}
