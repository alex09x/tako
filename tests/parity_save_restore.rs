// Ported from the upstream `save_restore` test suite

use tako_core::terminal::Terminal;

// PORTED in tests/parity_revived.rs: "Terminal: saveCursor"

/// Upstream test: "Terminal: saveCursor pending wrap state"
#[test]
fn save_cursor_pending_wrap_state() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;5H");
    term.feed(b"A");
    term.feed(b"\x1b7");
    term.feed(b"\x1b[1;1H");
    term.feed(b"B");
    term.feed(b"\x1b8");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "B   A\nX");
}

/// Upstream test: "Terminal: saveCursor resize"
#[test]
fn save_cursor_resize() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[1;10H");
    term.feed(b"\x1b7");
    term.resize(5, 5);
    term.feed(b"\x1b8");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "    X");
}

#[test]
fn saved_cursor_row_is_clamped_after_height_shrink() {
    let mut term = Terminal::new(10, 50);
    term.feed(b"\x1b[43;1H\x1b[s");

    term.resize(10, 22);
    term.feed(b"\x1b[u");

    assert_eq!(term.cursor(), (21, 0));
    term.feed(b"X");
    assert_eq!(term.active_grid().get(21, 0).unwrap().char, 'X');
}

/// Upstream test: "Terminal: saveCursor doesn't modify hyperlink state"
#[test]
fn save_cursor_doesnt_modify_hyperlink_state() {
    let mut term = Terminal::new(3, 3);
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"\x1b7");
    term.feed(b"\x1b8");
    term.feed(b"A");
    let cell = term.active_grid().get(0, 0).unwrap();
    // Hyperlink ids are 1-based, matching upstream.
    assert_eq!(cell.hyperlink, Some(1));
}
