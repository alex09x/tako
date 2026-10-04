// Which command printed a row (OSC 133): row owners, the command table, the
// command each search hit belongs to, start times from the host, and how all
// of it survives reflow, eviction, reset and checkpoints.

use tako_core::ffi::TakoCore;
use tako_core::grid::{RowOwner, SearchHit, SemanticPrompt};
use tako_core::terminal::commands::{CommandStatus, MAX_COMMAND_RECORDS, MAX_INPUT_CHARS};
use tako_core::terminal::{CommandMarkStatus, Terminal, TerminalEvent};

const A: &[u8] = b"\x1b]133;A\x07";
const B: &[u8] = b"\x1b]133;B\x07";
const C: &[u8] = b"\x1b]133;C\x07";

fn d(code: i32) -> Vec<u8> {
    format!("\x1b]133;D;{code}\x07").into_bytes()
}

/// A prompt, a typed command line, then its output and its exit code.
fn run(t: &mut Terminal, line: &str, output: &str, code: Option<i32>) {
    t.feed(A);
    t.feed(b"$ ");
    t.feed(B);
    t.feed(line.as_bytes());
    t.feed(b"\r\n");
    t.feed(C);
    t.feed(output.as_bytes());
    match code {
        Some(code) => t.feed(&d(code)),
        None => t.feed(b"\x1b]133;D\x07"),
    }
}

fn hits(t: &Terminal, needle: &str) -> Vec<SearchHit> {
    t.active_grid().search_chunk(needle, None, usize::MAX, usize::MAX).hits
}

fn command_of(t: &Terminal, needle: &str) -> Option<u64> {
    let found = hits(t, needle);
    assert_eq!(found.len(), 1, "{needle}");
    found[0].command
}

fn owners(t: &Terminal) -> Vec<RowOwner> {
    let g = t.active_grid();
    (0..g.rows()).map(|r| g.row_owner(r)).collect()
}

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
    assert_eq!(t.commands().get(first).unwrap().status, CommandStatus::Abandoned);
    assert_eq!(t.commands().get(second).unwrap().status, CommandStatus::Completed(Some(1)));
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
    assert_eq!(t.commands().get(one).unwrap().status, CommandStatus::Abandoned);
    assert_eq!(t.commands().get(command_of(&t, "two").unwrap()).unwrap().status, CommandStatus::Running);
}

#[test]
fn d_without_a_code_is_finished_but_not_a_success() {
    let mut t = Terminal::new(30, 8);
    run(&mut t, "x", "out\r\n", None);
    let id = command_of(&t, "out").unwrap();
    assert_eq!(t.commands().get(id).unwrap().status, CommandStatus::Completed(None));
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
    for seq in [&b"\x1b[2X"[..], b"\x1b[2@", b"\x1b[2P", b"\x1b[K", b"\x1b[1K", b"   "] {
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
    assert!(t.take_events().contains(&TerminalEvent::CommandStart { id: None }));
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

#[test]
fn ids_keep_counting_across_a_reset() {
    let mut t = Terminal::new(20, 4);
    t.feed(C);
    t.feed(b"\x1bc");
    assert_eq!(t.commands().records().len(), 0);
    t.feed(C);
    assert!(t.take_events().contains(&TerminalEvent::CommandStart { id: Some(2) }));
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
    copy.import_checkpoint(&t.export_checkpoint().unwrap()).unwrap();
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
    copy.import_checkpoint(&t.export_checkpoint().unwrap()).unwrap();
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
    assert!(copy.take_events().contains(&TerminalEvent::CommandStart { id: Some(3) }));
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
    let blank = (0..8).filter(|&r| copy.active_grid().row_owner(r) == RowOwner::Empty).count();
    assert!(blank > 0);
    copy.feed(C);
    copy.feed(b"\x1b[8;1Hnew");
    assert!(command_of(&copy, "new").is_some());
}

// -- The host side: search hits carry the record, start times by token. --

fn core_with_finished_command() -> (TakoCore, u64) {
    let core = TakoCore::new(30, 8);
    // Start and end in one feed: the host sees the start after the end.
    core.feed(b"\x1b]133;C\x07output\r\n\x1b]133;D;3\x07".to_vec());
    let id = core
        .take_events()
        .into_iter()
        .find_map(|e| match e {
            tako_core::ffi::FfiEvent::CommandStart { id } => id,
            _ => None,
        })
        .unwrap();
    (core, id)
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
    assert_eq!(chunk.hits[0].command.as_ref().unwrap().started_at_ms, Some(1000));
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
    assert!(input.chars().count() <= MAX_INPUT_CHARS, "{}", input.chars().count());
    assert!(input.contains('\n'));
    assert!(rec.input_truncated);
    let mut copy = Terminal::new(50, 30);
    copy.import_checkpoint(&t.export_checkpoint().unwrap()).unwrap();
    assert_eq!(copy.commands().get(id).unwrap().input.as_deref(), Some(input.as_str()));
}

#[test]
fn rows_moving_under_the_command_line_drop_it() {
    let cases: [(&str, &[u8]); 7] = [
        ("erase below from above", b"\x1b[1;1H\x1b[J\x1b[2;3Hreplacement"),
        ("erase above from below", b"\x1b[3;1H\x1b[1J\x1b[2;3Hreplacement"),
        ("insert line", b"\x1b[1;1H\x1b[L\x1b[1;1Hreplacement"),
        ("delete line", b"\x1b[1;1H\x1b[M\x1b[1;1Hreplacement"),
        ("region scroll up", b"\x1b[1;3r\x1b[3;1H\n\x1b[r\x1b[1;1Hreplacement"),
        ("region scroll down", b"\x1b[1;3r\x1b[1;1H\x1bM\x1b[r\x1b[1;1Hreplacement"),
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
        run(&mut t, &format!("cmd {i}"), &format!("out {i}\r\nmixed "), Some(i));
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
    assert_eq!(rec.input.as_deref(), Some("for x in a b\n> do echo $x; done"));
    // A primary P is a new prompt: the next command line starts after it.
    t.feed(&d(0));
    t.feed(b"\x1b]133;P;k=i\x07$ \x1b]133;B\x07ls\r\n");
    t.feed(C);
    t.feed(b"listed\r\n");
    let rec = t.commands().get(command_of(&t, "listed").unwrap()).unwrap();
    assert_eq!(rec.input.as_deref(), Some("ls"));
}

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
    core.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07false\r\n\x1b]133;C\x07bad\r\n\x1b]133;D;1\x07".to_vec());
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
    let (rec, out) = t.last_command(10, 1000).expect("the newest command is kept");
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
    core.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07ok\r\n\x1b]133;C\x07fine\r\n\x1b]133;D;0\x07".to_vec());
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
        t.active_grid().retained_semantic_prompt(cmd3_mark.retained_row),
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
    restored.import_checkpoint(&data).expect("import checkpoint");

    // Command output begins and finishes in restored terminal
    restored.feed(b"\x1b]133;C\x07hello\r\n\x1b]133;D;0\x07");

    let marks = restored.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].status, CommandMarkStatus::Success);
    assert_eq!(marks[0].retained_row, 0);
}




