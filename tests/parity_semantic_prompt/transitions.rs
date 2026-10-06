/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::grid::SemanticPrompt;
use tako_core::terminal::{SemanticContent, Terminal};

/// Upstream (stream): "semantic prompt fresh line"
#[test]
fn semantic_prompt_fresh_line() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"Hello");
    term.feed(b"\x1b]133;L\x07");
    assert_eq!(term.cursor(), (1, 0));
}

/// Upstream (stream): "semantic prompt fresh line new prompt"
#[test]
fn semantic_prompt_fresh_line_new_prompt() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"Hello");
    term.feed(b"\x1b]133;A\x07");
    assert_eq!(term.cursor(), (1, 0));
    assert_eq!(term.semantic_content(), SemanticContent::Prompt);
    assert_eq!(
        term.active_grid().row_semantic_prompt(1),
        SemanticPrompt::Prompt
    );
}

/// Upstream (stream): "semantic prompt end of input, then start output"
#[test]
fn semantic_prompt_end_of_input_then_start_output() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"Hello");
    term.feed(b"\x1b]133;A\x07");
    term.feed(b"prompt$ ");
    term.feed(b"\x1b]133;B\x07");
    assert_eq!(term.semantic_content(), SemanticContent::Input);
    term.feed(b"\x1b]133;C\x07");
    assert_eq!(term.semantic_content(), SemanticContent::Output);
}

/// Upstream (stream): "semantic prompt prompt_start"
#[test]
fn semantic_prompt_prompt_start() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b]133;P\x07");
    assert_eq!(term.semantic_content(), SemanticContent::Prompt);
    assert_eq!(
        term.active_grid().row_semantic_prompt(0),
        SemanticPrompt::Prompt
    );
}

/// Upstream (stream): "semantic prompt new_command at column zero" -- a
/// fresh-line request at column 0 must not consume a line.
#[test]
fn semantic_prompt_new_command_at_column_zero() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b]133;A\x07");
    assert_eq!(term.cursor(), (0, 0));
    assert_eq!(
        term.active_grid().row_semantic_prompt(0),
        SemanticPrompt::Prompt
    );
}

#[test]
fn prompt_navigation_jumps_between_prompts_in_scrollback() {
    let mut term = Terminal::new(30, 5);
    // Command 1
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07echo cmd1\r\n\x1b]133;C\x07out1.1\r\nout1.2\r\nout1.3\r\n\x1b]133;D;0\x07");
    // Command 2
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07echo cmd2\r\n\x1b]133;C\x07out2.1\r\nout2.2\r\nout2.3\r\n\x1b]133;D;0\x07");
    // Command 3
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07echo cmd3\r\n\x1b]133;C\x07out3.1\r\nout3.2\r\nout3.3\r\n\x1b]133;D;0\x07");
    // Command 4 prompt
    term.feed(b"\x1b]133;A\x07$ ");

    // We have lines in scrollback and screen.
    assert!(term.active_grid().scrollback_len() > 0);
    assert_eq!(term.viewport_offset(), 0);

    // Cmd+Up: jump to previous prompt (Command 3 prompt or earlier)
    let jumped = term.scroll_to_previous_prompt();
    assert!(jumped);
    let offset1 = term.viewport_offset();
    assert!(offset1 > 0);

    // Cmd+Up again: jump further up
    let jumped2 = term.scroll_to_previous_prompt();
    assert!(jumped2);
    let offset2 = term.viewport_offset();
    assert!(offset2 > offset1);

    // Cmd+Down: jump back forward
    let jumped_down = term.scroll_to_next_prompt();
    assert!(jumped_down);
    let offset_down = term.viewport_offset();
    assert!(offset_down < offset2);

    // Cmd+Down until bottom
    term.scroll_to_next_prompt();
    assert_eq!(term.viewport_offset(), 0);

    // Cmd+Down at bottom returns false
    assert!(!term.scroll_to_next_prompt());
}
