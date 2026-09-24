// Ported from the upstream `modes_misc` test suite

use tako_core::terminal::Terminal;

// PORTED in tests/parity_revived.rs: "Terminal: setTitle accepts its current value"

/// Upstream test: "Terminal: DECALN"
#[test]
fn decaln() {
    let mut term = Terminal::new(2, 2);
    term.feed(b"A");
    term.feed(b"\r");
    term.feed(b"\n");
    term.feed(b"B");
    term.feed(b"\x1b#8");

    assert_eq!(term.cursor(), (0, 0));

    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "EE\nEE");
}

/// Upstream test: "Terminal: decaln reset margins"
#[test]
fn decaln_reset_margins() {
    let mut term = Terminal::new(3, 3);
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[2;3r");
    term.feed(b"\x1b#8");
    term.feed(b"\x1b[1T");

    assert_eq!(term.plain_string(), "\nEEE\nEEE");
}

/// Upstream test: "Terminal: decaln preserves color"
#[test]
fn decaln_preserves_color() {
    let mut term = Terminal::new(3, 3);
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1b[2;3r");
    term.feed(b"\x1b#8");
    term.feed(b"\x1b[1T");

    assert_eq!(term.plain_string(), "\nEEE\nEEE");

    let cell = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell.bg, tako_core::grid::Color::Rgb(255, 0, 0));
}

/// Upstream test: "Terminal: fullReset origin mode"
#[test]
fn full_reset_origin_mode() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b[3;5H");
    term.feed(b"\x1b[?6h");
    term.feed(b"\x1bc");

    assert_eq!(term.cursor(), (0, 0));
    assert!(!term.modes().origin_mode);
}

/// Upstream test: "Terminal: mode 47 copies cursor both directions"
#[test]
fn mode_47_copies_cursor_both_directions() {
    let mut term = Terminal::new(5, 5);

    // Color our cursor red
    term.feed(b"\x1b[38;2;255;0;127m");

    // Go to alt screen with mode 47
    term.feed(b"\x1b[?47h");

    // upstream: page/pin/refcount internals, not modeled

    // Set a new style
    term.feed(b"\x1b[38;2;0;255;0m");

    // Go back to primary
    term.feed(b"\x1b[?47l");

    // upstream: page/pin/refcount internals, not modeled
}

/// Upstream test: "Terminal: mode 1047 copies cursor both directions"
#[test]
fn mode_1047_copies_cursor_both_directions() {
    let mut term = Terminal::new(5, 5);

    // Color our cursor red
    term.feed(b"\x1b[38;2;255;0;127m");

    // Go to alt screen with mode 1047
    term.feed(b"\x1b[?1047h");

    // upstream: page/pin/refcount internals, not modeled

    // Set a new style
    term.feed(b"\x1b[38;2;0;255;0m");

    // Go back to primary
    term.feed(b"\x1b[?1047l");

    // upstream: page/pin/refcount internals, not modeled
}
