// OSC 133 command lifecycle as host events.
//
// The tab-bar crab indicator is driven by these: it starts running on a
// command start and settles on the end, coloured by the exit code. Row marks
// alone are not enough -- the host needs to know *when*.

use tako_core::terminal::{Terminal, TerminalEvent};

/// A command that runs and succeeds reports both a start and an end.
#[test]
fn command_start_and_end_emit_events() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]133;C\x07");
    term.feed(b"output\r\n");
    term.feed(b"\x1b]133;D;0\x07");
    let events = term.take_events();
    assert!(events.contains(&TerminalEvent::CommandStart));
    assert!(events.contains(&TerminalEvent::CommandEnd { exit_code: Some(0) }));
}

/// A failing command carries its exit code, which is what turns the crab red.
#[test]
fn command_end_carries_exit_code() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]133;D;101\x07");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::CommandEnd { exit_code: Some(101) }]
    );
}

/// `OSC 133;D` with no code is still an end, just without a status.
#[test]
fn command_end_without_code() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]133;D\x07");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::CommandEnd { exit_code: None }]
    );
}

/// A prompt start is not a command start: the crab must stay still while the
/// user is only typing at the prompt.
#[test]
fn prompt_start_emits_no_command_event() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]133;A\x07");
    term.feed(b"\x1b]133;B\x07");
    assert!(term.take_events().is_empty());
}

/// Events drain, so a host that polls every frame sees each command once.
#[test]
fn events_drain_between_commands() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]133;C\x07");
    assert_eq!(term.take_events(), vec![TerminalEvent::CommandStart]);
    assert!(term.take_events().is_empty());
    term.feed(b"\x1b]133;D;0\x07");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::CommandEnd { exit_code: Some(0) }]
    );
}
