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
fn ids_keep_counting_across_a_reset() {
    let mut t = Terminal::new(20, 4);
    t.feed(C);
    t.feed(b"\x1bc");
    assert_eq!(t.commands().records().len(), 0);
    t.feed(C);
    assert!(
        t.take_events()
            .contains(&TerminalEvent::CommandStart { id: Some(2) })
    );
}

#[test]
fn the_table_keeps_the_newest_records_and_a_forgotten_id_groups_nothing() {
    let mut t = Terminal::with_scrollback(20, 4, 100_000);
    t.feed(C);
    t.feed(b"oldest\r\n");
    // Each command keeps a row of output, so none is pruned for lack of one.
    for _ in 0..MAX_COMMAND_RECORDS {
        t.feed(C);
        t.feed(b"x\r\n");
        t.feed(&d(0));
    }
    assert_eq!(t.commands().records().len(), MAX_COMMAND_RECORDS);
    assert!(t.commands().get(1).is_none());
    // The row still names id 1, which is gone: no group.
    assert_eq!(command_of(&t, "oldest"), Some(1));
    let mut copy = Terminal::new(20, 4);
    copy.import_checkpoint(&t.export_checkpoint().unwrap())
        .unwrap();
    // Export wrote that row as unowned.
    assert_eq!(command_of(&copy, "oldest"), Some(1));
    assert_eq!(copy.commands().records().len(), MAX_COMMAND_RECORDS);
}

#[test]
fn a_checkpoint_keeps_owners_records_and_the_running_command() {
    let mut t = Terminal::new(30, 8);
    t.feed(b"\x1b]7;file://h/src\x07");
    run(&mut t, "make", "done\r\n", Some(2));
    t.feed(A);
    t.feed(b"$ ");
    t.feed(B);
    t.feed(b"tail -f\r\n");
    t.feed(C);
    t.feed(b"streaming\r\n");
    assert!(t.set_command_started_at(2, 1234));

    let mut copy = Terminal::new(30, 8);
    copy.import_checkpoint(&t.export_checkpoint().unwrap())
        .unwrap();
    let records = |t: &Terminal| t.commands().records().cloned().collect::<Vec<_>>();
    assert_eq!(records(&copy), records(&t));
    assert_eq!(owners(&copy), owners(&t));
    // The running command goes on claiming its output, and ends.
    copy.feed(b"more\r\n");
    copy.feed(&d(0));
    assert_eq!(command_of(&copy, "more"), Some(2));
    let rec = copy.commands().get(2).unwrap();
    assert_eq!(rec.status, CommandStatus::Completed(Some(0)));
    assert_eq!(rec.started_at_ms, Some(1234));
    assert_eq!(rec.input.as_deref(), Some("tail -f"));
    // New commands do not reuse an id.
    copy.feed(C);
    assert!(
        copy.take_events()
            .contains(&TerminalEvent::CommandStart { id: Some(3) })
    );
}

#[test]
fn a_v3_checkpoint_carries_no_commands() {
    let mut t = Terminal::new(30, 8);
    run(&mut t, "ls", "files\r\n", Some(0));
    let v3 = t.export_checkpoint_version(3, 0).unwrap();
    assert!(v3.len() < t.export_checkpoint().unwrap().len());
    let mut copy = Terminal::new(30, 8);
    copy.import_checkpoint(&v3).unwrap();
    assert_eq!(copy.commands().records().len(), 0);
    assert_eq!(command_of(&copy, "files"), None);
    // Rows that show nothing are free for the next command.
    let blank = (0..8)
        .filter(|&r| copy.active_grid().row_owner(r) == RowOwner::Empty)
        .count();
    assert!(blank > 0);
    copy.feed(C);
    copy.feed(b"\x1b[8;1Hnew");
    assert!(command_of(&copy, "new").is_some());
}

#[test]
fn a_search_hit_carries_its_command() {
    let (core, id) = core_with_finished_command();
    let chunk = core.search_chunk("output".into(), None, 100, 10);
    let info = chunk.hits[0].command.clone().unwrap();
    assert_eq!(info.id, id);
    assert_eq!(info.epoch, core.state_epoch());
    assert!(info.finished && !info.running && !info.abandoned);
    assert_eq!(info.exit_code, Some(3));
}

#[test]
fn a_start_time_lands_once_even_after_the_command_ended() {
    let (core, id) = core_with_finished_command();
    let epoch = core.state_epoch();
    assert!(core.set_command_time(epoch, id, 1000));
    assert!(!core.set_command_time(epoch, id, 2000));
    let chunk = core.search_chunk("output".into(), None, 100, 10);
    assert_eq!(
        chunk.hits[0].command.as_ref().unwrap().started_at_ms,
        Some(1000)
    );
}

#[test]
fn an_old_token_does_nothing_after_an_import_or_a_reset() {
    let (core, id) = core_with_finished_command();
    let epoch = core.state_epoch();
    let blob = core.checkpoint_export(0, 0).unwrap();
    core.checkpoint_import(blob).unwrap();
    // Same id exists in the imported table, but the token is from before.
    assert!(!core.set_command_time(epoch, id, 1000));
    let (core, id) = core_with_finished_command();
    let epoch = core.state_epoch();
    core.reset();
    core.feed(b"\x1b]133;C\x07".to_vec());
    assert!(!core.set_command_time(epoch, id, 1000));
    assert!(core.set_command_time(core.state_epoch(), id, 1000));
}

#[test]
fn a_multiline_command_line_stays_within_the_limit_and_round_trips() {
    let mut t = Terminal::with_scrollback(50, 30, 100);
    t.feed(B);
    // Eleven full rows, each ended by a real line break: 550 cells plus ten
    // separators.
    for _ in 0..11 {
        t.feed("y".repeat(50).as_bytes());
        t.feed(b"\x1b[K\r\n");
    }
    t.feed(C);
    t.feed(b"result\r\n");
    let id = command_of(&t, "result").unwrap();
    let rec = t.commands().get(id).unwrap().clone();
    let input = rec.input.unwrap();
    assert!(
        input.chars().count() <= MAX_INPUT_CHARS,
        "{}",
        input.chars().count()
    );
    assert!(input.contains('\n'));
    assert!(rec.input_truncated);
    let mut copy = Terminal::new(50, 30);
    copy.import_checkpoint(&t.export_checkpoint().unwrap())
        .unwrap();
    assert_eq!(
        copy.commands().get(id).unwrap().input.as_deref(),
        Some(input.as_str())
    );
}

#[test]
fn rows_moving_under_the_command_line_drop_it() {
    let cases: [(&str, &[u8]); 7] = [
        (
            "erase below from above",
            b"\x1b[1;1H\x1b[J\x1b[2;3Hreplacement",
        ),
        (
            "erase above from below",
            b"\x1b[3;1H\x1b[1J\x1b[2;3Hreplacement",
        ),
        ("insert line", b"\x1b[1;1H\x1b[L\x1b[1;1Hreplacement"),
        ("delete line", b"\x1b[1;1H\x1b[M\x1b[1;1Hreplacement"),
        (
            "region scroll up",
            b"\x1b[1;3r\x1b[3;1H\n\x1b[r\x1b[1;1Hreplacement",
        ),
        (
            "region scroll down",
            b"\x1b[1;3r\x1b[1;1H\x1bM\x1b[r\x1b[1;1Hreplacement",
        ),
        ("whole line erased", b"\x1b[2K\x1b[1;3Hreplacement"),
    ];
    for (name, seq) in cases {
        let mut t = Terminal::new(40, 6);
        if name.starts_with("erase ") {
            // The command line on row 2, so there is a row above it.
            t.feed(b"\r\n");
        }
        t.feed(b"$ ");
        t.feed(B);
        t.feed(b"original");
        t.feed(seq);
        t.feed(b"\x1b[4;1H");
        t.feed(C);
        t.feed(b"built");
        let rec = t.commands().get(command_of(&t, "built").unwrap()).unwrap();
        assert_eq!(rec.input, None, "{name}");
    }
}

#[test]
fn import_cost_matches_what_a_v4_import_charges() {
    use tako_core::terminal::checkpoint::{import_cost, import_traced};
    let mut t = Terminal::with_scrollback(30, 6, 50);
    t.feed(b"\x1b]7;file://h/some/dir\x07");
    for i in 0..5 {
        run(
            &mut t,
            &format!("cmd {i}"),
            &format!("out {i}\r\nmixed "),
            Some(i),
        );
        t.feed(b"prompt junk\r\n");
    }
    t.feed(B);
    t.feed(b"half typed");
    let blob = t.export_checkpoint().unwrap();
    let predicted = import_cost(&t);
    let (restored, trace) = import_traced(&blob).unwrap();
    assert_eq!(trace.allocated, predicted);
    assert_eq!(import_cost(&restored), predicted);
}

#[test]
fn a_line_editor_redraw_keeps_the_command_line() {
    // Erasing from the cursor on the command line's own row and retyping is
    // a redraw, not a different command.
    let mut t = Terminal::new(40, 6);
    t.feed(b"$ ");
    t.feed(B);
    t.feed(b"mkae");
    t.feed(b"\x1b[1;3H\x1b[Jmake\x1b[K");
    t.feed(b"\r\n");
    t.feed(C);
    t.feed(b"built");
    let rec = t.commands().get(command_of(&t, "built").unwrap()).unwrap();
    assert_eq!(rec.input.as_deref(), Some("make"));
}

#[test]
fn continuation_prompts_keep_the_whole_command_line() {
    // What the bundled bash and zsh integrations send: P;k=i ... B for the
    // prompt, P;k=s ... B for each continuation line.
    let mut t = Terminal::new(40, 8);
    t.feed(b"\x1b]133;P;k=i\x07$ \x1b]133;B\x07for x in a b\r\n");
    t.feed(b"\x1b]133;P;k=s\x07> \x1b]133;B\x07do echo $x; done\r\n");
    t.feed(C);
    t.feed(b"looped\r\n");
    let rec = t.commands().get(command_of(&t, "looped").unwrap()).unwrap();
    assert_eq!(
        rec.input.as_deref(),
        Some("for x in a b\n> do echo $x; done")
    );
    // A primary P is a new prompt: the next command line starts after it.
    t.feed(&d(0));
    t.feed(b"\x1b]133;P;k=i\x07$ \x1b]133;B\x07ls\r\n");
    t.feed(C);
    t.feed(b"listed\r\n");
    let rec = t.commands().get(command_of(&t, "listed").unwrap()).unwrap();
    assert_eq!(rec.input.as_deref(), Some("ls"));
}
