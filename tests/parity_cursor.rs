// Ported from the upstream `cursor` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: setCursorPos saturates overflowing origin offsets"
#[test]
fn set_cursor_pos_saturates_overflowing_origin_offsets() {
    let mut term = Terminal::new(10, 10);
    // Upstream 0-based region top=2/bottom=7/left=3/right=8 -> 1-based
    // DECSTBM 3;8 and DECSLRM 4;9 (behind mode 69).
    term.feed(b"\x1b[3;8r");
    term.feed(b"\x1b[?69h\x1b[4;9s");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[999999;999999H");
    assert_eq!(term.cursor(), (7, 8));
}

/// Upstream test: "Terminal: cursorPos resets wrap"
#[test]
fn cursor_pos_resets_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1;1H");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "XBCDE");
}

/// Upstream test: "Terminal: cursorPos off the screen"
#[test]
fn cursor_pos_off_the_screen() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[500;500H");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "\n\n\n\n    X");
}

/// Upstream test: "Terminal: cursorPos relative to origin"
#[test]
fn cursor_pos_relative_to_origin() {
    let mut term = Terminal::new(5, 5);
    // Upstream assigns 0-based fields top=2/bottom=3 -> 1-based CSI 3;4r.
    term.feed(b"\x1b[3;4r");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[1;1H");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "\n\nX");
}

/// Upstream test: "Terminal: setCursorPos (original test)"
#[test]
fn set_cursor_pos_original_test() {
    let mut term = Terminal::new(80, 80);
    assert_eq!(term.cursor(), (0, 0));

    // Setting it to 0 should keep it zero (1 based)
    term.feed(b"\x1b[0;0H");
    assert_eq!(term.cursor(), (0, 0));

    // Should clamp to size
    term.feed(b"\x1b[81;81H");
    assert_eq!(term.cursor(), (79, 79));

    // Should reset pending wrap
    term.feed(b"\x1b[1;80H");
    term.feed(b"c");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1;80H");
    assert!(!term.pending_wrap());

    // Origin mode
    term.feed(b"\x1b[?6h");

    // No change without a scroll region
    term.feed(b"\x1b[81;81H");
    assert_eq!(term.cursor(), (79, 79));

    // Set the scroll region
    term.feed(b"\x1b[10;80r");
    term.feed(b"\x1b[0;0H");
    assert_eq!(term.cursor(), (9, 0));

    term.feed(b"\x1b[1;1H");
    assert_eq!(term.cursor(), (9, 0));

    term.feed(b"\x1b[100;0H");
    assert_eq!(term.cursor(), (79, 0));

    term.feed(b"\x1b[10;11r");
    term.feed(b"\x1b[2;0H");
    assert_eq!(term.cursor(), (10, 0));
}

/// Upstream test: "Terminal: cursorUp basic"
#[test]
fn cursor_up_basic() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;1HA");
    term.feed(b"\x1b[10A");
    term.feed(b"X");
    assert_eq!(term.plain_string(), " X\n\nA");
}

/// Upstream test: "Terminal: cursorUp below top scroll margin"
#[test]
fn cursor_up_below_top_scroll_margin() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[2;4r");
    term.feed(b"\x1b[3;1HA");
    term.feed(b"\x1b[5A");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "\n X\nA");
}

/// Upstream test: "Terminal: cursorUp above top scroll margin"
#[test]
fn cursor_up_above_top_scroll_margin() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;5r");
    term.feed(b"\x1b[3;1HA");
    term.feed(b"\x1b[2;1H");
    term.feed(b"\x1b[10A");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "X\n\nA");
}

/// Upstream test: "Terminal: cursorUp resets wrap"
#[test]
fn cursor_up_resets_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1A");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDX");
}

/// Upstream test: "Terminal: cursorLeft no wrap"
#[test]
fn cursor_left_no_wrap() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"A\r\nB");
    term.feed(b"\x1b[10D");
    assert_eq!(term.plain_string(), "A\nB");
}

/// Upstream test: "Terminal: cursorLeft unsets pending wrap state"
#[test]
fn cursor_left_unsets_pending_wrap_state() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1D");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCXE");
}

/// Upstream test: "Terminal: cursorLeft unsets pending wrap state with longer jump"
#[test]
fn cursor_left_unsets_pending_wrap_state_with_longer_jump() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[3D");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "AXCDE");
}

/// Upstream test: "Terminal: cursorDown basic"
#[test]
fn cursor_down_basic() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"A");
    term.feed(b"\x1b[10B");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "A\n\n\n\n X");
}

/// Upstream test: "Terminal: cursorDown above bottom scroll margin"
#[test]
fn cursor_down_above_bottom_scroll_margin() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;3r");
    term.feed(b"A");
    term.feed(b"\x1b[10B");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "A\n\n X");
}

/// Upstream test: "Terminal: cursorDown below bottom scroll margin"
#[test]
fn cursor_down_below_bottom_scroll_margin() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;3r");
    term.feed(b"A");
    term.feed(b"\x1b[4;1H");
    term.feed(b"\x1b[10B");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "A\n\n\n\nX");
}

/// Upstream test: "Terminal: cursorDown resets wrap"
#[test]
fn cursor_down_resets_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1B");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDE\n    X");
}

/// Upstream test: "Terminal: cursorRight resets wrap"
#[test]
fn cursor_right_resets_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[1C");
    assert!(!term.pending_wrap());
    term.feed(b"X");
    assert_eq!(term.plain_string(), "ABCDX");
}

/// Upstream test: "Terminal: cursorRight to the edge of screen"
#[test]
fn cursor_right_to_the_edge_of_screen() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[100C");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "    X");
}

/// Upstream test: "Terminal: saveCursor position"
#[test]
fn save_cursor_position() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[1;5HA");
    term.feed(b"\x1b7");
    term.feed(b"\x1b[1;1HB");
    term.feed(b"\x1b8");
    term.feed(b"X");
    assert_eq!(term.plain_string(), "B   AX");
}
