/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! What a Swift host asks `TakoCore` about a session: its context stack,
//! modes, shell-marked commands and prompts, search hits, events, and the
//! bytes a key or a mouse report becomes.

use super::common::*;
use tako_core::ffi::FfiContextFrame;

fn ffi_key(key: FfiKey) -> Vec<u8> {
    TakoCore::new(20, 5).encode_key(default_key_event(key))
}

#[test]
fn the_context_stack_and_its_tint_reach_the_host() {
    let core = TakoCore::new(40, 10);
    assert!(core.context_stack().is_empty() && !core.is_elevated() && core.active_tint().is_none());
    core.feed(b"\x1b]3008;push;container;web;#3b82f6\x07".to_vec());
    core.feed(b"\x1b]3008;push;sudo;root\x07".to_vec());
    let stack = core.context_stack();
    assert_eq!(stack.len(), 2);
    assert_eq!(
        (
            stack[0].kind.as_str(),
            stack[0].name.as_str(),
            stack[0].tint.as_deref()
        ),
        ("container", "web", Some("#3b82f6"))
    );
    assert!(stack[1].is_elevated && core.is_elevated());
    assert!(core.active_tint().is_some());
    core.feed(b"\x1b]3008;pop\x07".to_vec());
    core.feed(b"\x1b]3008;clear\x07".to_vec());
    let events = core.take_events();
    assert!(events.contains(&FfiEvent::ContextPush {
        frame: FfiContextFrame {
            kind: "container".into(),
            name: "web".into(),
            tint: Some("#3b82f6".into()),
            is_elevated: false
        }
    }));
    assert!(events.contains(&FfiEvent::ContextPop) && events.contains(&FfiEvent::ContextClear));
    assert!(core.context_stack().is_empty());
}

#[test]
fn status_prompt_and_program_status_events_reach_the_host() {
    let core = TakoCore::new(40, 10);
    core.feed(b"\x1b]9;5;working;Indexing\x07".to_vec());
    core.feed(b"\x1b]9;5;clear\x07".to_vec());
    core.feed(b"\x1b]133;A\x07".to_vec());
    core.feed(b"\x1b]7501;state=working:id=job\x07".to_vec());
    let events = core.take_events();
    assert!(events.contains(&FfiEvent::StatusSet {
        status: "working".into(),
        text: Some("Indexing".into())
    }));
    assert!(events.contains(&FfiEvent::StatusClear));
    assert!(events.contains(&FfiEvent::PromptMark));
    assert!(events.iter().any(
        |e| matches!(e, FfiEvent::ProgramStatusChanged { snapshot, .. }
        if snapshot.records.iter().any(|r| r.id == "job"))
    ));
}

#[test]
fn a_status_burst_too_big_to_queue_is_one_resync_not_a_flood_of_events() {
    let core = TakoCore::new(40, 10);
    let burst: String = (0..100)
        .map(|i| format!("\x1b]7501;state=working:id=r{i}\x07"))
        .collect();
    let outcome = core.feed_with_outcome(burst.into_bytes());
    assert!(outcome.status_overflow_coalesced);
    assert_eq!(
        outcome.status_resync_snapshot.map(|s| s.records.len()),
        Some(100)
    );
    assert!(
        !outcome
            .events
            .iter()
            .any(|e| matches!(e, FfiEvent::ProgramStatusChanged { .. })),
        "the resync replaces the per-update events"
    );
}

#[test]
fn modes_reach_the_host_as_set() {
    let core = TakoCore::new(40, 10);
    let fresh = core.modes();
    assert!(
        fresh.autowrap && !fresh.alternate_screen && fresh.mouse_tracking == FfiMouseTracking::Off
    );
    core.feed(b"\x1b[?7l\x1b[?6h\x1b[?1h\x1b[?1002h\x1b[?1005h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[?1007h\x1b[?1049h".to_vec());
    let m = core.modes();
    assert!(!m.autowrap && m.origin_mode && m.cursor_key_app_mode);
    assert_eq!(m.mouse_tracking, FfiMouseTracking::ButtonEvent);
    assert!(
        m.mouse_utf8
            && m.mouse_sgr
            && m.focus_events
            && m.bracketed_paste
            && m.alternate_scroll
            && m.alternate_screen
    );
    assert_eq!(core.mouse_shift_capture(), None);
}

/// Three commands, each with output, in a 5-row terminal: the first two
/// scroll back.
fn session() -> TakoCore {
    let core = TakoCore::new(40, 5);
    for (i, code) in [(1, 0), (2, 1), (3, 0)] {
        core.feed(format!("\x1b]133;A\x07$ \x1b]133;B\x07run{i}\r\n\x1b]133;C\x07out{i}.a\r\nout{i}.b\r\n\x1b]133;D;{code}\x07").into_bytes());
    }
    core.feed(b"\x1b]133;A\x07$ ".to_vec());
    core
}

#[test]
fn shell_marked_commands_reach_the_host_by_id_and_generation() {
    let core = session();
    let epoch = core.state_epoch();
    let marks = core.command_marks();
    assert_eq!(
        marks
            .iter()
            .map(|m| (m.status, m.exit_code))
            .collect::<Vec<_>>(),
        [(1, Some(0)), (2, Some(1)), (1, Some(0))]
    );
    let newest = core.newest_command_id().expect("three commands");
    assert_eq!(marks.last().unwrap().command_id, newest);
    let second = core
        .first_command_after(marks[0].command_id)
        .expect("a command after the first");
    assert_eq!(
        (second.id, second.exit_code, second.finished),
        (marks[1].command_id, Some(1), true)
    );
    assert!(core.first_command_after(newest).is_none());

    let last = core.last_command(10, 4096).expect("the newest command");
    assert_eq!(last.command.id, newest);
    assert!(last.output.contains("out3.a"));
    let first = core
        .command_output(marks[0].command_id, epoch, 10, 4096)
        .expect("still retained");
    assert!(first.output.contains("out1.b"));
    assert!(
        core.command_output(marks[0].command_id, epoch + 1, 10, 4096)
            .is_none(),
        "another generation's id means nothing"
    );

    assert!(core.set_command_time(epoch, newest, 1_700_000_000_000));
    assert_eq!(
        core.last_command(1, 64).unwrap().command.started_at_ms,
        Some(1_700_000_000_000)
    );
    assert!(
        !core.set_command_time(epoch + 1, newest, 1),
        "a stale generation sets nothing"
    );
    assert!(core.first_retained_line() <= marks[0].prompt_line);
}

#[test]
fn prompt_rows_navigation_and_output_selection_follow_the_marks() {
    let core = session();
    assert!(core.cursor_is_at_prompt());
    assert_eq!(
        core.row_semantic_prompt(4),
        1,
        "the cursor's row is a prompt"
    );
    let first_prompt = core.command_marks()[0].retained_row;
    assert_eq!(core.retained_semantic_prompt(first_prompt), 1);
    assert_eq!(
        core.retained_semantic_prompt(first_prompt + 1),
        0,
        "its output is not"
    );
    assert!(core.scroll_to_previous_prompt());
    assert!(core.scroll_to_next_prompt());
    assert!(core.select_command_output());
}

#[test]
fn a_search_hit_names_its_command_and_selects_it_in_scrollback() {
    let core = session();
    let chunk = core.search_chunk("OUT1".into(), None, 100, 10);
    let hit = chunk
        .hits
        .iter()
        .find(|h| h.matched.eq_ignore_ascii_case("out1"))
        .expect("case-insensitive hit")
        .clone();
    assert!(
        hit.command.is_some(),
        "a hit in a command's output names the command"
    );
    let lines = core.search_first_line();
    assert!(lines.scrollback_len > 0 && hit.start_line >= lines.first_line);
    assert!(core.search_hit_is_current("OUT1".into(), hit.clone()));
    assert!(
        core.select_search_hit("OUT1".into(), hit.clone()),
        "a hit scrolled out is scrolled to and selected"
    );

    let mut stale = hit;
    stale.start_col += 1;
    stale.end_col += 1;
    assert!(!core.search_hit_is_current("OUT1".into(), stale.clone()));
    assert!(
        !core.select_search_hit("OUT1".into(), stale),
        "a hit that moved is not selected"
    );
}

#[test]
fn a_flood_of_replies_is_counted_once_and_clipboard_reading_toggles() {
    let core = TakoCore::new(20, 5);
    core.feed(b"\x1b[c".repeat(400));
    assert!(core.take_reply_overflow_count() > 0);
    assert_eq!(
        core.take_reply_overflow_count(),
        0,
        "the count is taken once"
    );
    core.set_clipboard_read_allowed(true);
    core.set_clipboard_read_allowed(false);
    assert!(!core.is_clipboard_read_allowed());
}

#[test]
fn named_keys_send_the_xterm_bytes() {
    let cases: [(FfiKey, &[u8]); 25] = [
        (FfiKey::Backspace, b"\x7f"),
        (FfiKey::Down, b"\x1b[B"),
        (FfiKey::Right, b"\x1b[C"),
        (FfiKey::Left, b"\x1b[D"),
        (FfiKey::Home, b"\x1b[H"),
        (FfiKey::End, b"\x1b[F"),
        (FfiKey::PageUp, b"\x1b[5~"),
        (FfiKey::PageDown, b"\x1b[6~"),
        (FfiKey::Insert, b"\x1b[2~"),
        (FfiKey::Delete, b"\x1b[3~"),
        (FfiKey::F2, b"\x1bOQ"),
        (FfiKey::F3, b"\x1b[13~"),
        (FfiKey::F4, b"\x1bOS"),
        (FfiKey::F5, b"\x1b[15~"),
        (FfiKey::F6, b"\x1b[17~"),
        (FfiKey::F7, b"\x1b[18~"),
        (FfiKey::F8, b"\x1b[19~"),
        (FfiKey::F9, b"\x1b[20~"),
        (FfiKey::F10, b"\x1b[21~"),
        (FfiKey::F11, b"\x1b[23~"),
        (FfiKey::F12, b"\x1b[24~"),
        (FfiKey::KeypadPlus, b"+"),
        (FfiKey::KeypadMinus, b"-"),
        (FfiKey::KeypadMultiply, b"*"),
        (FfiKey::KeypadDivide, b"/"),
    ];
    for (key, bytes) in cases {
        assert_eq!(ffi_key(key), bytes, "{key:?}");
    }
    // Keypad digits exist only under the Kitty protocol: there each is its own code.
    let digits = [
        FfiKey::Keypad0,
        FfiKey::Keypad1,
        FfiKey::Keypad2,
        FfiKey::Keypad3,
        FfiKey::Keypad4,
        FfiKey::Keypad5,
        FfiKey::Keypad6,
        FfiKey::Keypad7,
        FfiKey::Keypad8,
        FfiKey::Keypad9,
    ];
    let core = TakoCore::new(20, 5);
    for key in digits {
        assert!(
            core.encode_key(default_key_event(key)).is_empty(),
            "{key:?} has no legacy form"
        );
    }
    core.feed(b"\x1b[>9u".to_vec());
    for (n, key) in digits.into_iter().enumerate() {
        assert_eq!(
            core.encode_key(default_key_event(key)),
            format!("\x1b[{}u", 57399 + n).into_bytes(),
            "{key:?}"
        );
    }
    for key in [
        FfiKey::ShiftLeft,
        FfiKey::ShiftRight,
        FfiKey::ControlLeft,
        FfiKey::ControlRight,
        FfiKey::AltLeft,
        FfiKey::AltRight,
        FfiKey::MetaLeft,
        FfiKey::MetaRight,
        FfiKey::Unidentified,
    ] {
        assert!(ffi_key(key).is_empty(), "{key:?} alone sends nothing");
    }
    let core = TakoCore::new(20, 5);
    let mut shifted = default_key_event(FfiKey::Up);
    (shifted.shift, shifted.alt, shifted.super_key) = (true, true, true);
    assert_eq!(
        core.encode_key(shifted),
        b"\x1b[1;12A",
        "shift+alt+super: modifier 1+1+2+8"
    );
}

fn mouse(core: &TakoCore, button: FfiMouseButton, action: FfiMouseAction) -> String {
    let event = FfiMouseEvent {
        button,
        action,
        shift: false,
        alt: false,
        ctrl: false,
        col: 2,
        row: 3,
    };
    String::from_utf8_lossy(&core.encode_mouse(event)).into_owned()
}

#[test]
fn every_button_and_action_is_reported_in_sgr() {
    let core = TakoCore::new(20, 5);
    core.feed(b"\x1b[?1003h\x1b[?1006h".to_vec());
    assert_eq!(
        mouse(&core, FfiMouseButton::Middle, FfiMouseAction::Press),
        "\x1b[<1;3;4M"
    );
    assert_eq!(
        mouse(&core, FfiMouseButton::Right, FfiMouseAction::Release),
        "\x1b[<2;3;4m"
    );
    assert_eq!(
        mouse(&core, FfiMouseButton::WheelUp, FfiMouseAction::Press),
        "\x1b[<64;3;4M"
    );
    assert_eq!(
        mouse(&core, FfiMouseButton::WheelDown, FfiMouseAction::Press),
        "\x1b[<65;3;4M"
    );
    assert_eq!(
        mouse(&core, FfiMouseButton::WheelLeft, FfiMouseAction::Press),
        "\x1b[<66;3;4M"
    );
    assert_eq!(
        mouse(&core, FfiMouseButton::WheelRight, FfiMouseAction::Press),
        "\x1b[<67;3;4M"
    );
    assert_eq!(
        mouse(&core, FfiMouseButton::None, FfiMouseAction::Motion),
        "\x1b[<35;3;4M",
        "any-motion tracking reports a hover"
    );
    core.feed(b"\x1b[?1006l\x1b[?1005h".to_vec());
    assert!(
        mouse(&core, FfiMouseButton::Left, FfiMouseAction::Press).starts_with("\x1b[M"),
        "UTF-8 encoding"
    );
}
