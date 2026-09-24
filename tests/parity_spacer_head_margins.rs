// 1:1 ports of the four upstream spacer_head x margins tests
// (upstream `Terminal` "deleteLines wide character spacer head ..."), unblocked
// by is_wide_spacer_head + plain_string_unwrapped().
//
// Upstream sets scrolling_region fields directly (0-based); over the wire
// that is DECLRMM (?69h) + DECSLRM with 1-based values. DECSLRM homes the
// cursor, so the explicit setCursorPos that follows in each upstream test
// still determines the final position.

use tako_core::terminal::Terminal;

fn setup() -> Terminal {
    let mut term = Terminal::new(5, 3);
    // "AAAAA" fills row 0 (wrapped), "BBBB" + a wide glyph that cannot fit
    // leaves a spacer head, wide char lands on row 2 with "CCC".
    term.feed("AAAAABBBB\u{1F600}CCC".as_bytes());
    term
}

/// Upstream test: "Terminal: deleteLines wide character spacer head left scroll margin"
#[test]
fn delete_lines_spacer_head_left_scroll_margin() {
    let mut term = setup();
    term.feed(b"\x1b[?69h\x1b[3;5s"); // left = 2 (0-based) -> 1-based 3, right = full
    term.feed(b"\x1b[1;3H");
    term.feed(b"\x1b[1M");
    assert_eq!(term.plain_string(), "AABB\nBBCCC\n\u{1F600}");
    assert_eq!(term.plain_string_unwrapped(), "AABB BBCCC\u{1F600}");
}

/// Upstream test: "Terminal: deleteLines wide character spacer head right scroll margin"
#[test]
fn delete_lines_spacer_head_right_scroll_margin() {
    let mut term = setup();
    term.feed(b"\x1b[?69h\x1b[1;4s"); // right = 3 (0-based) -> 1-based 4
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[1M");
    assert_eq!(term.plain_string(), "BBBBA\n\u{1F600}CC\n    C");
    assert_eq!(term.plain_string_unwrapped(), "BBBBA\u{1F600}CC     C");
}

/// Upstream test: "Terminal: deleteLines wide character spacer head left and right scroll margin"
#[test]
fn delete_lines_spacer_head_left_and_right_scroll_margin() {
    let mut term = setup();
    term.feed(b"\x1b[?69h\x1b[3;4s"); // left = 2, right = 3 (0-based)
    term.feed(b"\x1b[1;3H");
    term.feed(b"\x1b[1M");
    assert_eq!(term.plain_string(), "AABBA\nBBCC\n\u{1F600}  C");
    assert_eq!(term.plain_string_unwrapped(), "AABBABBCC\u{1F600}  C");
}

/// Upstream test: "Terminal: deleteLines wide character spacer head left (< 2) and right scroll margin"
#[test]
fn delete_lines_spacer_head_left_lt2_and_right_scroll_margin() {
    let mut term = setup();
    term.feed(b"\x1b[?69h\x1b[2;4s"); // left = 1, right = 3 (0-based)
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[1M");
    assert_eq!(term.plain_string(), "ABBBA\nB CC\n    C");
    assert_eq!(term.plain_string_unwrapped(), "ABBBAB CC     C");
}
