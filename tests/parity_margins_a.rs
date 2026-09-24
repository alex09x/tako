// Ported from the upstream `margins_a` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: print right margin wrap"
#[test]
fn print_right_margin_wrap() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;5H");
    term.feed(b"XY");

    assert_eq!(term.plain_string(), "1234X6789\n  Y");
    // upstream: row.wrap assertion, internal state not modeled in active_grid
}

/// Upstream test: "Terminal: print right margin wrap dirty tracking"
#[test]
fn print_right_margin_wrap_dirty_tracking() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;5H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"X");
    // upstream: dirty-tracking assert, not modeled

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"Y");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "1234X6789\n  Y");
}

/// Upstream test: "Terminal: print right margin outside"
#[test]
fn print_right_margin_outside() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;6H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"XY");

    assert_eq!(term.plain_string(), "12345XY89");
    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print right margin outside wrap"
#[test]
fn print_right_margin_outside_wrap() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;10H");
    term.feed(b"XY");

    assert_eq!(term.plain_string(), "123456789X\n  Y");
}

/// Upstream test: "Terminal: print wide char at right margin does not create spacer head"
#[test]
fn print_wide_char_at_right_margin_does_not_create_spacer_head() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;5H");
    term.feed("😀".as_bytes());

    assert_eq!(term.cursor(), (1, 4));

    // upstream: dirty-tracking assert, not modeled

    let grid = term.active_grid();
    let cell0 = grid.get(0, 4).unwrap();
    assert_eq!(cell0.char, '\0');
    assert!(!cell0.is_wide_spacer);
    // upstream: row.wrap assertion, internal state not modeled in active_grid

    let cell1 = grid.get(1, 2).unwrap();
    assert_eq!(cell1.char, '😀');
    assert!(!cell1.is_wide_spacer);

    let cell2 = grid.get(1, 3).unwrap();
    assert!(cell2.is_wide_spacer);
}

/// Upstream test: "Terminal: carriage return origin mode moves to left margin"
#[test]
fn carriage_return_origin_mode_moves_to_left_margin() {
    let mut term = Terminal::new(5, 80);
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[?69h\x1b[3;5s");
    // Move cursor x to 0 in origin mode or absolute mode
    term.feed(b"\x1b[?6l\x1b[1;1H\x1b[?6h");
    term.feed(b"\r");
    assert_eq!(term.cursor().1, 2);
}

/// Upstream test: "Terminal: carriage return left of left margin moves to zero"
#[test]
fn carriage_return_left_of_left_margin_moves_to_zero() {
    let mut term = Terminal::new(5, 80);
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\r");
    assert_eq!(term.cursor().1, 0);
}

/// Upstream test: "Terminal: carriage return right of left margin moves to left margin"
#[test]
fn carriage_return_right_of_left_margin_moves_to_left_margin() {
    let mut term = Terminal::new(5, 80);
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[1;4H");
    term.feed(b"\r");
    assert_eq!(term.cursor().1, 2);
}

/// Upstream test: "Terminal: horizontal tabs with right margin"
#[test]
fn horizontal_tabs_with_right_margin() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b[?69h\x1b[3;6s");
    term.feed(b"\x1b[1;1H");
    term.feed(b"X");
    term.feed(b"\t");
    term.feed(b"A");

    assert_eq!(term.plain_string(), "X    A");
}

/// Upstream test: "Terminal: horizontal tabs with left margin in origin mode"
#[test]
fn horizontal_tabs_with_left_margin_in_origin_mode() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[?69h\x1b[3;6s");
    term.feed(b"\x1b[1;2H");
    term.feed(b"X");
    term.feed(b"\x1b[Z");
    term.feed(b"A");

    assert_eq!(term.plain_string(), "  AX");
}

/// Upstream test: "Terminal: horizontal tab back with cursor before left margin"
#[test]
fn horizontal_tab_back_with_cursor_before_left_margin() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b7");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[5;0s");
    term.feed(b"\x1b8");
    term.feed(b"\x1b[Z");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X");
}

/// Upstream test: "Terminal: cursorPos relative to origin with left/right"
#[test]
fn cursor_pos_relative_to_origin_with_left_right() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;4r");
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[1;1H");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "\n\n  X");
}

/// Upstream test: "Terminal: cursorPos limits with full scroll region"
#[test]
fn cursor_pos_limits_with_full_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;4r");
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[500;500H");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "\n\n\n    X");
}

/// Upstream test: "Terminal: setLeftAndRightMargin simple"
#[test]
fn set_left_and_right_margin_simple() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[0;0s");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1X");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), " BC\nDEF\nGHI");
}

/// Upstream test: "Terminal: setLeftAndRightMargin left only"
#[test]
fn set_left_and_right_margin_left_only() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;0s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A\nDBC\nGEF\n HI");
}

/// Upstream test: "Terminal: setLeftAndRightMargin left and right"
#[test]
fn set_left_and_right_margin_left_and_right() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[1;2s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "  C\nABF\nDEI\nGH");
}

/// Upstream test: "Terminal: setLeftAndRightMargin left equal right"
#[test]
fn set_left_and_right_margin_left_equal_right() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;2s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: setLeftAndRightMargin mode 69 unset"
#[test]
fn set_left_and_right_margin_mode_69_unset() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[?69l");
    term.feed(b"\x1b[1;2s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\nABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: insertLines left/right scroll region"
#[test]
fn insert_lines_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1L");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC123\nD   56\nGEF489\n HI7");
}

/// Upstream test: "Terminal: scrollUp left/right scroll region"
#[test]
fn scroll_up_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    let cursor = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1S");
    assert_eq!(cursor, term.cursor());

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "AEF423\nDHI756\nG   89");
}

/// Upstream test: "Terminal: scrollUp left/right scroll region hyperlink"
#[test]
fn scroll_up_left_right_scroll_region_hyperlink() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\n");
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"DEF456");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1S");

    assert_eq!(term.plain_string(), "AEF423\nDHI756\nG   89");

    let grid = term.active_grid();
    for x in 0..1 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 1..4 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 4..6 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }

    for x in 0..1 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 1..4 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 4..6 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
}

/// Upstream test: "Terminal: scrollUp full top/bottomleft/right scroll region"
#[test]
fn scroll_up_full_top_bottomleft_right_scroll_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"top");
    term.feed(b"\x1b[5;1H");
    term.feed(b"ABCDE");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;5r");
    term.feed(b"\x1b[2;4s");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[4S");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "top\n\n\n\nA   E");
}

/// Upstream test: "Terminal: scrollUp with max_scrollback_bytes zero and left/right margin"
#[test]
fn scroll_up_with_max_scrollback_bytes_zero_and_left_right_margin() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"AAAAABBBBB\r\nCCCCCDDDDD\r\nEEEEEFFFFF");
    term.feed(b"\x1b[?69h\x1b[2;6s");

    term.feed(b"\x1b[1S");

    assert_eq!(term.plain_string(), "ACCCCDBBBB\nCEEEEFDDDD\nE     FFFF");
}

/// Upstream test: "Terminal: scrollDown left/right scroll region"
#[test]
fn scroll_down_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    let cursor = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    assert_eq!(cursor, term.cursor());

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A   23\nDBC156\nGEF489\n HI7");
}

/// Upstream test: "Terminal: scrollDown left/right scroll region hyperlink"
#[test]
fn scroll_down_left_right_scroll_region_hyperlink() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"ABC123");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1T");

    assert_eq!(term.plain_string(), "A   23\nDBC156\nGEF489\n HI7");

    let grid = term.active_grid();
    for x in 0..1 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 1..4 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 4..6 {
        let cell = grid.get(0, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }

    for x in 0..1 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
    for x in 1..4 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_some());
        // upstream: hyperlink internals assert, not modeled
    }
    for x in 4..6 {
        let cell = grid.get(1, x).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}

/// Upstream test: "Terminal: scrollDown outside of left/right scroll region"
#[test]
fn scroll_down_outside_of_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[1;1H");

    let cursor = term.cursor();
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1T");
    assert_eq!(cursor, term.cursor());

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A   23\nDBC156\nGEF489\n HI7");
}

/// Upstream test: "Terminal: reverseIndex left/right margins"
#[test]
fn reverse_index_left_right_margins() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\x1b[2;1H");
    term.feed(b"DEF");
    term.feed(b"\x1b[3;1H");
    term.feed(b"GHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;3s");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1bM");

    assert_eq!(term.plain_string(), "A\nDBC\nGEF\n HI");
}
