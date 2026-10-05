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
    assert!(events
        .iter()
        .any(|e| matches!(e, TerminalEvent::ClipboardSet(s) if s == "hello")));
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

#[test]
fn title_sanitization_and_length_clamping() {
    let mut term = Terminal::new(80, 24);

    // Feed OSC 0 with length > 512
    let long_title = "A".repeat(600);
    let seq = format!("\x1b]0;{long_title}\x07");
    term.feed(seq.as_bytes());

    let events = term.take_events();
    let title_event = events
        .iter()
        .find_map(|e| match e {
            TerminalEvent::TitleChanged(t) => Some(t),
            _ => None,
        })
        .expect("title changed event must be emitted");

    assert_eq!(
        title_event.chars().count(),
        512,
        "title must be clamped to 512 chars"
    );

    // Test sanitization rules directly on raw strings containing controls
    let raw = "Safe\x1b[31mTitle\x08With\tTab\x00And\nNewline\u{0085}C1";
    let sanitized = Terminal::sanitize_title(raw);
    assert!(
        !sanitized.contains('\x1b'),
        "C0 control escape must be stripped"
    );
    assert!(!sanitized.contains('\x08'), "C0 backspace must be stripped");
    assert!(!sanitized.contains('\x00'), "C0 null must be stripped");
    assert!(!sanitized.contains('\n'), "newlines must be stripped");
    assert!(
        !sanitized.contains('\u{0085}'),
        "C1 control must be stripped"
    );
    assert!(sanitized.contains('\t'), "tabs should be preserved");
    assert_eq!(sanitized, "Safe[31mTitleWith\tTabAndNewlineC1");
}

#[test]
fn notification_rate_limiting_sliding_window() {
    let mut term = Terminal::new(80, 24);

    // Send 25 notifications immediately
    for i in 0..25 {
        let seq = format!("\x1b]777;notify;Notice {i};Body {i}\x07");
        term.feed(seq.as_bytes());
    }

    let events = term.take_events();
    let notif_count = events
        .iter()
        .filter(|e| matches!(e, TerminalEvent::Notification { .. }))
        .count();

    // Exactly 10 should be allowed by the rate limiter within the 1-second burst window
    assert_eq!(notif_count, 10, "notifications must be limited to 10/sec");
}

#[test]
fn notification_text_sanitization_and_length_clamping() {
    let mut term = Terminal::new(80, 24);

    let huge_title = "T".repeat(200) + "\x1b[31mEvil";
    let huge_body = "B".repeat(2000) + "\x00Null";

    let seq = format!("\x1b]777;notify;{huge_title};{huge_body}\x07");
    term.feed(seq.as_bytes());

    let events = term.take_events();
    let notif = events
        .iter()
        .find_map(|e| match e {
            TerminalEvent::Notification { title, body } => Some((title, body)),
            _ => None,
        })
        .expect("notification event must be emitted");

    assert!(notif.0.chars().count() <= 128, "title clamped to 128");
    assert!(notif.1.chars().count() <= 1024, "body clamped to 1024");
    assert!(!notif.0.contains('\x1b'));
    assert!(!notif.1.contains('\x00'));
}

#[test]
fn status_text_sanitization_and_length_clamping() {
    let mut term = Terminal::new(80, 24);

    let huge_text = "S".repeat(300) + "\x1b[0mInjected";
    let seq = format!("\x1b]9;5;working;{huge_text}\x07");
    term.feed(seq.as_bytes());

    let events = term.take_events();
    let status_event = events
        .iter()
        .find_map(|e| match e {
            TerminalEvent::StatusSet { status, text } => Some((status, text)),
            _ => None,
        })
        .expect("status event must be emitted");

    assert_eq!(status_event.0, "working");
    let text = status_event.1.as_ref().expect("status text present");
    assert!(text.chars().count() <= 256, "status text clamped to 256");
    assert!(!text.contains('\x1b'));
}
