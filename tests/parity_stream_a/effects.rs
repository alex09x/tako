/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::{Terminal, TerminalEvent};

/// Upstream test: "bell effect callback"
#[test]
fn bell_effect_callback() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x07");
    assert_eq!(term.take_events(), vec![TerminalEvent::Bell]);

    term.feed(b"AfterBell");
    assert_eq!(term.plain_string(), "AfterBell");

    term.feed(b"\x07");
    assert_eq!(term.take_events(), vec![TerminalEvent::Bell]);

    term.feed(b"\x07\x07");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::Bell, TerminalEvent::Bell]
    );
}

/// Upstream test: "desktop_notification effect callback"
#[test]
fn desktop_notification_effect_callback() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x1b]9;Ignored\x1b\\AfterNotification");
    assert_eq!(term.plain_string(), "AfterNotification");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::Notification {
            title: String::new(),
            body: "Ignored".to_string(),
        }]
    );

    term.feed(b"\x1b]9;Build ");
    assert!(term.take_events().is_empty());
    term.feed(b"complete\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::Notification {
            title: String::new(),
            body: "Build complete".to_string(),
        }]
    );

    term.feed(b"\x1b]777;notify;Codex;Needs attention\x07");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::Notification {
            title: "Codex".to_string(),
            body: "Needs attention".to_string(),
        }]
    );
}

// PORTED in tests/parity_revived.rs: "progress_report effect callback"

/// Upstream test: "clipboard_write effect callback"
#[test]
fn clipboard_write_effect_callback() {
    let mut term = Terminal::new(80, 24);
    term.set_clipboard_policy(tako_core::terminal::ClipboardPolicy::ReadWrite);

    term.feed(b"\x1b]52;c;aGVsbG8=\x1b\\");
    term.feed(b"AfterClipboard");
    assert_eq!(term.plain_string(), "AfterClipboard");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet("hello".to_string())]
    );

    term.feed(b"\x1b]52;s;d29ybGQ=\x07");
    term.feed(b"\x1b]52;p;cHJpbWFyeQ==\x1b\\");
    term.feed(b"\x1b]52;0;Y3V0\x1b\\");
    term.feed(b"\x1b]52;x;ZmFsbGJhY2s=\x1b\\");
    term.feed(b"\x1b]52;c;YQBi\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![
            TerminalEvent::ClipboardSet("world".to_string()),
            TerminalEvent::ClipboardSet("primary".to_string()),
            TerminalEvent::ClipboardSet("cut".to_string()),
            TerminalEvent::ClipboardSet("fallback".to_string()),
            TerminalEvent::ClipboardSet("a\0b".to_string()),
        ]
    );

    term.feed(b"\x1b]52;s;\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet(String::new())]
    );

    term.feed(b"\x1b]52;c;?\x1b\\");
    term.feed(b"\x1b]52;c;***\x1b\\");
    assert_eq!(term.take_events(), vec![TerminalEvent::ClipboardQuery]);

    term.feed(b"\x1b]1337;Copy=:aVRlcm0y\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet("iTerm2".to_string())]
    );

    term.feed(b"\x1b]52;p;ZnJh");
    term.feed(b"Z21lbnRlZA==\x1b");
    term.feed(b"\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet("fragmented".to_string())]
    );
}

// SKIPPED "clipboard_write allocation failure is ignored": custom allocator injection unsupported in Rust port

/// Upstream test: "request mode DECRQM with write_pty callback"
#[test]
fn request_mode_decrqm_with_write_pty_callback() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x1b[?7$p");
    assert_eq!(term.take_output(), b"\x1b[?7;1$y");

    term.feed(b"\x1b[?7l");
    term.feed(b"\x1b[?7$p");
    assert_eq!(term.take_output(), b"\x1b[?7;2$y");

    term.feed(b"\x1b[?9999$p");
    assert_eq!(term.take_output(), b"\x1b[?9999;0$y");
}

/// Upstream test: "stream: CSI W with intermediate but no params"
#[test]
fn stream_csi_w_with_intermediate_but_no_params() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[?W");
}

/// Upstream test: "window_title effect is called"
#[test]
fn window_title_effect_is_called() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]2;Hello World\x1b\\");
    assert_eq!(term.title(), "Hello World");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::TitleChanged("Hello World".to_string())]
    );
}

/// Upstream test: "window_title effect not called without callback"
#[test]
fn window_title_effect_not_called_without_callback() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]2;Hello World\x1b\\");
    assert_eq!(term.title(), "Hello World");

    term.feed(b"Test");
    assert_eq!(term.plain_string(), "Test");
}
