// 1:1 ports of upstream tests for reverse wrap (modes 45/1045) and
// insert mode (IRM, ANSI mode 4). Sources: the upstream `reverse_wrap` test suite,
// the upstream `irm` test suite.

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: cursorLeft reverse wrap with pending wrap state"
#[test]
fn cursor_left_reverse_wrap_with_pending_wrap_state() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[?45h");
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[D");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDX");
}

/// Upstream test: "Terminal: cursorLeft reverse wrap extended with pending wrap state"
#[test]
fn cursor_left_reverse_wrap_extended_with_pending_wrap_state() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[?1045h");
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[D");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDX");
}

/// Upstream test: "Terminal: cursorLeft reverse wrap"
#[test]
fn cursor_left_reverse_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[?45h");
    term.feed(b"ABCDE1");
    term.feed(b"\x1b[2D");
    term.feed(b"X");
    assert!(term.pending_wrap());
    assert_eq!(term.plain_string(), "ABCDX\n1");
}

/// Upstream test: "Terminal: cursorLeft reverse wrap with no soft wrap"
#[test]
fn cursor_left_reverse_wrap_with_no_soft_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[?45h");
    term.feed(b"ABCDE\r\n1");
    term.feed(b"\x1b[2D");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDE\nX");
}

/// Upstream test: "Terminal: cursorLeft extended reverse wrap"
#[test]
fn cursor_left_extended_reverse_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[?1045h");
    term.feed(b"ABCDE\r\n1");
    term.feed(b"\x1b[2D");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDX\n1");
}

/// Upstream test: "Terminal: cursorLeft extended reverse wrap bottom wraparound"
#[test]
fn cursor_left_extended_reverse_wrap_bottom_wraparound() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"\x1b[?1045h");
    term.feed(b"ABCDE\r\n1");
    term.feed(b"\x1b[7D"); // 1 + cols + 1
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDE\n1\n    X");
}

/// Upstream test: "Terminal: cursorLeft extended reverse wrap is priority if both set"
#[test]
fn cursor_left_extended_reverse_wrap_is_priority_if_both_set() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"\x1b[?45h\x1b[?1045h");
    term.feed(b"ABCDE\r\n1");
    term.feed(b"\x1b[7D");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDE\n1\n    X");
}

/// Upstream test: "Terminal: cursorLeft extended reverse wrap above top scroll region"
#[test]
fn cursor_left_extended_reverse_wrap_above_top_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[?1045h");
    term.feed(b"\x1b[3;r"); // top margin at row 3 (bottom defaults to last row)
    term.feed(b"\x1b[2;1H"); // above the region
    term.feed(b"\x1b[1000D");
    assert_eq!(term.cursor(), (0, 0));
}

/// Upstream test: "Terminal: cursorLeft reverse wrap on first row"
#[test]
fn cursor_left_reverse_wrap_on_first_row() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[?45h");
    term.feed(b"\x1b[3;r");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[1000D");
    assert_eq!(term.cursor(), (0, 0));
}

/// Upstream test: "Terminal: insert mode with space"
#[test]
fn insert_mode_with_space() {
    let mut term = Terminal::new(10, 2);
    term.feed(b"hello");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[4h");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "hXello");
}

/// Upstream test: "Terminal: insert mode doesn't wrap pushed characters"
#[test]
fn insert_mode_doesnt_wrap_pushed_characters() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"hello");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[4h");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "hXell");
}

/// Upstream test: "Terminal: insert mode does nothing at the end of the line"
#[test]
fn insert_mode_does_nothing_at_the_end_of_the_line() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"hello");
    term.feed(b"\x1b[4h");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "hello\nX");
}
