/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::{ClipboardPolicy, Terminal, TerminalEvent};

#[test]
fn default_clipboard_policy_is_write_only_and_drops_query() {
    let mut term = Terminal::new(80, 24);
    assert_eq!(term.clipboard_policy(), ClipboardPolicy::WriteOnly);

    // Query should be dropped by default
    term.feed(b"\x1b]52;c;?\x07");
    let events = term.take_events();
    assert!(!events.contains(&TerminalEvent::ClipboardQuery));

    // Write should be allowed by default
    term.feed(b"\x1b]52;c;aGVsbG8=\x07"); // "hello" in base64
    let events = term.take_events();
    assert!(
        events
            .iter()
            .any(|e| matches!(e, TerminalEvent::ClipboardSet(s) if s == "hello"))
    );
}

#[test]
fn clipboard_read_write_allows_query() {
    let mut term = Terminal::new(80, 24);
    term.set_clipboard_policy(ClipboardPolicy::ReadWrite);
    assert_eq!(term.clipboard_policy(), ClipboardPolicy::ReadWrite);

    term.feed(b"\x1b]52;c;?\x07");
    let events = term.take_events();
    assert!(events.contains(&TerminalEvent::ClipboardQuery));
}

#[test]
fn clipboard_disabled_suppresses_both_read_and_write() {
    let mut term = Terminal::new(80, 24);
    term.set_clipboard_policy(ClipboardPolicy::Disabled);

    term.feed(b"\x1b]52;c;?\x07");
    term.feed(b"\x1b]52;c;aGVsbG8=\x07");
    term.feed(b"\x1b]1337;Copy=:aGVsbG8=\x07");

    let events = term.take_events();
    assert!(events.is_empty());
}

#[test]
fn clipboard_write_payload_size_limit() {
    let mut term = Terminal::new(80, 24);

    // Create a payload > 1 MiB decoded
    let large_data = vec![b'A'; 1024 * 1024 + 10];
    use base64::Engine as _;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&large_data);
    let seq = format!("\x1b]52;c;{b64}\x07");
    term.feed(seq.as_bytes());

    let events = term.take_events();
    assert!(
        events.is_empty(),
        "oversized clipboard writes must be rejected"
    );
}
