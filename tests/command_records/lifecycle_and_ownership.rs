/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

#[test]
fn a_command_owns_its_output_and_its_record_says_how_it_ended() {
    let mut t = Terminal::new(30, 8);
    t.feed(b"\x1b]7;file://host/tmp/work\x07");
    run(&mut t, "ls -la", "alpha\r\nbeta\r\n", Some(0));
    let id = command_of(&t, "alpha").expect("grouped");
    assert_eq!(command_of(&t, "beta"), Some(id));
    // The prompt and the command line are not output.
    assert_eq!(command_of(&t, "ls -la"), None);
    let rec = t.commands().get(id).unwrap();
    assert_eq!(rec.status, CommandStatus::Completed(Some(0)));
    assert_eq!(rec.input.as_deref(), Some("ls -la"));
    assert!(!rec.input_truncated);
    assert_eq!(rec.cwd.as_deref(), Some("file://host/tmp/work"));
    assert_eq!(rec.started_at_ms, None);
}

#[test]
fn the_start_event_names_the_record() {
    let mut t = Terminal::new(30, 8);
    t.feed(C);
    t.feed(C);
    let ids: Vec<_> = t
        .take_events()
        .into_iter()
        .filter_map(|e| match e {
            TerminalEvent::CommandStart { id } => Some(id),
            _ => None,
        })
        .collect();
    assert_eq!(ids, vec![Some(1), Some(2)]);
}

#[test]
fn a_command_without_d_is_abandoned_and_does_not_take_the_next_ones_output() {
    let mut t = Terminal::new(30, 10);
    t.feed(A);
    t.feed(C);
    t.feed(b"first\r\n");
    // No D: the next prompt and command.
    run(&mut t, "two", "second\r\n", Some(1));
    let first = command_of(&t, "first").unwrap();
    let second = command_of(&t, "second").unwrap();
    assert_ne!(first, second);
    assert_eq!(
        t.commands().get(first).unwrap().status,
        CommandStatus::Abandoned
    );
    assert_eq!(
        t.commands().get(second).unwrap().status,
        CommandStatus::Completed(Some(1))
    );
    // The second prompt is no one's output.
    assert_eq!(command_of(&t, "two"), None);
}

#[test]
fn c_without_d_then_c_abandons_the_first() {
    let mut t = Terminal::new(30, 10);
    t.feed(C);
    t.feed(b"one\r\n");
    t.feed(C);
    t.feed(b"two\r\n");
    let one = command_of(&t, "one").unwrap();
    assert_eq!(
        t.commands().get(one).unwrap().status,
        CommandStatus::Abandoned
    );
    assert_eq!(
        t.commands()
            .get(command_of(&t, "two").unwrap())
            .unwrap()
            .status,
        CommandStatus::Running
    );
}

#[test]
fn d_without_a_code_is_finished_but_not_a_success() {
    let mut t = Terminal::new(30, 8);
    run(&mut t, "x", "out\r\n", None);
    let id = command_of(&t, "out").unwrap();
    assert_eq!(
        t.commands().get(id).unwrap().status,
        CommandStatus::Completed(None)
    );
}

#[test]
fn two_commands_on_one_row_make_it_mixed() {
    let mut t = Terminal::new(30, 8);
    t.feed(C);
    t.feed(b"left ");
    t.feed(&d(0));
    t.feed(C);
    t.feed(b"right");
    assert_eq!(command_of(&t, "left"), None);
    assert_eq!(command_of(&t, "right"), None);
    assert_eq!(t.active_grid().row_owner(0), RowOwner::Mixed);
}

#[test]
fn a_row_overwritten_by_another_command_is_mixed() {
    let mut t = Terminal::new(30, 8);
    run(&mut t, "a", "aaaa\r\n", Some(0));
    let row = hits(&t, "aaaa")[0].start_line as usize;
    t.feed(C);
    t.feed(format!("\x1b[{};1Hbb", row + 1).as_bytes());
    assert_eq!(t.active_grid().row_owner(row), RowOwner::Mixed);
    assert_eq!(command_of(&t, "bbaa"), None);
}

#[test]
fn a_partial_write_over_unknown_content_is_mixed_and_stays_mixed() {
    let mut t = Terminal::new(30, 8);
    t.feed(b"prompt text");
    assert_eq!(t.active_grid().row_owner(0), RowOwner::Unowned);
    t.feed(C);
    t.feed(b"\x1b[1;3Hxy");
    assert_eq!(t.active_grid().row_owner(0), RowOwner::Mixed);
    // Writing outside a command, then in a new one, does not clean it.
    t.feed(&d(0));
    t.feed(b"\x1b[1;5Hzz");
    t.feed(C);
    t.feed(b"\x1b[1;7Hww");
    assert_eq!(t.active_grid().row_owner(0), RowOwner::Mixed);
}

#[test]
fn partial_erases_inserts_and_deletes_count_as_writes() {
    // ECH, ICH, DCH and a partial EL over a prompt row while a command runs.
    for seq in [
        &b"\x1b[2X"[..],
        b"\x1b[2@",
        b"\x1b[2P",
        b"\x1b[K",
        b"\x1b[1K",
        b"   ",
    ] {
        let mut t = Terminal::new(30, 4);
        t.feed(b"prompt");
        t.feed(b"\x1b[1;3H");
        t.feed(C);
        t.feed(seq);
        assert_eq!(t.active_grid().row_owner(0), RowOwner::Mixed, "{seq:?}");
    }
}

#[test]
fn erasing_a_whole_row_or_screen_cleans_it_for_the_next_command() {
    let mut t = Terminal::new(30, 4);
    t.feed(b"junk\r\nmore junk");
    t.feed(b"\x1b[2J\x1b[H");
    assert_eq!(owners(&t), vec![RowOwner::Empty; 4]);
    t.feed(b"\x1b[2;1H\x1b[2K");
    t.feed(C);
    t.feed(b"clean");
    let id = command_of(&t, "clean");
    assert!(id.is_some());
    // EL 2 on a row owned by someone else also cleans it.
    let mut t = Terminal::new(30, 4);
    t.feed(b"junk");
    t.feed(C);
    t.feed(b"\x1b[2K\rfresh");
    assert!(command_of(&t, "fresh").is_some());
}

#[test]
fn owners_move_with_their_rows_through_scroll_regions_and_line_edits() {
    let mut t = Terminal::new(20, 6);
    t.feed(C);
    t.feed(b"r0\r\nr1\r\nr2");
    let id = command_of(&t, "r0").unwrap();
    t.feed(&d(0));
    // Insert two lines at the top: the command's rows move down with their text.
    t.feed(b"\x1b[1;1H\x1b[2L");
    assert_eq!(t.active_grid().row_owner(0), RowOwner::Empty);
    assert_eq!(t.active_grid().row_owner(2), RowOwner::Command(id));
    assert_eq!(command_of(&t, "r2"), Some(id));
    // Delete one: back up by one.
    t.feed(b"\x1b[1;1H\x1b[1M");
    assert_eq!(t.active_grid().row_owner(1), RowOwner::Command(id));
    // Scroll a region: the rows inside rotate with their owners.
    t.feed(b"\x1b[2;4r\x1b[4;1H\n\x1b[r");
    assert_eq!(command_of(&t, "r1"), Some(id));
    assert_eq!(command_of(&t, "r2"), Some(id));
}

#[test]
fn a_commands_tail_stays_grouped_after_its_start_is_evicted() {
    let mut t = Terminal::with_scrollback(20, 3, 4);
    t.feed(C);
    for i in 0..12 {
        t.feed(format!("line{i:02}\r\n").as_bytes());
    }
    t.feed(&d(0));
    assert!(hits(&t, "line00").is_empty());
    let id = command_of(&t, "line11").unwrap();
    assert_eq!(command_of(&t, "line08"), Some(id));
}

#[test]
fn reflow_keeps_owners_and_a_line_joined_from_two_commands_is_mixed() {
    let mut t = Terminal::new(10, 6);
    t.feed(C);
    t.feed(b"0123456789abcdef\r\n");
    let id = command_of(&t, "abc").unwrap();
    t.feed(&d(0));
    t.resize(20, 6);
    assert_eq!(command_of(&t, "6789abc"), Some(id));
    t.resize(5, 6);
    assert_eq!(command_of(&t, "def"), Some(id));

    // A soft-wrapped line whose rows two commands wrote.
    let mut t = Terminal::new(10, 6);
    t.feed(C);
    t.feed(b"0123456789");
    t.feed(&d(0));
    t.feed(C);
    t.feed(b"xyz");
    t.resize(20, 6);
    assert_eq!(t.active_grid().row_owner(0), RowOwner::Mixed);
}

#[test]
fn the_alternate_screen_records_nothing() {
    let mut t = Terminal::new(20, 4);
    t.feed(b"\x1b[?1049h");
    t.feed(C);
    t.feed(b"inside");
    t.feed(&d(0));
    assert!(
        t.take_events()
            .contains(&TerminalEvent::CommandStart { id: None })
    );
    assert_eq!(t.commands().records().len(), 0);
    assert_eq!(command_of(&t, "inside"), None);
}

#[test]
fn the_command_line_is_cut_at_the_limit() {
    let mut t = Terminal::new(80, 20);
    let long = "x".repeat(MAX_INPUT_CHARS + 50);
    run(&mut t, &long, "out\r\n", Some(0));
    let rec = t.commands().get(command_of(&t, "out").unwrap()).unwrap();
    assert_eq!(rec.input.as_ref().unwrap().chars().count(), MAX_INPUT_CHARS);
    assert!(rec.input_truncated);
}

#[test]
fn the_command_line_is_dropped_when_it_may_have_moved() {
    let cases: [(&str, &dyn Fn(&mut Terminal)); 4] = [
        ("resize", &|t| t.resize(41, 6)),
        ("clear", &|t| t.feed(b"\x1b[2J\x1b[Hredrawn by a program")),
        ("screen switch", &|t| t.feed(b"\x1b[?1049h\x1b[?1049l")),
        ("new prompt", &|t| t.feed(A)),
    ];
    for (name, interrupt) in cases {
        let mut t = Terminal::new(40, 6);
        t.feed(b"$ ");
        t.feed(B);
        t.feed(b"make");
        interrupt(&mut t);
        t.feed(b"\r\n");
        t.feed(C);
        t.feed(b"built\r\n");
        let rec = t.commands().get(command_of(&t, "built").unwrap()).unwrap();
        assert_eq!(rec.input, None, "{name}");
    }
    // Evicted before C.
    let mut t = Terminal::with_scrollback(40, 2, 1);
    t.feed(B);
    t.feed(b"make\r\n\r\n\r\n\r\n");
    t.feed(C);
    t.feed(b"built");
    let rec = t.commands().get(command_of(&t, "built").unwrap()).unwrap();
    assert_eq!(rec.input, None);
    // A reset forgets everything.
    let mut t = Terminal::new(40, 6);
    t.feed(B);
    t.feed(b"make\x1bc\r\n");
    t.feed(C);
    t.feed(b"built");
    let rec = t.commands().get(command_of(&t, "built").unwrap()).unwrap();
    assert_eq!(rec.input, None);
}
