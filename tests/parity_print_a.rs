// Source: the upstream `print_a` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: input with basic wraparound"
#[test]
fn input_with_basic_wraparound() {
    let mut term = Terminal::new(5, 40);
    term.feed(b"helloworldabc12");
    assert_eq!(term.cursor().0, 2);
    assert_eq!(term.cursor().1, 4);
    assert!(term.pending_wrap());
    assert_eq!(term.plain_string(), "hello\nworld\nabc12");
}

/// Upstream test: "Terminal: print single very long line"
#[test]
fn print_single_very_long_line() {
    let mut term = Terminal::new(5, 5);
    term.feed("x".repeat(1000).as_bytes());
}

/// Upstream test: "Terminal: print wide char at edge creates spacer head"
#[test]
fn print_wide_char_at_edge_creates_spacer_head() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b[1;10H");
    term.feed("😀".as_bytes());
    assert_eq!(term.cursor().0, 1);
    assert_eq!(term.cursor().1, 2);

    let cell_head = term.active_grid().get(0, 9).unwrap();
    assert!(cell_head.is_wide_spacer_head);
    assert!(!cell_head.is_wide_spacer);

    let cell_wide = term.active_grid().get(1, 0).unwrap();
    assert_eq!(cell_wide.char, '😀');
    assert!(!cell_wide.is_wide_spacer);

    let cell_tail = term.active_grid().get(1, 1).unwrap();
    assert!(cell_tail.is_wide_spacer);

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print wide char in single-width terminal"
#[test]
fn print_wide_char_in_single_width_terminal() {
    let mut term = Terminal::new(1, 80);
    term.feed("😀".as_bytes());
    assert_eq!(term.cursor().0, 0);
    assert_eq!(term.cursor().1, 0);
    assert!(term.pending_wrap());

    let cell = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell.char, '\0');
    assert!(!cell.is_wide_spacer);

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print over wide char at 0,0"
#[test]
fn print_over_wide_char_at_0_0() {
    let mut term = Terminal::new(80, 80);
    term.feed("😀".as_bytes());
    term.feed(b"\x1b[1;1H");
    term.feed(b"A");

    assert_eq!(term.cursor().0, 0);
    assert_eq!(term.cursor().1, 1);

    let cell0 = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell0.char, 'A');
    assert!(!cell0.is_wide_spacer);

    let cell1 = term.active_grid().get(0, 1).unwrap();
    assert_eq!(cell1.char, '\0');
    assert!(!cell1.is_wide_spacer);

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print over wide char at col 0 corrupts previous row"
#[test]
fn print_over_wide_char_at_col_0_corrupts_previous_row() {
    let mut term = Terminal::new(10, 3);

    for _ in 0..10 {
        term.feed("中".as_bytes());
    }

    term.feed(b"\x1b[2;1H");
    term.feed(b"A");

    let cell_row1_col0 = term.active_grid().get(1, 0).unwrap();
    assert_eq!(cell_row1_col0.char, 'A');
    assert!(!cell_row1_col0.is_wide_spacer);

    let cell_row0_col8 = term.active_grid().get(0, 8).unwrap();
    assert_eq!(cell_row0_col8.char, '中');
    assert!(!cell_row0_col8.is_wide_spacer);

    let cell_row0_col9 = term.active_grid().get(0, 9).unwrap();
    assert!(cell_row0_col9.is_wide_spacer);
}

/// Upstream test: "Terminal: print over wide char with bg color"
#[test]
fn print_over_wide_char_with_bg_color() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed("😀".as_bytes());
    // upstream: style map assert, not modeled

    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[0m");
    term.feed(b"A");

    // upstream: style map assert, not modeled
    // upstream: dirty-tracking assert, not modeled
}

// PORTED in tests/parity_revived.rs: "Terminal: print writes to bottom if scrolled"

// PORTED in tests/parity_revived.rs: "Terminal: print charset"

// PORTED in tests/parity_revived.rs: "Terminal: print charset outside of ASCII"

/// Upstream test: "Terminal: print invoke charset"
#[test]
fn print_invoke_charset() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"\x1b)0");
    term.feed(b"`");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x0e");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"`");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"`");
    term.feed(b"\x0f");
    term.feed(b"`");

    assert_eq!(term.plain_string(), "`◆◆`");
}

// PORTED in tests/parity_revived.rs: "Terminal: print invoke charset single"

/// Upstream test: "Terminal: disabled wraparound with wide char and one space"
#[test]
fn disabled_wraparound_with_wide_char_and_one_space() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[?7l");
    term.feed(b"AAAA");
    term.feed("🚨".as_bytes());

    assert_eq!(term.cursor().0, 0);
    assert_eq!(term.cursor().1, 4);

    assert_eq!(term.plain_string(), "AAAA");

    let cell = term.active_grid().get(0, 4).unwrap();
    assert_eq!(cell.char, '\0');
    assert!(!cell.is_wide_spacer);

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: disabled wraparound with wide char and no space"
#[test]
fn disabled_wraparound_with_wide_char_and_no_space() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[?7l");
    term.feed(b"AAAAA");
    term.feed("🚨".as_bytes());

    assert_eq!(term.cursor().0, 0);
    assert_eq!(term.cursor().1, 4);

    assert_eq!(term.plain_string(), "AAAAA");

    let cell = term.active_grid().get(0, 4).unwrap();
    assert_eq!(cell.char, 'A');
    assert!(!cell.is_wide_spacer);

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print with hyperlink"
#[test]
fn print_with_hyperlink() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"123456");

    for x in 0..6 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.hyperlink, Some(1));
    }

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print over cell with same hyperlink"
#[test]
fn print_over_cell_with_same_hyperlink() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"123456");
    term.feed(b"\x1b[1;1H");
    term.feed(b"123456");

    for x in 0..6 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.hyperlink, Some(1));
    }

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print and end hyperlink"
#[test]
fn print_and_end_hyperlink() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"123");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"456");

    for x in 0..3 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.hyperlink, Some(1));
    }
    for x in 3..6 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.hyperlink, None);
    }

    // upstream: dirty-tracking assert, not modeled
}

/// Upstream test: "Terminal: print and change hyperlink"
#[test]
fn print_and_change_hyperlink() {
    let mut term = Terminal::new(80, 80);

    term.feed(b"\x1b]8;;http://one.example.com\x1b\\");
    term.feed(b"123");
    term.feed(b"\x1b]8;;http://two.example.com\x1b\\");
    term.feed(b"456");

    for x in 0..3 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.hyperlink, Some(1));
    }
    for x in 3..6 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.hyperlink, Some(2));
    }

    // upstream: dirty-tracking assert, not modeled
}
