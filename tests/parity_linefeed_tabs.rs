// Ported from the upstream `linefeed_tabs` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: linefeed and carriage return"
#[test]
fn linefeed_and_carriage_return() {
    let mut term = Terminal::new(80, 80);

    // Print and CR.
    term.feed(b"hello");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\r");

    // CR should not mark row dirty because it doesn't change rendering.
    // upstream: dirty-tracking assert, not modeled

    term.feed(b"\n");

    // LF marks row dirty due to cursor movement
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    term.feed(b"world");
    let (row, col) = term.cursor();
    assert_eq!(row, 1);
    assert_eq!(col, 5);
    assert_eq!(term.plain_string(), "hello\nworld");
}

/// Upstream test: "Terminal: linefeed mode automatic carriage return"
#[test]
fn linefeed_mode_automatic_carriage_return() {
    let mut term = Terminal::new(10, 10);

    // Basic grid writing
    term.feed(b"\x1b[20h");
    term.feed(b"123456");
    term.feed(b"\n");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "123456\nX");
}

/// Upstream test: "Terminal: carriage return unsets pending wrap"
#[test]
fn carriage_return_unsets_pending_wrap() {
    let mut term = Terminal::new(5, 80);

    // Basic grid writing
    term.feed(b"hello");
    assert!(term.pending_wrap());
    term.feed(b"\r");
    assert!(!term.pending_wrap());
}

/// Upstream test: "Terminal: backspace"
#[test]
fn backspace() {
    let mut term = Terminal::new(80, 80);

    // BS
    term.feed(b"hello");
    term.feed(b"\x08");
    term.feed(b"y");
    let (row, col) = term.cursor();
    assert_eq!(row, 0);
    assert_eq!(col, 5);
    assert_eq!(term.plain_string(), "helly");
}

/// Upstream test: "Terminal: horizontal tabs"
#[test]
fn horizontal_tabs() {
    let mut term = Terminal::new(20, 5);

    // HT
    term.feed(b"1");
    term.feed(b"\t");
    let (_, col) = term.cursor();
    assert_eq!(col, 8);

    // HT
    term.feed(b"\t");
    let (_, col) = term.cursor();
    assert_eq!(col, 16);

    // HT at the end
    term.feed(b"\t");
    let (_, col) = term.cursor();
    assert_eq!(col, 19);
    term.feed(b"\t");
    let (_, col) = term.cursor();
    assert_eq!(col, 19);
}

/// Upstream test: "Terminal: horizontal tabs starting on tabstop"
#[test]
fn horizontal_tabs_starting_on_tabstop() {
    let mut term = Terminal::new(20, 5);

    term.feed(b"\x1b[0;9H");
    term.feed(b"X");
    term.feed(b"\x1b[0;9H");
    term.feed(b"\t");
    term.feed(b"A");

    assert_eq!(term.plain_string(), "        X       A");
}

/// Upstream test: "Terminal: horizontal tabs back"
#[test]
fn horizontal_tabs_back() {
    let mut term = Terminal::new(20, 5);

    // Edge of screen
    term.feed(b"\x1b[0;20H");

    // HT
    term.feed(b"\x1b[Z");
    let (_, col) = term.cursor();
    assert_eq!(col, 16);

    // HT
    term.feed(b"\x1b[Z");
    let (_, col) = term.cursor();
    assert_eq!(col, 8);

    // HT
    term.feed(b"\x1b[Z");
    let (_, col) = term.cursor();
    assert_eq!(col, 0);
    term.feed(b"\x1b[Z");
    let (_, col) = term.cursor();
    assert_eq!(col, 0);
}

/// Upstream test: "Terminal: horizontal tabs back starting on tabstop"
#[test]
fn horizontal_tabs_back_starting_on_tabstop() {
    let mut term = Terminal::new(20, 5);

    term.feed(b"\x1b[0;9H");
    term.feed(b"X");
    term.feed(b"\x1b[0;9H");
    term.feed(b"\x1b[Z");
    term.feed(b"A");

    assert_eq!(term.plain_string(), "A       X");
}
