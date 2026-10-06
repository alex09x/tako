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
fn the_last_command_is_the_newest_with_its_output_and_status() {
    let mut t = Terminal::new(30, 12);
    t.feed(b"\x1b]7;file://host/tmp/work\x07");
    run(&mut t, "echo one", "one\r\n", Some(0));
    run(&mut t, "make", "compiling\r\nerror: nope\r\n", Some(2));
    let (rec, out) = t.last_command(100, 10_000).expect("a command");
    assert_eq!(rec.input.as_deref(), Some("make"));
    assert_eq!(rec.status, CommandStatus::Completed(Some(2)));
    // As the shell reported it (OSC 7): a file URL.
    assert_eq!(rec.cwd.as_deref(), Some("file://host/tmp/work"));
    // Its own output only: not the earlier command's, not the prompt.
    assert_eq!(out.text, "compiling\nerror: nope");
    assert_eq!((out.lines, out.more, out.truncated), (2, false, false));
}

#[test]
fn the_last_command_while_it_runs_and_a_soft_wrapped_line_comes_back_whole() {
    let mut t = Terminal::new(10, 12);
    t.feed(A);
    t.feed(b"$ ");
    t.feed(B);
    t.feed(b"seq\r\n");
    t.feed(C);
    t.feed(b"abcdefghijklmnop\r\n");
    let (rec, out) = t.last_command(100, 10_000).expect("a command");
    assert_eq!(rec.status, CommandStatus::Running);
    assert_eq!(out.text, "abcdefghijklmnop");
}

#[test]
fn the_last_command_output_is_bounded_from_its_end() {
    let mut t = Terminal::new(30, 40);
    let output: String = (1..=20).map(|i| format!("line{i}\r\n")).collect();
    run(&mut t, "seq", &output, Some(0));
    let (_, out) = t.last_command(3, 10_000).unwrap();
    assert_eq!(out.text, "line18\nline19\nline20");
    assert!(out.more);
    let (_, out) = t.last_command(100, 9).unwrap();
    // "line20" (6) + a newline leaves 2 bytes of "line19", from its end.
    assert_eq!(out.text, "19\nline20");
    assert!(out.truncated && out.more);
}

#[test]
fn no_last_command_without_marks_and_abandoned_ones_are_skipped() {
    let mut t = Terminal::new(30, 8);
    t.feed(b"plain output\r\n");
    assert!(t.last_command(10, 1000).is_none());
    run(&mut t, "ok", "fine\r\n", Some(0));
    // A command that starts and is abandoned by a new prompt.
    t.feed(A);
    t.feed(B);
    t.feed(b"sleep\r\n");
    t.feed(C);
    t.feed(A);
    let (rec, _) = t.last_command(10, 1000).unwrap();
    assert_eq!(rec.input.as_deref(), Some("ok"));
}

#[test]
fn the_ffi_reports_the_last_command() {
    let core = TakoCore::new(30, 8);
    core.feed(
        b"\x1b]133;A\x07$ \x1b]133;B\x07false\r\n\x1b]133;C\x07bad\r\n\x1b]133;D;1\x07".to_vec(),
    );
    let last = core.last_command(10, 1000).expect("a command");
    assert_eq!(last.output, "bad");
    assert!(last.command.finished);
    assert_eq!(last.command.exit_code, Some(1));
    assert_eq!(last.command.input.as_deref(), Some("false"));
}

#[test]
fn a_quiet_last_command_survives_sweeps() {
    let mut t = Terminal::new(30, 8);
    for _ in 0..300 {
        run(&mut t, "cd /tmp", "", Some(0));
    }
    run(&mut t, "true", "", Some(0));
    let (rec, out) = t
        .last_command(10, 1000)
        .expect("the newest command is kept");
    assert_eq!(rec.input.as_deref(), Some("true"));
    assert_eq!(out.text, "");
}

#[test]
fn a_command_by_id_and_output_written_over_is_reported_incomplete() {
    let mut t = Terminal::new(20, 10);
    run(&mut t, "first", "one\r\ntwo\r\n", Some(0));
    let (first, _) = t.last_command(10, 1000).unwrap();
    run(&mut t, "second", "three\r\n", Some(1));
    let (rec, out) = t.command(first.id, 10, 1000).unwrap();
    assert_eq!(rec.input.as_deref(), Some("first"));
    assert_eq!(out.text, "one\ntwo");
    assert!(!out.incomplete);
    // Overwrite a row of the first command's output from outside it.
    t.feed(b"\x1b[3;1Hxx");
    let (_, out) = t.command(first.id, 10, 1000).unwrap();
    assert!(out.incomplete, "{out:?}");
}

#[test]
fn reading_a_few_lines_of_a_long_output_stops_early() {
    let mut t = Terminal::new(30, 10);
    let output: String = (1..=2000).map(|i| format!("line{i}\r\n")).collect();
    run(&mut t, "seq", &output, Some(0));
    let (_, out) = t.last_command(2, 10_000).unwrap();
    assert_eq!(out.text, "line1999\nline2000");
    assert!(out.more);
}

#[test]
fn the_first_command_after_another_is_found_even_when_abandoned() {
    let core = TakoCore::new(30, 8);
    core.feed(
        b"\x1b]133;A\x07$ \x1b]133;B\x07ok\r\n\x1b]133;C\x07fine\r\n\x1b]133;D;0\x07".to_vec(),
    );
    let before = core.newest_command_id().expect("one command");
    // A command that starts and is abandoned by a new prompt, then another.
    core.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07sleep\r\n\x1b]133;C\x07".to_vec());
    core.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07x\r\n\x1b]133;D;0\x07".to_vec());
    let next = core.first_command_after(before).expect("a later command");
    assert!(next.abandoned);
    assert_eq!(next.input.as_deref(), Some("sleep"));
    assert!(core.newest_command_id().unwrap() > next.id);
}

#[test]
fn command_marks_track_prompt_lines_and_status() {
    use tako_core::terminal::CommandMarkStatus;

    let mut t = Terminal::new(30, 10);
    // Command 1: success (exit 0)
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07echo hi\r\n\x1b]133;C\x07hi\r\n\x1b]133;D;0\x07");
    // Command 2: failure with code (exit 2)
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07exit 2\r\n\x1b]133;C\x07error\r\n\x1b]133;D;2\x07");
    // Command 3: still running (no D)
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07sleep 10\r\n\x1b]133;C\x07working...\r\n");

    let marks = t.command_marks();
    assert_eq!(marks.len(), 3);

    // Command 1: Success
    assert_eq!(marks[0].command_id, 1);
    assert_eq!(marks[0].status, CommandMarkStatus::Success);
    assert_eq!(marks[0].prompt_line, 0);
    assert_eq!(marks[0].retained_row, 0);

    // Command 2: Error with code 2
    assert_eq!(marks[1].command_id, 2);
    assert_eq!(marks[1].status, CommandMarkStatus::Error(Some(2)));
    assert_eq!(marks[1].prompt_line, 2);
    assert_eq!(marks[1].retained_row, 2);

    // Command 3: Running
    assert_eq!(marks[2].command_id, 3);
    assert_eq!(marks[2].status, CommandMarkStatus::Running);
    assert_eq!(marks[2].prompt_line, 4);
    assert_eq!(marks[2].retained_row, 4);

    // Complete command 3 with exit 0
    t.feed(b"\x1b]133;D;0\x07");
    let marks_after = t.command_marks();
    assert_eq!(marks_after[2].status, CommandMarkStatus::Success);
}

#[test]
fn command_marks_empty_on_alternate_screen_and_omits_non_command_prompts() {
    let mut t = Terminal::new(30, 10);
    // Plain prompt with no command started (e.g. empty enter)
    t.feed(b"\x1b]133;A\x07$ \r\n");
    assert!(t.command_marks().is_empty());

    // Now run an actual command
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07test\r\n\x1b]133;C\x07ok\r\n\x1b]133;D;0\x07");
    assert_eq!(t.command_marks().len(), 1);

    // Switch to alternate screen
    t.feed(b"\x1b[?1049h");
    assert!(t.command_marks().is_empty());

    // Switch back to primary screen
    t.feed(b"\x1b[?1049l");
    assert_eq!(t.command_marks().len(), 1);
}

#[test]
fn ffi_command_marks_and_first_retained_line() {
    let core = TakoCore::new(30, 8);
    assert_eq!(core.first_retained_line(), 0);

    // Success command
    core.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07true\r\n\x1b]133;C\x07\x1b]133;D;0\x07".to_vec());
    // Failure command
    core.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07false\r\n\x1b]133;C\x07\x1b]133;D;1\x07".to_vec());
    // Running command
    core.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07cat\r\n\x1b]133;C\x07".to_vec());

    let marks = core.command_marks();
    assert_eq!(marks.len(), 3);

    assert_eq!(marks[0].status, 1); // 1 = success
    assert_eq!(marks[0].exit_code, Some(0));

    assert_eq!(marks[1].status, 2); // 2 = error
    assert_eq!(marks[1].exit_code, Some(1));

    assert_eq!(marks[2].status, 0); // 0 = running
    assert_eq!(marks[2].exit_code, None);
}

#[test]
fn command_marks_remap_after_reflow() {
    let mut t = Terminal::new(40, 10);
    // Command 1
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07echo hello\r\n\x1b]133;C\x07hello\r\n\x1b]133;D;0\x07");
    // Command 2 with long output that wraps across multiple lines when narrowed
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07cat file\r\n\x1b]133;C\x07");
    t.feed(b"123456789012345678901234567890\r\n");
    t.feed(b"\x1b]133;D;0\x07");
    // Command 3
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07tail\r\n\x1b]133;C\x07");

    let marks_before = t.command_marks();
    assert_eq!(marks_before.len(), 3);
    assert_eq!(marks_before[0].status, CommandMarkStatus::Success);
    assert_eq!(marks_before[1].status, CommandMarkStatus::Success);
    assert_eq!(marks_before[2].status, CommandMarkStatus::Running);

    // Narrow terminal to 15 columns, causing long line "123456789012345678901234567890" to wrap into 2 rows
    t.resize(15, 10);

    let marks_after = t.command_marks();
    assert_eq!(marks_after.len(), 3);
    assert_eq!(marks_after[0].status, CommandMarkStatus::Success);
    assert_eq!(marks_after[1].status, CommandMarkStatus::Success);
    assert_eq!(marks_after[2].status, CommandMarkStatus::Running);

    // Ensure prompt row for command 3 matches its new remapped position and has SemanticPrompt::Prompt
    let cmd3_mark = &marks_after[2];
    assert_eq!(
        t.active_grid()
            .retained_semantic_prompt(cmd3_mark.retained_row),
        SemanticPrompt::Prompt
    );
}

#[test]
fn pending_prompt_line_preserved_across_checkpoint() {
    let mut t = Terminal::new(40, 10);
    // OSC 133;A establishes prompt line, 133;B command starts, but 133;C has not arrived yet
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07echo hello\r\n");

    let data = t.export_checkpoint().expect("export checkpoint");

    let mut restored = Terminal::new(40, 10);
    restored
        .import_checkpoint(&data)
        .expect("import checkpoint");

    // Command output begins and finishes in restored terminal
    restored.feed(b"\x1b]133;C\x07hello\r\n\x1b]133;D;0\x07");

    let marks = restored.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].status, CommandMarkStatus::Success);
    assert_eq!(marks[0].retained_row, 0);
}
