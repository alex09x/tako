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
use tako_core::terminal::Terminal;

#[test]
fn prompt_navigation_falls_back_when_no_marks() {
    let mut term = Terminal::new(30, 5);
    // Plain text without OSC 133
    term.feed(b"line1\r\nline2\r\nline3\r\nline4\r\nline5\r\nline6\r\n");
    assert!(!term.scroll_to_previous_prompt());
    assert!(!term.scroll_to_next_prompt());

    // Alternate screen: never navigates
    term.feed(b"\x1b[?1049h");
    term.feed(b"\x1b]133;A\x07$ \r\n");
    assert!(!term.scroll_to_previous_prompt());
    assert!(!term.scroll_to_next_prompt());
}

#[test]
fn select_command_output_bounds_output_cleanly() {
    let mut term = Terminal::new(30, 10);
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07test command\r\n\x1b]133;C\x07result line 1\r\nresult line 2\r\n\x1b]133;D;0\x07");
    term.feed(b"\x1b]133;A\x07$ ");

    // We are at the prompt after the command finished.
    // Cmd+Shift+A should select the previous command's output: "result line 1\nresult line 2"
    let selected = term.select_command_output();
    assert!(selected);
    assert!(term.has_selection());
    let text = term.selected_text().expect("selected text");
    assert_eq!(text, "result line 1\nresult line 2");
    // Ensure no prompt bleed
    assert!(!text.contains('$'));
    assert!(!text.contains("test command"));
}

#[test]
fn select_command_output_with_running_command() {
    let mut term = Terminal::new(30, 10);
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07run_agent\r\n\x1b]133;C\x07step 1 complete\r\nstep 2 working...\r\n");

    // Command is still running (no 133;D yet)
    let selected = term.select_command_output();
    assert!(selected);
    assert!(term.has_selection());
    let text = term.selected_text().expect("selected text");
    assert_eq!(text, "step 1 complete\nstep 2 working...");
}

#[test]
fn select_command_output_no_output_returns_false() {
    let mut term = Terminal::new(30, 10);
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07true\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    term.feed(b"\x1b]133;A\x07$ ");

    // `true` produced no output
    let selected = term.select_command_output();
    assert!(!selected);
}

#[test]
fn prompt_marks_preserved_on_resize_into_scrollback() {
    let mut term = Terminal::new(20, 10);
    // Write a prompt and fill lines so rows are occupied
    term.feed(b"\x1b]133;A\x07prompt1$ \r\n");
    for i in 1..10 {
        term.feed(format!("output {}\r\n", i).as_bytes());
    }

    // Shrink height from 10 to 5, pushing prompt1 into scrollback
    term.resize(20, 5);
    assert!(term.active_grid().scrollback_len() > 0);
    assert_eq!(
        term.active_grid()
            .scrollback_rows()
            .next()
            .unwrap()
            .semantic,
        SemanticPrompt::Prompt
    );

    // Prompt navigation in scrollback works after height shrink
    assert!(term.scroll_to_previous_prompt());
    assert!(term.viewport_offset() > 0);

    // Reflow resize: shrink width from 20 to 10
    term.scroll_viewport_bottom();
    term.resize(10, 5);
    assert_eq!(
        term.active_grid()
            .scrollback_rows()
            .next()
            .unwrap()
            .semantic,
        SemanticPrompt::Prompt
    );
    assert!(term.scroll_to_previous_prompt());
}

#[test]
fn checkpoint_roundtrip_preserves_scrollback_prompt_marks() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]133;A\x07prompt1$ \r\n");
    // Push prompt1 into scrollback by filling rows
    for i in 0..10 {
        term.feed(format!("line {}\r\n", i).as_bytes());
    }
    term.feed(b"\x1b]133;A\x07prompt2$ ");

    assert!(term.active_grid().scrollback_len() > 0);
    let blob_v5 = term.export_checkpoint().unwrap();

    let mut restored = Terminal::new(20, 5);
    restored.import_checkpoint(&blob_v5).unwrap();

    // Verify restored terminal has prompt mark in scrollback
    assert_eq!(
        restored.active_grid().scrollback_len(),
        term.active_grid().scrollback_len()
    );
    let sb_prompt = restored
        .active_grid()
        .scrollback_rows()
        .any(|row| row.semantic == SemanticPrompt::Prompt);
    assert!(sb_prompt, "restored scrollback must preserve prompt marker");

    // Navigating back finds the scrollback prompt
    assert!(restored.scroll_to_previous_prompt());
    assert!(restored.viewport_offset() > 0);

    // Older v4 export exports cleanly without scrollback prompts
    let blob_v4 = term.export_checkpoint_version(4, 0).unwrap();
    let mut restored_v4 = Terminal::new(20, 5);
    restored_v4.import_checkpoint(&blob_v4).unwrap();
    let v4_sb_has_prompt = restored_v4
        .active_grid()
        .scrollback_rows()
        .any(|row| row.semantic != SemanticPrompt::Unset);
    assert!(
        !v4_sb_has_prompt,
        "v4 checkpoint restore initializes scrollback prompts to Unset"
    );
}

#[test]
fn select_command_output_restricts_to_contiguous_run_around_target() {
    let mut term = Terminal::new(30, 10);
    // Command starts
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07jumpy_cmd\r\n\x1b]133;C\x07");
    term.feed(b"first block\r\n");
    // Jump cursor down leaving an unowned/empty gap (CUP: row 5, col 1)
    term.feed(b"\x1b[5;1Hsecond block\r\n\x1b]133;D;0\x07");
    term.feed(b"\x1b]133;A\x07$ ");

    // Selecting output at prompt should restrict to the contiguous run around target (second block)
    let selected = term.select_command_output();
    assert!(selected);
    let text = term.selected_text().expect("selected text");
    assert_eq!(text, "second block");
    assert!(!text.contains("first block"));
}

#[test]
fn select_command_output_preserves_interior_blank_lines() {
    let mut term = Terminal::new(30, 10);
    term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07printf\r\n\x1b]133;C\x07first\r\n\r\nsecond\r\n\x1b]133;D;0\x07");
    term.feed(b"\x1b]133;A\x07$ ");

    let selected = term.select_command_output();
    assert!(selected);
    assert!(term.has_selection());
    let text = term.selected_text().expect("selected text");
    assert_eq!(text, "first\n\nsecond");
    // Ensure no prompt bleed
    assert!(!text.contains('$'));
}
