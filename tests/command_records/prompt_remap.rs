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
use tako_core::terminal::{CommandMarkStatus, Terminal};

#[test]
fn continuation_prompts_preserve_initial_prompt_line_and_emit_marks() {
    let mut t = Terminal::new(40, 10);
    // Line 0: Initial prompt
    t.feed(b"\x1b]133;A\x07$ prompt line 1\r\n");
    // Line 1: Continuation prompt (k=c)
    t.feed(b"\x1b]133;A;k=c\x07> prompt line 2\r\n");
    // Line 2: Second continuation prompt (k=c)
    t.feed(b"\x1b]133;A;k=c\x07> prompt line 3\r\n");
    // Command line input
    t.feed(b"\x1b]133;B\x07echo multiline\r\n");
    // Command execution and completion
    t.feed(b"\x1b]133;C\x07output\r\n\x1b]133;D;0\x07");

    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].prompt_line, 0);
    assert_eq!(marks[0].retained_row, 0);
    assert_eq!(marks[0].status, CommandMarkStatus::Success);

    // Reflow: resize terminal to narrower width
    t.resize(20, 10);
    let marks_after = t.command_marks();
    assert_eq!(marks_after.len(), 1);
    assert_eq!(marks_after[0].status, CommandMarkStatus::Success);
    assert_eq!(
        t.active_grid()
            .retained_semantic_prompt(marks_after[0].retained_row),
        SemanticPrompt::Prompt
    );
}

#[test]
fn prompt_mark_tracked_when_scrollback_is_zero() {
    let mut t = Terminal::new(40, 5);
    t.set_scrollback_capacity(0);

    // Initial prompt on row 2
    t.feed(b"\r\n\r\n\x1b]133;A\x07$ \x1b]133;C\x07sleep 10\r\n");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 2);
    assert_eq!(marks[0].status, CommandMarkStatus::Running);

    // One more line reaches bottom row (row 4)
    t.feed(b"running...\r\n");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 2);

    // Printing newline at bottom causes scroll up by 1: prompt moves to row 1
    t.feed(b"scroll 1\r\n");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 1);
    assert_eq!(
        t.active_grid()
            .retained_semantic_prompt(marks[0].retained_row),
        SemanticPrompt::Prompt
    );

    // Another scroll up: prompt moves to row 0
    t.feed(b"scroll 2\r\n");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 0);
    assert_eq!(
        t.active_grid()
            .retained_semantic_prompt(marks[0].retained_row),
        SemanticPrompt::Prompt
    );

    // Another scroll: prompt scrolls off the screen; with 0 scrollback, it is evicted
    t.feed(b"scroll 3\r\n");
    let marks = t.command_marks();
    assert!(
        marks.is_empty(),
        "evicted prompt with zero scrollback has no mark"
    );
}

#[test]
fn prompt_marks_remap_through_vertical_row_edits() {
    let mut t = Terminal::new(40, 10);
    // Write prompt at row 2
    t.feed(b"\r\n\r\n\x1b]133;A\x07$ \x1b]133;C\x07cmd\r\n\x1b]133;D;0\x07");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 2);
    assert_eq!(marks[0].prompt_line, 2);

    // 1. Insert line above prompt: cursor at row 1 (1-based: 2), CSI 1 L
    t.feed(b"\x1b[2;1H\x1b[1L");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 3);
    assert_eq!(marks[0].prompt_line, 3);
    assert_eq!(
        t.active_grid().retained_semantic_prompt(3),
        SemanticPrompt::Prompt
    );

    // 2. Delete line above prompt: cursor at row 1 (1-based: 2), CSI 1 M
    t.feed(b"\x1b[2;1H\x1b[1M");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 2);
    assert_eq!(marks[0].prompt_line, 2);
    assert_eq!(
        t.active_grid().retained_semantic_prompt(2),
        SemanticPrompt::Prompt
    );

    // 3. Scroll region down: CSI 1 T
    t.feed(b"\x1b[1T");
    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 3);
    assert_eq!(marks[0].prompt_line, 3);
    assert_eq!(
        t.active_grid().retained_semantic_prompt(3),
        SemanticPrompt::Prompt
    );

    // 4. Delete the line containing prompt: cursor at row 3 (1-based: 4), CSI 1 M
    t.feed(b"\x1b[4;1H\x1b[1M");
    let marks = t.command_marks();
    assert!(
        marks.is_empty(),
        "deleted prompt line should have its mark removed"
    );
}

#[test]
fn prompt_marks_remap_below_top_anchored_scroll_region() {
    let mut t = Terminal::new(40, 10);
    // Write prompt 1 at row 0 (inside upcoming region 0..=2)
    t.feed(b"\x1b]133;A\x07$ \x1b]133;C\x07cmd1\r\n\x1b]133;D;0\x07");

    // Move cursor to row 4 (1-based: 5, below upcoming region 0..=2)
    t.feed(b"\x1b[5;1H\x1b]133;A\x07$ \x1b]133;C\x07cmd2\r\n\x1b]133;D;0\x07");

    let marks = t.command_marks();
    assert_eq!(marks.len(), 2);
    assert_eq!(marks[0].retained_row, 0);
    assert_eq!(marks[0].prompt_line, 0);
    assert_eq!(marks[1].retained_row, 4);
    assert_eq!(marks[1].prompt_line, 4);

    // Set scroll region to rows 1..3 (0-based: 0..=2)
    t.feed(b"\x1b[1;3r");

    // Scroll region up by 2 lines: CSI 2 S
    t.feed(b"\x1b[2S");

    let marks = t.command_marks();
    assert_eq!(marks.len(), 2, "both marks must be preserved");

    // Prompt 1 entered scrollback (stashed at history line 0)
    assert_eq!(marks[0].prompt_line, 0);
    assert_eq!(marks[0].retained_row, 0);

    // Prompt 2 remained at screen row 4, but 2 rows were added to scrollback,
    // so retained_row is now 6 and prompt_line is remapped to 6.
    assert_eq!(marks[1].prompt_line, 6);
    assert_eq!(marks[1].retained_row, 6);
    assert_eq!(
        t.active_grid().retained_semantic_prompt(6),
        SemanticPrompt::Prompt
    );
}

#[test]
fn prompt_marks_remap_when_prompt_begins_on_wrapped_row() {
    let mut t = Terminal::new(10, 10);
    // Print 15 characters to wrap line 0 onto line 1
    t.feed(b"1234567890abcde");
    // Issue OSC 133;P on the wrapped line 1
    t.feed(b"\x1b]133;P\x07$ \x1b]133;C\x07cmd\r\n\x1b]133;D;0\x07");

    let marks = t.command_marks();
    assert_eq!(marks.len(), 1);
    assert_eq!(marks[0].retained_row, 1);
    assert_eq!(marks[0].prompt_line, 1);

    // Widen terminal to 30 columns: line 0 and line 1 merge into a single row 0
    t.resize(30, 10);

    let marks = t.command_marks();
    assert_eq!(
        marks.len(),
        1,
        "mark must be retained after widening merges wrapped row"
    );
    assert_eq!(marks[0].retained_row, 0, "mark must remap to merged row 0");
    assert_eq!(marks[0].prompt_line, 0, "prompt_line must remap to 0");
    assert_eq!(
        t.active_grid().retained_semantic_prompt(0),
        SemanticPrompt::Prompt
    );

    // Now narrow terminal to 5 columns: row 0 wraps into multiple rows
    t.resize(5, 10);

    let marks = t.command_marks();
    assert_eq!(marks.len(), 1, "mark must be retained after narrowing");
    assert_eq!(
        marks[0].retained_row, 0,
        "mark must be at start of prompt line (row 0)"
    );
    assert_eq!(marks[0].prompt_line, 0, "prompt_line must remain 0");
    assert_eq!(
        t.active_grid().retained_semantic_prompt(0),
        SemanticPrompt::Prompt
    );
    assert_eq!(
        t.active_grid().retained_semantic_prompt(1),
        SemanticPrompt::PromptContinuation
    );
}
