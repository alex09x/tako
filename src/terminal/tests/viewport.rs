/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::terminal::{Terminal, TerminalEvent};

#[test]
fn viewport_stays_at_bottom_after_large_output() {
    let mut term = Terminal::new(80, 24);
    // Feed 100 lines — well beyond screen height — to build scrollback.
    for i in 0..100u32 {
        term.feed(format!("line {}\r\n", i).as_bytes());
    }
    // viewport_offset 0 means "live screen bottom"; it must never drift up
    // on its own while PTY data arrives.
    assert_eq!(term.viewport_offset(), 0);
}

#[test]
fn scroll_viewport_bottom_is_noop_when_already_at_zero() {
    let mut term = Terminal::new(80, 24);
    for _ in 0..50 {
        term.feed(b"line\r\n");
    }
    // Already at bottom.
    assert_eq!(term.viewport_offset(), 0);
    term.take_damage(); // drain damage flags

    // Calling scroll_viewport_bottom when already at offset 0 must NOT
    // mark rows dirty (it would force a full redraw on every PTY batch).
    term.scroll_viewport_bottom();
    assert_eq!(term.viewport_offset(), 0);
    assert!(
        term.take_damage().is_empty(),
        "spurious full-redraw triggered"
    );
}

#[test]
fn scroll_viewport_bottom_snaps_from_scrolled_position() {
    let mut term = Terminal::new(80, 24);
    // Build at least 10 lines of scrollback.
    for _ in 0..40 {
        term.feed(b"line\r\n");
    }
    term.scroll_viewport_up(10);
    assert_eq!(term.viewport_offset(), 10);
    term.take_damage(); // drain

    term.scroll_viewport_bottom();
    assert_eq!(term.viewport_offset(), 0);
    // After actually moving the viewport, all rows must be re-rendered.
    assert!(
        !term.take_damage().is_empty(),
        "no damage reported after viewport snap"
    );
}

#[test]
fn prompt_visible_after_cat_like_output() {
    // Simulate: shell prompt → user runs cat on a 66-line file → new prompt.
    // After the cat output, scroll_viewport_bottom should leave the live
    // screen visible so the shell prompt is on-screen without user action.
    let mut term = Terminal::new(80, 24);

    // Initial prompt.
    term.feed(b"$ ");

    // 66 lines of cat output (simulating cat backend_prompt.md).
    for i in 0..66u32 {
        term.feed(format!("output line {}\r\n", i).as_bytes());
    }

    // New prompt after command exits.
    term.feed(b"$ ");

    // The terminal is at the live screen bottom — prompt is on row 23
    // (or wherever the cursor landed). scroll_viewport_bottom is a no-op.
    assert_eq!(term.viewport_offset(), 0);

    // The cursor must be on the last live screen row (bottom area), not
    // stuck at the top because 66 lines scrolled past.
    let (row, _col) = term.cursor();
    assert!(row > 0, "cursor never moved after 66 lines of output");
}

#[test]
fn viewport_scrolled_up_then_new_output_snaps_back() {
    // User scrolls back in history while a command is running, then the
    // command finishes and the host calls scroll_viewport_bottom (which our
    // Swift PTY-read loop now does on every damage batch).
    let mut term = Terminal::new(80, 24);
    for _ in 0..50 {
        term.feed(b"history line\r\n");
    }
    // User scrolled up 15 lines.
    term.scroll_viewport_up(15);
    assert_eq!(term.viewport_offset(), 15);

    // New PTY data arrives (command output + prompt).
    term.feed(b"command output\r\n$ ");
    // Host calls scroll_viewport_bottom (done in the Swift PTY read loop).
    term.scroll_viewport_bottom();

    assert_eq!(
        term.viewport_offset(),
        0,
        "viewport must snap to live screen"
    );

    // The prompt text must be on the live screen.
    let live_rows: Vec<String> = (0..term.active_grid().rows())
        .map(|r| {
            term.viewport_row(r)
                .iter()
                .map(|c| if c.char == '\0' { ' ' } else { c.char })
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect();
    let screen = live_rows.join("\n");
    assert!(
        screen.contains("command output"),
        "command output missing from live screen"
    );
    assert!(screen.contains('$'), "prompt missing from live screen");
}

#[test]
fn has_damage_reflects_synchronized_output_state() {
    let mut term = Terminal::new(80, 24);
    term.take_damage(); // clear initial damage

    // Open a Synchronized Output frame (mode 2026).
    term.feed(b"\x1b[?2026h");
    term.feed(b"mid-frame content\r\n");

    // While mode 2026 is active, has_damage must return false so hosts
    // don't paint a partial frame.
    assert!(
        !term.has_damage(),
        "must not report damage inside sync frame"
    );

    // Close the frame.
    term.feed(b"\x1b[?2026l");
    assert!(
        term.has_damage(),
        "must report damage after sync frame closes"
    );
}

#[test]
fn osc_133_prompt_mark_emits_prompt_mark_event() {
    let mut term = Terminal::new(80, 24);

    // OSC 133;A
    term.feed(b"\x1b]133;A\x07");
    let events = term.take_events();
    assert!(
        events
            .iter()
            .any(|e| matches!(e, TerminalEvent::PromptMark))
    );

    // OSC 133;P without k=s or k=c (initial prompt)
    term.feed(b"\x1b]133;P;k=i\x07");
    let events = term.take_events();
    assert!(
        events
            .iter()
            .any(|e| matches!(e, TerminalEvent::PromptMark))
    );

    // OSC 133;P with k=s (secondary prompt) should not emit PromptMark
    term.feed(b"\x1b]133;P;k=s\x07");
    let events = term.take_events();
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, TerminalEvent::PromptMark))
    );

    // OSC 133;P with k=c (continuation prompt) should not emit PromptMark
    term.feed(b"\x1b]133;P;k=c\x07");
    let events = term.take_events();
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, TerminalEvent::PromptMark))
    );
}

#[test]
fn osc_1337_set_status_and_clear_status() {
    let mut term = Terminal::new(80, 24);

    // SetStatus with status and text
    term.feed(b"\x1b]1337;SetStatus=working;compiling crate\x07");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::StatusSet {
            status: "working".into(),
            text: Some("compiling crate".into())
        }]
    );

    // SetStatus thinking alias normalized to working
    term.feed(b"\x1b]1337;SetStatus=thinking;analyzing code\x07");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::StatusSet {
            status: "working".into(),
            text: Some("analyzing code".into())
        }]
    );

    // ClearStatus
    term.feed(b"\x1b]1337;ClearStatus\x07");
    let events = term.take_events();
    assert_eq!(events, vec![TerminalEvent::StatusClear]);
}

#[test]
fn osc_9_5_status_and_clear() {
    let mut term = Terminal::new(80, 24);

    // OSC 9;5;status;text
    term.feed(b"\x1b]9;5;waiting_for_input;prompting user\x07");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::StatusSet {
            status: "waiting_for_input".into(),
            text: Some("prompting user".into())
        }]
    );

    // OSC 9;5;clear
    term.feed(b"\x1b]9;5;clear\x07");
    let events = term.take_events();
    assert_eq!(events, vec![TerminalEvent::StatusClear]);
}

#[test]
fn status_sanitization_and_length_limit() {
    let mut term = Terminal::new(80, 24);

    // Text with control characters, whitespace, and length > 128 characters
    let long_text = "a".repeat(200);
    let payload = format!("\x1b]1337;SetStatus=running;  \x01\x08hello\t {long_text}  \x07");
    term.feed(payload.as_bytes());

    let events = term.take_events();
    assert_eq!(events.len(), 1);
    if let TerminalEvent::StatusSet { status, text } = &events[0] {
        assert_eq!(status, "running");
        let t = text.as_ref().unwrap();
        assert!(t.len() <= 256);
        assert!(!t.contains('\x01'));
        assert!(!t.contains('\x08'));
        assert!(!t.starts_with(' '));
        assert!(!t.ends_with(' '));
    } else {
        panic!("expected StatusSet event");
    }

    // Invalid status rejected
    term.feed(b"\x1b]1337;SetStatus=invalid_status;testing\x07");
    let events = term.take_events();
    assert!(events.is_empty(), "invalid status must be rejected");
}

#[test]
fn status_pane_isolation() {
    let mut term1 = Terminal::new(80, 24);
    let mut term2 = Terminal::new(80, 24);

    // Feed sequence to term1 only
    term1.feed(b"\x1b]1337;SetStatus=needs_approval;confirm diff\x07");
    let events1 = term1.take_events();
    let events2 = term2.take_events();

    assert_eq!(events1.len(), 1);
    assert!(
        events2.is_empty(),
        "pane 2 must not receive events from pane 1"
    );
}

#[test]
fn test_set_command_started_at_any_status() {
    let mut term = Terminal::new(10, 10);
    // C and D in one feed
    term.feed(b"\x1b]133;C\x07\x1b]133;D\x07");

    // Command is already Completed, but setting time still works!
    assert_eq!(term.commands.running(), None); // It is not running
    // id is 1
    assert!(term.set_command_started_at(1, 1000));
    assert_eq!(term.commands.get(1).unwrap().started_at_ms, Some(1000));

    // Time cannot be overwritten
    assert!(!term.set_command_started_at(1, 2000));
    assert_eq!(term.commands.get(1).unwrap().started_at_ms, Some(1000));
}
