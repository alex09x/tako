/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::{CommandMarkStatus, Terminal};

#[test]
fn sticky_command_header_tracks_output_and_scroll_to_prompt() {
    let mut t = Terminal::new(30, 10);
    // Command 1: prompt at row 0, command line "cat file.txt", prints 30 lines
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07cat file.txt\r\n\x1b]133;C\x07");
    for i in 1..=30 {
        t.feed(format!("line {}\r\n", i).as_bytes());
    }
    t.feed(b"\x1b]133;D;0\x07");

    // Live screen sits at the bottom (viewport_offset == 0).
    // Prompt at row 0 has scrolled into scrollback, so vp_top is around row 21.
    // vp_top is within output of "cat file.txt" (rows 1..31).
    let header = t
        .sticky_command_header()
        .expect("sticky header must be pinned while scrolled into output");
    assert_eq!(header.command, "cat file.txt");
    assert_eq!(header.prompt_retained_row, 0);
    assert_eq!(header.status, CommandMarkStatus::Success);

    // Clicking / jumping to prompt:
    assert!(t.scroll_to_prompt(header.prompt_retained_row));
    // Viewport is now scrolled so prompt_retained_row (0) is at top of screen (vp_top == 0).
    // Prompt is visible on screen, so sticky header must be None!
    assert!(
        t.sticky_command_header().is_none(),
        "header must unpin when prompt is visible on screen"
    );

    // Scroll back down into output:
    t.scroll_viewport_down(10);
    let header2 = t
        .sticky_command_header()
        .expect("sticky header must re-pin when scrolled back into output");
    assert_eq!(header2.command, "cat file.txt");

    // Alternate screen buffer must suppress sticky header:
    t.feed(b"\x1b[?1049h");
    assert!(
        t.sticky_command_header().is_none(),
        "alternate screen must suppress sticky header"
    );
    t.feed(b"\x1b[?1049l");
    assert!(
        t.sticky_command_header().is_some(),
        "sticky header restores on primary screen"
    );
}

#[test]
fn sticky_command_header_multiple_commands_and_zero_output() {
    use tako_core::terminal::CommandMarkStatus;

    let mut t = Terminal::new(30, 10);
    // Command 1: zero output (e.g. true)
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07true\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    // Command 2: prints 25 lines
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07make all\r\n\x1b]133;C\x07");
    for i in 1..=25 {
        t.feed(format!("build {}\r\n", i).as_bytes());
    }
    t.feed(b"\x1b]133;D;1\x07");
    // Idle prompt 3 at bottom
    t.feed(b"\x1b]133;A\x07$ ");

    // While sitting at bottom, vp_top is in output of "make all"
    let header = t
        .sticky_command_header()
        .expect("header should pin make all");
    assert_eq!(header.command, "make all");
    assert_eq!(header.status, CommandMarkStatus::Error(Some(1)));

    // Scroll all the way to prompt of make all:
    t.scroll_to_prompt(header.prompt_retained_row);
    // make all's prompt is at top of viewport:
    assert!(t.sticky_command_header().is_none());

    // Scroll up to row 0 (prompt of true):
    t.scroll_to_prompt(0);
    // true produced zero output, so no header:
    assert!(t.sticky_command_header().is_none());
}

#[test]
fn sticky_command_header_requires_osc133_boundaries_and_command_text() {
    let mut t = Terminal::new(30, 10);
    // Plain text without OSC 133
    for i in 1..=30 {
        t.feed(format!("unmarked {}\r\n", i).as_bytes());
    }
    assert!(
        t.sticky_command_header().is_none(),
        "must never appear without OSC 133 boundaries"
    );

    // Command without 133;B (empty input text)
    t.feed(b"\x1b]133;A\x07$ \x1b]133;C\x07");
    for i in 1..=20 {
        t.feed(format!("no-b {}\r\n", i).as_bytes());
    }
    t.feed(b"\x1b]133;D;0\x07");
    assert!(
        t.sticky_command_header().is_none(),
        "must not appear without command name"
    );
}

#[test]
fn sticky_command_header_running_command() {
    use tako_core::terminal::CommandMarkStatus;

    let mut t = Terminal::new(30, 10);
    // Running command (no 133;D yet)
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07streaming-job\r\n\x1b]133;C\x07");
    for i in 1..=25 {
        t.feed(format!("data {}\r\n", i).as_bytes());
    }

    let header = t
        .sticky_command_header()
        .expect("running command output must pin header");
    assert_eq!(header.command, "streaming-job");
    assert_eq!(header.status, CommandMarkStatus::Running);

    // Scroll to prompt
    t.scroll_to_prompt(header.prompt_retained_row);
    assert!(t.sticky_command_header().is_none());
}

#[test]
fn sticky_command_header_unowned_text_between_commands_suppresses_header() {
    let mut t = Terminal::new(30, 10);
    // Command 1: prompt at row 0, 20 lines of output, ends with 133;D
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07git log\r\n\x1b]133;C\x07");
    for i in 1..=20 {
        t.feed(format!("commit {}\r\n", i).as_bytes());
    }
    t.feed(b"\x1b]133;D;0\x07");

    // Shell hook prints 12 unowned lines (not wrapped in 133;C/D)
    for i in 1..=12 {
        t.feed(format!("hook line {}\r\n", i).as_bytes());
    }

    // Prompt 2 starts
    t.feed(b"\x1b]133;A\x07$ ");

    // While sitting at bottom (scrollback_offset == 0), the visible viewport spans
    // the unowned hook lines and prompt 2. vp_top is past the last row of "git log".
    assert!(
        t.sticky_command_header().is_none(),
        "unowned shell hook text after 133;D must not show the previous command header"
    );

    // Scroll up into git log's output:
    // Scroll back by 10 lines:
    t.scroll_viewport_up(10);
    let header = t
        .sticky_command_header()
        .expect("should pin git log when scrolled into its output");
    assert_eq!(header.command, "git log");
}

#[test]
fn sticky_command_header_preserves_header_when_prompt_evicted_from_scrollback() {
    // 5 lines viewport, 10 lines scrollback limit
    let mut t = Terminal::with_scrollback(30, 5, 10);
    t.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07cargo test\r\n\x1b]133;C\x07");
    for i in 1..=30 {
        t.feed(format!("test line {}\r\n", i).as_bytes());
    }
    t.feed(b"\x1b]133;D;0\x07");

    // The prompt line (line 0) was evicted because 30 lines exceeded the 10-line scrollback capacity:
    assert!(
        t.first_retained_line() > 0,
        "prompt line must have been evicted"
    );
    assert!(
        t.command_marks().is_empty(),
        "command_marks must omit evicted prompt"
    );

    // Scroll up into retained scrollback:
    t.scroll_viewport_up(8);
    let header = t
        .sticky_command_header()
        .expect("header must be preserved even when prompt is evicted");
    assert_eq!(header.command, "cargo test");
    assert_eq!(
        header.prompt_retained_row, 0,
        "evicted prompt falls back to row 0"
    );

    // Click jump to prompt (row 0):
    assert!(t.scroll_to_prompt(header.prompt_retained_row));
    assert_eq!(
        t.viewport_offset(),
        10,
        "scrolled to top of retained scrollback"
    );
}
