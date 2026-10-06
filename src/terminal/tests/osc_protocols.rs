/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::terminal::{ContextFrame, Terminal, TerminalEvent};

#[test]
fn test_osc99_simple_notification() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]99;;Hello World\x1b\\");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::StructuredNotification {
            id: None,
            title: "Hello World".into(),
            body: String::new(),
            app_name: None,
            urgency: 1,
            actions: Vec::new(),
            report_activation: false,
            focus: true,
            report_close: false,
            timeout_ms: None,
            only_when_unfocused: false,
        }]
    );
}

#[test]
fn test_osc99_chunked_title_body_and_buttons() {
    let mut term = Terminal::new(80, 24);
    // Chunk 1: id=test1, not done yet (d=0), title="Build Done"
    term.feed(b"\x1b]99;i=test1:d=0;Build Done\x1b\\");
    assert!(term.take_events().is_empty());

    // Chunk 2: id=test1, not done yet (d=0), body="42 passed"
    term.feed(b"\x1b]99;i=test1:d=0:p=body;42 passed\x1b\\");
    assert!(term.take_events().is_empty());

    // Chunk 3: id=test1, done (d=1 by default), buttons="View\u{2028}Cancel", report activation, urgency=2
    term.feed(" \x1b]99;i=test1:u=2:a=report:p=buttons;View\u{2028}Cancel\x1b\\".as_bytes());
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::StructuredNotification {
            id: Some("test1".into()),
            title: "Build Done".into(),
            body: "42 passed".into(),
            app_name: None,
            urgency: 2,
            actions: vec!["View".into(), "Cancel".into()],
            report_activation: true,
            focus: true,
            report_close: false,
            timeout_ms: None,
            only_when_unfocused: false,
        }]
    );
}

#[test]
fn test_osc99_base64_and_app_name() {
    let mut term = Terminal::new(80, 24);
    // f=bXlhcHA= ("myapp"), payload=SGVsbG8= ("Hello"), e=1
    term.feed(b"\x1b]99;i=b64:e=1:f=bXlhcHA=;SGVsbG8=\x07");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::StructuredNotification {
            id: Some("b64".into()),
            title: "Hello".into(),
            body: String::new(),
            app_name: Some("myapp".into()),
            urgency: 1,
            actions: Vec::new(),
            report_activation: false,
            focus: true,
            report_close: false,
            timeout_ms: None,
            only_when_unfocused: false,
        }]
    );
}

#[test]
fn test_osc99_close_notification() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]99;i=job42:p=close:c=1;\x1b\\");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::NotificationClose {
            id: "job42".into(),
            report_close: true,
        }]
    );
}

#[test]
fn test_osc99_capability_and_alive_query() {
    let mut term = Terminal::new(80, 24);
    // Capability query with ST
    term.feed(b"\x1b]99;i=q1:p=?;\x1b\\");
    let reply = term.take_output();
    assert_eq!(
        reply,
        b"\x1b]99;i=q1:p=?;a=focus,report:c=1:o=always,unfocused,invisible:p=title,body,buttons,close:u=0,1,2\x1b\\".to_vec()
    );

    // Capability query with BEL
    term.feed(b"\x1b]99;i=q2:p=?;\x07");
    let reply2 = term.take_output();
    assert_eq!(
        reply2,
        b"\x1b]99;i=q2:p=?;a=focus,report:c=1:o=always,unfocused,invisible:p=title,body,buttons,close:u=0,1,2\x07".to_vec()
    );

    // Alive query
    term.feed(b"\x1b]99;i=q3:p=alive;\x1b\\");
    let reply3 = term.take_output();
    assert_eq!(reply3, b"\x1b]99;i=q3:p=alive;\x1b\\".to_vec());
}

#[test]
fn test_osc99_occasion_and_timeout() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]99;i=unf1:o=unfocused:w=5000;Background Alert\x1b\\");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![TerminalEvent::StructuredNotification {
            id: Some("unf1".into()),
            title: "Background Alert".into(),
            body: String::new(),
            app_name: None,
            urgency: 1,
            actions: Vec::new(),
            report_activation: false,
            focus: true,
            report_close: false,
            timeout_ms: Some(5000),
            only_when_unfocused: true,
        }]
    );
}

#[test]
fn test_osc3008_push_pop_clear() {
    let mut term = Terminal::new(80, 24);
    assert!(term.context_stack().is_empty());
    assert!(!term.is_elevated());
    assert_eq!(term.active_tint(), None);

    // Push host
    term.feed(b"\x1b]3008;push;host;macbook\x07");
    assert_eq!(term.context_stack().len(), 1);
    assert_eq!(term.context_stack()[0].kind, "host");
    assert_eq!(term.context_stack()[0].name, "macbook");
    assert!(!term.is_elevated());
    assert_eq!(term.active_tint(), None);

    // Push container with custom tint
    term.feed(b"\x1b]3008;push;container;docker-alpine;#3b82f6\x1b\\");
    assert_eq!(term.context_stack().len(), 2);
    assert_eq!(term.context_stack()[1].kind, "container");
    assert_eq!(term.context_stack()[1].name, "docker-alpine");
    assert_eq!(term.context_stack()[1].tint.as_deref(), Some("#3b82f6"));
    assert_eq!(term.active_tint(), Some("#3b82f6"));
    assert!(!term.is_elevated());

    let events = term.take_events();
    assert_eq!(events.len(), 2);
    assert_eq!(
        events[0],
        TerminalEvent::ContextPush(ContextFrame {
            kind: "host".into(),
            name: "macbook".into(),
            tint: None,
            is_elevated: false,
        })
    );
    assert_eq!(
        events[1],
        TerminalEvent::ContextPush(ContextFrame {
            kind: "container".into(),
            name: "docker-alpine".into(),
            tint: Some("#3b82f6".into()),
            is_elevated: false,
        })
    );

    // Pop container
    term.feed(b"\x1b]3008;pop\x07");
    assert_eq!(term.context_stack().len(), 1);
    assert_eq!(term.active_tint(), None);
    let events = term.take_events();
    assert_eq!(events, vec![TerminalEvent::ContextPop]);

    // Clear
    term.feed(b"\x1b]3008;clear\x1b\\");
    assert!(term.context_stack().is_empty());
    let events = term.take_events();
    assert_eq!(events, vec![TerminalEvent::ContextClear]);
}

#[test]
fn test_osc3008_elevation_and_tint() {
    let mut term = Terminal::new(80, 24);
    // Push elevated shell: sudo -> automatic tint #ea580c and is_elevated = true
    term.feed(b"\x1b]3008;push;sudo;root\x07");
    assert!(term.is_elevated());
    assert_eq!(term.active_tint(), Some("#ea580c"));

    // Hard reset clears context stack
    term.feed(b"\x1bc"); // RIS
    assert!(term.context_stack().is_empty());
    assert!(!term.is_elevated());
}

#[test]
fn test_osc3008_set_and_container_roundtrip() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]3008;set;ssh;prod-server;#10b981\x07");
    assert_eq!(term.context_stack().len(), 1);
    assert_eq!(term.context_stack()[0].kind, "ssh");
    assert_eq!(term.context_stack()[0].name, "prod-server");
    assert_eq!(term.active_tint(), Some("#10b981"));

    // Replace with set
    term.feed(b"\x1b]3008;set;container;app-runner\x1b\\");
    assert_eq!(term.context_stack().len(), 1);
    assert_eq!(term.context_stack()[0].kind, "container");
    assert_eq!(term.context_stack()[0].name, "app-runner");
    assert_eq!(term.active_tint(), None);
}

#[test]
fn test_osc3008_bounded_stack_depth_and_field_length() {
    let mut term = Terminal::new(80, 24);

    // Push 50 frames; stack must cap at 32 and retain only the newest 32
    for i in 0..50 {
        let cmd = format!("\x1b]3008;push;host;node-{i}\x07");
        term.feed(cmd.as_bytes());
    }
    assert_eq!(term.context_stack().len(), 32);
    assert_eq!(term.context_stack()[0].name, "node-18");
    assert_eq!(term.context_stack()[31].name, "node-49");

    // Overly long fields are truncated to 128 characters
    let long_name = "x".repeat(300);
    let cmd = format!("\x1b]3008;push;container;{long_name}\x07");
    term.feed(cmd.as_bytes());
    assert_eq!(term.context_stack().len(), 32);
    let last = term.context_stack().last().unwrap();
    assert_eq!(last.name.len(), 128);
}

#[test]
fn test_osc3008_overflow_preserves_elevation() {
    let mut term = Terminal::new(80, 24);

    // 1. Push elevated outer frame (e.g. sudo session)
    term.feed(b"\x1b]3008;push;sudo;root\x07");
    assert_eq!(term.context_stack().len(), 1);
    assert!(term.is_elevated());
    assert_eq!(term.active_tint(), Some("#ea580c"));

    // 2. Push 40 non-elevated ordinary frames. Stack must cap at 32, but outer elevated frame must NOT be dropped.
    for i in 1..=40 {
        let cmd = format!("\x1b]3008;push;step;task_{i}\x07");
        term.feed(cmd.as_bytes());
    }
    assert_eq!(term.context_stack().len(), 32);
    // Frame 0 must still be the elevated root frame
    assert_eq!(term.context_stack()[0].name, "root");
    assert!(term.context_stack()[0].is_elevated);
    assert_eq!(term.context_stack()[31].name, "task_40");
    assert!(term.is_elevated());
    assert_eq!(term.active_tint(), Some("#ea580c"));

    // 3. Pop 31 times (exiting all non-elevated sub-contexts)
    for _ in 0..31 {
        term.feed(b"\x1b]3008;pop\x07");
    }
    assert_eq!(term.context_stack().len(), 1);
    assert_eq!(term.context_stack()[0].name, "root");
    assert!(term.is_elevated());
    assert_eq!(term.active_tint(), Some("#ea580c"));

    // 4. Pop 1 more time (exiting the root context)
    term.feed(b"\x1b]3008;pop\x07");
    assert!(term.context_stack().is_empty());
    assert!(!term.is_elevated());
    assert_eq!(term.active_tint(), None);

    // 5. Test overflow when all 32 frames are elevated
    for i in 1..=40 {
        let cmd = format!("\x1b]3008;push;sudo;elevated_{i}\x07");
        term.feed(cmd.as_bytes());
    }
    assert_eq!(term.context_stack().len(), 32);
    assert!(term.is_elevated());
    assert_eq!(term.active_tint(), Some("#ea580c"));

    // Popping 40 times keeps elevation until all 40 are popped
    for _ in 0..39 {
        term.feed(b"\x1b]3008;pop\x07");
        assert!(term.is_elevated());
    }
    term.feed(b"\x1b]3008;pop\x07");
    assert!(term.context_stack().is_empty());
    assert!(!term.is_elevated());
}
