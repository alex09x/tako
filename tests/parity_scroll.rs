// Ported 1:1 from upstream test suite: the upstream `scroll` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: setTopAndBottomMargin simple"
#[test]
fn set_top_and_bottom_margin_simple() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[r");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: setTopAndBottomMargin top only"
#[test]
fn set_top_and_bottom_margin_top_only() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;0r");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "ABC\n\nDEF\nGHI");
}

/// Upstream test: "Terminal: setTopAndBottomMargin top and bottom"
#[test]
fn set_top_and_bottom_margin_top_and_bottom() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[1;2r");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "\nABC\nGHI");
}

/// Upstream test: "Terminal: setTopAndBottomMargin top equal to bottom"
#[test]
fn set_top_and_bottom_margin_top_equal_to_bottom() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2r");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: scrollUp simple"
#[test]
fn scroll_up_simple() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H");
    let (row, col) = term.cursor();
    // upstream: page/viewport internals, not modeled
    term.feed(b"\x1b[1S");
    assert_eq!(term.cursor(), (row, col));
    // upstream: page/viewport internals, not modeled
    assert_eq!(term.plain_string(), "DEF\nGHI");
}

/// Upstream test: "Terminal: scrollUp moves hyperlink"
#[test]
fn scroll_up_moves_hyperlink() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\n");
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"DEF");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\r\nGHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1S");

    assert_eq!(term.plain_string(), "DEF\nGHI");

    for col in 0..3 {
        let cell = term.active_grid().get(0, col).unwrap();
        assert!(cell.hyperlink.is_some());
    }
    for col in 0..3 {
        let cell = term.active_grid().get(1, col).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}

/// Upstream test: "Terminal: scrollUp clears hyperlink"
#[test]
fn scroll_up_clears_hyperlink() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"ABC");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1S");

    assert_eq!(term.plain_string(), "DEF\nGHI");

    for col in 0..3 {
        let cell = term.active_grid().get(0, col).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}

/// Upstream test: "Terminal: scrollUp top/bottom scroll region"
#[test]
fn scroll_up_top_bottom_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;3r");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1S");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "ABC\nGHI");
}

/// Upstream test: "Terminal: scrollUp preserves pending wrap"
#[test]
fn scroll_up_preserves_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;5HA");
    term.feed(b"\x1b[2;5HB");
    term.feed(b"\x1b[3;5HC");
    term.feed(b"\x1b[1S");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "    B\n    C\n\nX");
}

/// Upstream test: "Terminal: scrollUp full top/bottom region"
#[test]
fn scroll_up_full_top_bottom_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"top");
    term.feed(b"\x1b[5;1HABCDE");
    term.feed(b"\x1b[2;5r");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[4S");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "top");
}

/// Upstream test: "Terminal: scrollUp creates scrollback in primary screen"
#[test]
fn scroll_up_creates_scrollback_in_primary_screen() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1S");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "BBBBB\nCCCCC\nDDDDD\nEEEEE");
    // upstream: max_scrollback_bytes and viewport scroll internal API, not modeled
}

/// Upstream test: "Terminal: scrollUp with max_scrollback_bytes zero"
#[test]
fn scroll_up_with_max_scrollback_bytes_zero() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"AAAAA\r\nBBBBB\r\nCCCCC");
    term.feed(b"\x1b[1S");
    assert_eq!(term.plain_string(), "BBBBB\nCCCCC");
    // upstream: max_scrollback_bytes and viewport scroll internal API, not modeled
}

/// Upstream test: "Terminal: scrollUp with max_scrollback_bytes zero and top margin"
#[test]
fn scroll_up_with_max_scrollback_bytes_zero_and_top_margin() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD");
    term.feed(b"\x1b[2;5r");
    term.feed(b"\x1b[1S");
    assert_eq!(term.plain_string(), "AAAAA\nCCCCC\nDDDDD");
}

/// Upstream test: "Terminal: scrollDown simple"
#[test]
fn scroll_down_simple() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H");
    let (row, col) = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    assert_eq!(term.cursor(), (row, col));
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: scrollDown hyperlink moves"
#[test]
fn scroll_down_hyperlink_moves() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"ABC");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1T");

    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");

    for col in 0..3 {
        let cell = term.active_grid().get(1, col).unwrap();
        assert!(cell.hyperlink.is_some());
    }
    for col in 0..3 {
        let cell = term.active_grid().get(0, col).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}

/// Upstream test: "Terminal: scrollDown outside of scroll region"
#[test]
fn scroll_down_outside_of_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[3;4r");
    term.feed(b"\x1b[2;2H");
    let (row, col) = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    assert_eq!(term.cursor(), (row, col));
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "ABC\nDEF\n\nGHI");
}

/// Upstream test: "Terminal: scrollDown preserves pending wrap"
#[test]
fn scroll_down_preserves_pending_wrap() {
    let mut term = Terminal::new(5, 10);
    term.feed(b"\x1b[1;5HA");
    term.feed(b"\x1b[2;5HB");
    term.feed(b"\x1b[3;5HC");
    term.feed(b"\x1b[1T");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "\n    A\n    B\nX   C");
}

/// Upstream test: "Terminal: scrollUp top region no scrollback"
#[test]
fn scroll_up_top_region_no_scrollback() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"A\r\nB\r\nC\r\nD\r\nE");
    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[1S");
    assert_eq!(term.plain_string(), "B\nC\n\nD\nE");
    // upstream: dumpStringAlloc screen internal API, not modeled
}
