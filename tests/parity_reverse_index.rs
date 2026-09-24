// Upstream tests ported from the upstream `reverse_index` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: reverseIndex"
#[test]
fn reverse_index() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"A");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"B");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"C");
    term.feed(b"\x1bM");
    term.feed(b"D");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"\r");
    term.feed(b"\n");

    assert_eq!(term.plain_string(), "A\nBD\nC");
}

/// Upstream test: "Terminal: reverseIndex from the top"
#[test]
fn reverse_index_from_the_top() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"A");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"B");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"\r");
    term.feed(b"\n");

    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1bM");
    term.feed(b"D");

    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1bM");
    term.feed(b"E");
    term.feed(b"\r");
    term.feed(b"\n");

    assert_eq!(term.plain_string(), "E\nD\nA\nB");
}

/// Upstream test: "Terminal: reverseIndex top of scrolling region"
#[test]
fn reverse_index_top_of_scrolling_region() {
    let mut term = Terminal::new(2, 10);

    term.feed(b"\x1b[2;1H");
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
    term.feed(b"\r");
    term.feed(b"\n");

    term.feed(b"\x1b[2;5r");
    term.feed(b"\x1b[2;1H");
    term.feed(b"\x1bM");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "\nX\nA\nB\nC");
}

/// Upstream test: "Terminal: reverseIndex top of screen"
#[test]
fn reverse_index_top_of_screen() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"A");
    term.feed(b"\x1b[2;1H");
    term.feed(b"B");
    term.feed(b"\x1b[3;1H");
    term.feed(b"C");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1bM");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X\nA\nB\nC");
}

/// Upstream test: "Terminal: reverseIndex not top of screen"
#[test]
fn reverse_index_not_top_of_screen() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"A");
    term.feed(b"\x1b[2;1H");
    term.feed(b"B");
    term.feed(b"\x1b[3;1H");
    term.feed(b"C");
    term.feed(b"\x1b[2;1H");
    term.feed(b"\x1bM");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X\nB\nC");
}

/// Upstream test: "Terminal: reverseIndex top/bottom margins"
#[test]
fn reverse_index_top_bottom_margins() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"A");
    term.feed(b"\x1b[2;1H");
    term.feed(b"B");
    term.feed(b"\x1b[3;1H");
    term.feed(b"C");
    term.feed(b"\x1b[2;3r");
    term.feed(b"\x1b[2;1H");
    term.feed(b"\x1bM");

    assert_eq!(term.plain_string(), "A\n\nB");
}

/// Upstream test: "Terminal: reverseIndex outside top/bottom margins"
#[test]
fn reverse_index_outside_top_bottom_margins() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"A");
    term.feed(b"\x1b[2;1H");
    term.feed(b"B");
    term.feed(b"\x1b[3;1H");
    term.feed(b"C");
    term.feed(b"\x1b[2;3r");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1bM");

    assert_eq!(term.plain_string(), "A\nB\nC");
}
