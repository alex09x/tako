// Upstream tests ported from the upstream `margins_b` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: reverseIndex outside left/right margins"
#[test]
fn reverse_index_outside_left_right_margins() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"ABC");
    term.feed(b"\x1b[2;1H");
    term.feed(b"DEF");
    term.feed(b"\x1b[3;1H");
    term.feed(b"GHI");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;3s");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1bM");

    assert_eq!(term.plain_string(), "ABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: index outside left/right margin"
#[test]
fn index_outside_left_right_margin() {
    let mut term = Terminal::new(10, 5);

    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[?69h\x1b[4;6s");
    term.feed(b"\x1b[3;3H");
    term.feed(b"A");
    term.feed(b"\x1b[3;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"X");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\n\nX A");
}

/// Upstream test: "Terminal: index inside left/right margin"
#[test]
fn index_inside_left_right_margin() {
    let mut term = Terminal::new(10, 5);

    term.feed(b"AAAAAA\r\nAAAAAA\r\nAAAAAA");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[1;3s");
    term.feed(b"\x1b[3;1H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.cursor(), (2, 0));
    assert_eq!(term.plain_string(), "AAAAAA\nAAAAAA\n   AAA");
}

/// Upstream test: "Terminal: cursorLeft reverse wrap before left margin"
#[test]
fn cursor_left_reverse_wrap_before_left_margin() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[?7h");
    term.feed(b"\x1b[?45h");
    term.feed(b"\x1b[3;0r");
    term.feed(b"\x1b[1D");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "\n\nX");
}

/// Upstream test: "Terminal: cursorRight left of right margin"
#[test]
fn cursor_right_left_of_right_margin() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[?69h\x1b[1;3s");
    term.feed(b"\x1b[100C");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "  X");
}

/// Upstream test: "Terminal: cursorRight right of right margin"
#[test]
fn cursor_right_right_of_right_margin() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[?69h\x1b[1;3s");
    term.feed(b"\x1b[1;4H");
    term.feed(b"\x1b[100C");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "    X");
}

/// Upstream test: "Terminal: deleteLines left/right scroll region"
#[test]
fn delete_lines_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);

    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1M");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC123\nDHI756\nG   89");
}

/// Upstream test: "Terminal: deleteLines left/right scroll region from top"
#[test]
fn delete_lines_left_right_scroll_region_from_top() {
    let mut term = Terminal::new(10, 10);

    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[1;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1M");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "AEF423\nDHI756\nG   89");
}

/// Upstream test: "Terminal: deleteLines left/right scroll region high count"
#[test]
fn delete_lines_left_right_scroll_region_high_count() {
    let mut term = Terminal::new(10, 10);

    term.feed(b"ABC123\r\nDEF456\r\nGHI789");
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[100M");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC123\nD   56\nG   89");
}

// PORTED in tests/parity_spacer_head_margins.rs: "Terminal: deleteLines wide character spacer head left scroll margin"

/// Upstream test: "Terminal: deleteLines wide characters split by left/right scroll region boundaries"
#[test]
fn delete_lines_wide_characters_split_by_left_right_scroll_region_boundaries() {
    let mut term = Terminal::new(5, 2);

    // Upstream printString treats \n as CR+LF.
    term.feed("AAAAA\r\n\u{1F600}B\u{1F600}".as_bytes());
    term.feed(b"\x1b[?69h\x1b[2;4s");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[1M");

    assert_eq!(term.plain_string(), "A B A");
}

/// Upstream test: "Terminal: insertBlanks inside left/right scroll region"
#[test]
fn insert_blanks_inside_left_right_scroll_region() {
    let mut term = Terminal::new(10, 10);

    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[1;3H");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;3H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2@");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"X");

    assert_eq!(term.plain_string(), "  X A");
}

// SKIPPED "Terminal: insertBlanks outside left/right scroll region": upstream assigns margin fields directly
// without homing; the wire form (DECSLRM) homes the cursor and clears the
// deferred wrap, changing the scenario -- untranslatable via escape sequences.

/// Upstream test: "Terminal: insertBlanks left/right scroll region large count"
#[test]
fn insert_blanks_left_right_scroll_region_large_count() {
    let mut term = Terminal::new(10, 10);

    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[1;1H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[140@");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"X");

    assert_eq!(term.plain_string(), "  X");
}

/// Upstream test: "Terminal: insertBlanks wide char straddling right margin"
#[test]
fn insert_blanks_wide_char_straddling_right_margin() {
    let mut term = Terminal::new(10, 5);

    term.feed(b"\x1b[1;1H");
    term.feed(b"ABCD");
    term.feed("橋".as_bytes());

    term.feed(b"\x1b[?69h\x1b[1;5s");

    term.feed(b"\x1b[1;3H");
    term.feed(b"\x1b[1@");

    assert_eq!(term.plain_string(), "AB CD");
}

/// Upstream test: "Terminal: insertBlanks wide char spacer_tail orphaned beyond right margin"
#[test]
fn insert_blanks_wide_char_spacer_tail_orphaned_beyond_right_margin() {
    let mut term = Terminal::new(10, 5);

    for _ in 0..5 {
        term.feed("中".as_bytes());
    }

    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[1;9s");

    term.feed(b"a");

    term.feed(b"\x1b[8@");

    assert_eq!(term.plain_string(), "a");
}

// SKIPPED "Terminal: deleteChars outside scroll region": upstream assigns margin fields directly
// without homing; the wire form (DECSLRM) homes the cursor and clears the
// deferred wrap, changing the scenario -- untranslatable via escape sequences.

/// Upstream test: "Terminal: deleteChars inside scroll region"
#[test]
fn delete_chars_inside_scroll_region() {
    let mut term = Terminal::new(6, 10);

    term.feed(b"ABC123");
    term.feed(b"\x1b[?69h\x1b[3;5s");
    term.feed(b"\x1b[1;4H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1P");

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC2 3");
}

/// Upstream test: "Terminal: deleteChars wide char across right margin"
#[test]
fn delete_chars_wide_char_across_right_margin() {
    let mut term = Terminal::new(8, 3);

    term.feed("123456橋".as_bytes());
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[2;7s");

    assert_eq!(term.plain_string(), "123456橋");

    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[1P");
    // upstream: page integrity assert, not modeled

    assert_eq!(term.plain_string(), "13456");
}

/// Upstream test: "Terminal: saveCursor origin mode"
#[test]
fn save_cursor_origin_mode() {
    let mut term = Terminal::new(10, 5);

    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b7");
    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[3;5s");
    term.feed(b"\x1b[2;4r");
    term.feed(b"\x1b8");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "X");
}

// SKIPPED "Terminal: resize with left and right margin set": resize and modes.restore internal APIs not modeled
// SKIPPED "Terminal: DECCOLM resets scroll region": deccolm and direct scrolling_region field accessors not implemented

/// Upstream test: "Terminal: deleteLines wide char at right margin with full clear"
#[test]
fn delete_lines_wide_char_at_right_margin_with_full_clear() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x1b[10;39H");
    term.feed("中".as_bytes());

    term.feed(b"\x1b[?69h");
    term.feed(b"\x1b[5;39s");

    term.feed(b"\x1b[24S");
}
