// Ported from the upstream `alt_screen` test suite

use tako_core::terminal::Terminal;

// SKIPPED "Terminal: alternate resize failure replaces active alternate screen": depends on internal memory fault injection and screen fields not exposed by Rust port
// SKIPPED "Terminal: alternate resize replacement failure falls back to primary": depends on internal memory fault injection and screen fields not exposed by Rust port
// PORTED in tests/parity_semantic_prompt.rs: "Terminal: cursorIsAtPrompt alternate screen"

/// Upstream test: "Terminal: mode 47 alt screen plain"
#[test]
fn mode_47_alt_screen_plain() {
    let mut term = Terminal::new(5, 5);

    // Print on primary screen
    term.feed(b"1A");

    // Go to alt screen with mode 47
    term.feed(b"\x1b[?47h");

    // Screen should be empty
    assert_eq!(term.plain_string(), "");

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    term.feed(b"2B");
    assert_eq!(term.plain_string(), "  2B");

    // Go back to primary
    term.feed(b"\x1b[?47l");

    // Primary screen should still have the original content
    assert_eq!(term.plain_string(), "1A");

    // Go back to alt screen with mode 47
    term.feed(b"\x1b[?47h");

    // Screen should retain content
    assert_eq!(term.plain_string(), "  2B");
}

/// Upstream test: "Terminal: mode 1047 alt screen plain"
#[test]
fn mode_1047_alt_screen_plain() {
    let mut term = Terminal::new(5, 5);

    // Print on primary screen
    term.feed(b"1A");

    // Go to alt screen with mode 1047
    term.feed(b"\x1b[?1047h");

    // Screen should be empty
    assert_eq!(term.plain_string(), "");

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    term.feed(b"2B");
    assert_eq!(term.plain_string(), "  2B");

    // Go back to primary
    term.feed(b"\x1b[?1047l");

    // Primary screen should still have the original content
    assert_eq!(term.plain_string(), "1A");

    // Go back to alt screen with mode 1047
    term.feed(b"\x1b[?1047h");

    // Screen should be empty
    assert_eq!(term.plain_string(), "");
}

/// Upstream test: "Terminal: mode 1049 alt screen plain"
#[test]
fn mode_1049_alt_screen_plain() {
    let mut term = Terminal::new(5, 5);

    // Print on primary screen
    term.feed(b"1A");

    // Go to alt screen with mode 1049
    term.feed(b"\x1b[?1049h");

    // Screen should be empty
    assert_eq!(term.plain_string(), "");

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    term.feed(b"2B");
    assert_eq!(term.plain_string(), "  2B");

    // Go back to primary
    term.feed(b"\x1b[?1049l");

    // Primary screen should still have the original content
    assert_eq!(term.plain_string(), "1A");

    // Write, our cursor should be restored back.
    term.feed(b"C");
    assert_eq!(term.plain_string(), "1AC");

    // Go back to alt screen with mode 1049
    term.feed(b"\x1b[?1049h");

    // Screen should be empty
    assert_eq!(term.plain_string(), "");
}
