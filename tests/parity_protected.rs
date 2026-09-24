// Source file: the upstream `protected` test suite

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: eraseChars protected attributes respected with iso"
#[test]
fn erase_chars_protected_attributes_respected_with_iso() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[2X");
    assert_eq!(term.plain_string(), "ABC");
}

/// Upstream test: "Terminal: eraseChars protected attributes ignored with dec most recent"
#[test]
fn erase_chars_protected_attributes_ignored_with_dec_most_recent() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1\"q");
    term.feed(b"\x1b[0\"q");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[2X");
    assert_eq!(term.plain_string(), "  C");
}

/// Upstream test: "Terminal: eraseChars protected attributes ignored with dec set"
#[test]
fn erase_chars_protected_attributes_ignored_with_dec_set() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b[2X");
    assert_eq!(term.plain_string(), "  C");
}

// SKIPPED "Terminal: saveCursor protected pen": depends on t.screens.active.cursor.protected API
// SKIPPED "Terminal: setProtectedMode": depends on t.screens.active.cursor.protected API

/// Upstream test: "Terminal: eraseLine right protected attributes respected with iso"
#[test]
fn erase_line_right_protected_attributes_respected_with_iso() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "ABC");
}

/// Upstream test: "Terminal: eraseLine right protected attributes ignored with dec most recent"
#[test]
fn erase_line_right_protected_attributes_ignored_with_dec_most_recent() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1\"q");
    term.feed(b"\x1b[0\"q");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "A");
}

/// Upstream test: "Terminal: eraseLine right protected attributes ignored with dec set"
#[test]
fn erase_line_right_protected_attributes_ignored_with_dec_set() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "A");
}

/// Upstream test: "Terminal: eraseLine right protected requested"
#[test]
fn erase_line_right_protected_requested() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"12345678");
    term.feed(b"\x1b[1;6H");
    term.feed(b"\x1b[1\"q");
    term.feed(b"X");
    term.feed(b"\x1b[1;4H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[?K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "123  X");
}

/// Upstream test: "Terminal: eraseLine left protected attributes respected with iso"
#[test]
fn erase_line_left_protected_attributes_respected_with_iso() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "ABC");
}

/// Upstream test: "Terminal: eraseLine left protected attributes ignored with dec most recent"
#[test]
fn erase_line_left_protected_attributes_ignored_with_dec_most_recent() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1\"q");
    term.feed(b"\x1b[0\"q");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "  C");
}

/// Upstream test: "Terminal: eraseLine left protected attributes ignored with dec set"
#[test]
fn erase_line_left_protected_attributes_ignored_with_dec_set() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "  C");
}

/// Upstream test: "Terminal: eraseLine left protected requested"
#[test]
fn erase_line_left_protected_requested() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[1;6H");
    term.feed(b"\x1b[1\"q");
    term.feed(b"X");
    term.feed(b"\x1b[1;8H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[?1K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "     X  9");
}

/// Upstream test: "Terminal: eraseLine complete protected attributes respected with iso"
#[test]
fn erase_line_complete_protected_attributes_respected_with_iso() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "ABC");
}

/// Upstream test: "Terminal: eraseLine complete protected attributes ignored with dec most recent"
#[test]
fn erase_line_complete_protected_attributes_ignored_with_dec_most_recent() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\x1b[1\"q");
    term.feed(b"\x1b[0\"q");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "");
}

/// Upstream test: "Terminal: eraseLine complete protected attributes ignored with dec set"
#[test]
fn erase_line_complete_protected_attributes_ignored_with_dec_set() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\x1b[1;2H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[2K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "");
}

/// Upstream test: "Terminal: eraseLine complete protected requested"
#[test]
fn erase_line_complete_protected_requested() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"123456789");
    term.feed(b"\x1b[1;6H");
    term.feed(b"\x1b[1\"q");
    term.feed(b"X");
    term.feed(b"\x1b[1;8H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[?2K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "     X");
}

/// Upstream test: "Terminal: eraseDisplay below protected attributes respected with iso"
#[test]
fn erase_display_below_protected_attributes_respected_with_iso() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[J");
    assert_eq!(term.plain_string(), "ABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: eraseDisplay below protected attributes ignored with dec most recent"
#[test]
fn erase_display_below_protected_attributes_ignored_with_dec_most_recent() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[1\"q");
    term.feed(b"\x1b[0\"q");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[J");
    assert_eq!(term.plain_string(), "ABC\nD");
}

/// Upstream test: "Terminal: eraseDisplay below protected attributes ignored with dec set"
#[test]
fn erase_display_below_protected_attributes_ignored_with_dec_set() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[J");
    assert_eq!(term.plain_string(), "ABC\nD");
}

/// Upstream test: "Terminal: eraseDisplay below protected attributes respected with force"
#[test]
fn erase_display_below_protected_attributes_respected_with_force() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[?J");
    assert_eq!(term.plain_string(), "ABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: eraseDisplay above protected attributes respected with iso"
#[test]
fn erase_display_above_protected_attributes_respected_with_iso() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1J");
    assert_eq!(term.plain_string(), "ABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: eraseDisplay above protected attributes ignored with dec most recent"
#[test]
fn erase_display_above_protected_attributes_ignored_with_dec_most_recent() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1bV");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[1\"q");
    term.feed(b"\x1b[0\"q");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1J");
    assert_eq!(term.plain_string(), "\n  F\nGHI");
}

/// Upstream test: "Terminal: eraseDisplay above protected attributes ignored with dec set"
#[test]
fn erase_display_above_protected_attributes_ignored_with_dec_set() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[1J");
    assert_eq!(term.plain_string(), "\n  F\nGHI");
}

/// Upstream test: "Terminal: eraseDisplay above protected attributes respected with force"
#[test]
fn erase_display_above_protected_attributes_respected_with_force() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1\"q");
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");
    term.feed(b"\x1b[?1J");
    assert_eq!(term.plain_string(), "ABC\nDEF\nGHI");
}

/// Upstream test: "Terminal: eraseDisplay protected complete"
#[test]
fn erase_display_protected_complete() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"A");
    term.feed(b"\r\n");
    term.feed(b"123456789");
    term.feed(b"\x1b[2;6H");
    term.feed(b"\x1b[1\"q");
    term.feed(b"X");
    term.feed(b"\x1b[2;4H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[?2J");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "\n     X");
}

/// Upstream test: "Terminal: eraseDisplay protected below"
#[test]
fn erase_display_protected_below() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"A");
    term.feed(b"\r\n");
    term.feed(b"123456789");
    term.feed(b"\x1b[2;6H");
    term.feed(b"\x1b[1\"q");
    term.feed(b"X");
    term.feed(b"\x1b[2;4H");
    term.feed(b"\x1b[?J");
    assert_eq!(term.plain_string(), "A\n123  X");
}

/// Upstream test: "Terminal: eraseDisplay protected above"
#[test]
fn erase_display_protected_above() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"A");
    term.feed(b"\r\n");
    term.feed(b"123456789");
    term.feed(b"\x1b[2;6H");
    term.feed(b"\x1b[1\"q");
    term.feed(b"X");
    term.feed(b"\x1b[2;8H");
    term.feed(b"\x1b[?1J");
    assert_eq!(term.plain_string(), "\n     X  9");
}
