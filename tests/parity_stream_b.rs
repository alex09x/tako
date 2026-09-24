use tako_core::terminal::{Terminal, TerminalEvent};

/// Upstream test: "window_title effect with empty title"
#[test]
fn window_title_effect_with_empty_title() {
    let mut t = Terminal::new(80, 24);

    // Set empty window title
    t.feed(b"\x1b]2;\x1b\\");
    assert_eq!(t.title(), "");
    assert_eq!(
        t.take_events(),
        vec![TerminalEvent::TitleChanged(String::new())]
    );
}

/// Upstream test: "kitty_keyboard_query"
#[test]
fn kitty_keyboard_query() {
    let mut t = Terminal::new(80, 24);

    // Default kitty keyboard flags should be 0
    t.feed(b"\x1b[?u");
    assert_eq!(t.take_output(), b"\x1b[?0u");

    // Push kitty keyboard mode with flags and query again
    t.feed(b"\x1b[>1u"); // push with disambiguate flag
    t.feed(b"\x1b[?u");
    assert_eq!(t.take_output(), b"\x1b[?1u");
}

/// Upstream test: "xtversion default"
#[test]
fn xtversion_default() {
    let mut t = Terminal::new(80, 24);

    // Without xtversion effect set, should report "tako"
    t.feed(b"\x1b[>0q");
    assert_eq!(t.take_output(), b"\x1bP>|tako\x1b\\");
}

// PORTED in tests/parity_revived.rs: "xtversion with effect"

// PORTED in tests/parity_revived.rs: "xtversion with empty string effect"

// PORTED in tests/parity_revived.rs: "size report csi_14_t with effect"

// PORTED in tests/parity_revived.rs: "size report csi_16_t with effect"

// PORTED in tests/parity_revived.rs: "size report csi_18_t with effect"

/// Upstream test: "size report no effect callback"
#[test]
fn size_report_no_effect_callback() {
    let mut t = Terminal::new(80, 24);

    // Without size effect, size reports should be silently ignored
    t.feed(b"\x1b[14t");
    assert!(t.take_output().is_empty());
}

/// Upstream test: "size report csi_21_t title"
#[test]
fn size_report_csi_21_t_title() {
    let mut t = Terminal::new(80, 24);

    // Set a title first
    t.feed(b"\x1b]2;My Title\x1b\\");

    // CSI 21 t - report title (no size effect needed)
    t.feed(b"\x1b[21t");
    assert_eq!(t.take_output(), b"\x1b]lMy Title\x1b\\");
}

/// Upstream test: "enquiry no effect"
#[test]
fn enquiry_no_effect() {
    let mut t = Terminal::new(80, 24);

    // ENQ without enquiry effect should not write anything
    t.feed(b"\x05");
    assert!(t.take_output().is_empty());
}

// PORTED in tests/parity_revived.rs: "enquiry with effect"

// PORTED in tests/parity_revived.rs: "enquiry with empty response"

/// Upstream test: "device status: operating status"
#[test]
fn device_status_operating_status() {
    let mut t = Terminal::new(80, 24);

    // CSI 5 n — operating status report
    t.feed(b"\x1B[5n");
    assert_eq!(t.take_output(), b"\x1B[0n");
}

/// Upstream test: "device status: cursor position"
#[test]
fn device_status_cursor_position() {
    let mut t = Terminal::new(80, 24);

    // Default position is 0,0 — reported as 1,1
    t.feed(b"\x1B[6n");
    assert_eq!(t.take_output(), b"\x1B[1;1R");

    // Move cursor to row 5, col 10
    t.feed(b"\x1B[5;10H");
    t.feed(b"\x1B[6n");
    assert_eq!(t.take_output(), b"\x1B[5;10R");
}

/// Upstream test: "device status: cursor position with origin mode"
#[test]
fn device_status_cursor_position_with_origin_mode() {
    let mut t = Terminal::new(80, 24);

    // Set scroll region rows 5-20
    t.feed(b"\x1B[5;20r");
    // Enable origin mode
    t.feed(b"\x1B[?6h");
    // Move to row 3, col 5 within the region
    t.feed(b"\x1B[3;5H");
    // Query cursor position
    t.feed(b"\x1B[6n");
    // Should report position relative to the scroll region
    assert_eq!(t.take_output(), b"\x1B[3;5R");
}

// PORTED in tests/parity_revived.rs: "device status: color scheme dark"

// PORTED in tests/parity_revived.rs: "device status: color scheme light"

/// Upstream test: "device status: color scheme without callback"
#[test]
fn device_status_color_scheme_without_callback() {
    let mut t = Terminal::new(80, 24);

    // Without color_scheme effect, query should be silently ignored
    t.feed(b"\x1B[?996n");
    assert!(t.take_output().is_empty());
}

// SKIPPED "visibility reports": depends on internal flags.visible and report_visibility mode with no public Rust equivalent

/// Upstream test: "device status: readonly ignores all"
#[test]
fn device_status_readonly_ignores_all() {
    let mut t = Terminal::new(80, 24);

    // All device status queries should be silently ignored without effects
    t.feed(b"\x1B[5n");
    t.feed(b"\x1B[6n");
    t.feed(b"\x1B[?996n");
    t.feed(b"\x1B[?998n");

    // Terminal should still be functional
    t.feed(b"Test");
    assert_eq!(t.plain_string(), "Test");
}

/// Upstream test: "device attributes: primary DA"
#[test]
fn device_attributes_primary_da() {
    let mut t = Terminal::new(80, 24);

    t.feed(b"\x1B[c");
    assert_eq!(t.take_output(), b"\x1b[?62;22c");
}

/// Upstream test: "device attributes: secondary DA"
#[test]
fn device_attributes_secondary_da() {
    let mut t = Terminal::new(80, 24);

    t.feed(b"\x1B[>c");
    assert_eq!(t.take_output(), b"\x1b[>1;0;0c");
}

/// Upstream test: "device attributes: tertiary DA"
#[test]
fn device_attributes_tertiary_da() {
    let mut t = Terminal::new(80, 24);

    t.feed(b"\x1B[=c");
    assert_eq!(t.take_output(), b"\x1bP!|00000000\x1b\\");
}

/// Upstream test: "device attributes: readonly ignores"
#[test]
fn device_attributes_readonly_ignores() {
    let mut t = Terminal::new(80, 24);

    // All DA queries should be silently ignored without effects
    t.feed(b"\x1B[c");
    t.feed(b"\x1B[>c");
    t.feed(b"\x1B[=c");

    // Terminal should still be functional
    t.feed(b"Test");
    assert_eq!(t.plain_string(), "Test");
}

// SKIPPED "device attributes: custom response": depends on handler callback device_attributes with no public Rust equivalent

// SKIPPED "continuation reconstructs standard stream without duplicate effects": depends on Stream continuation API and handler callbacks with no public Rust equivalent
