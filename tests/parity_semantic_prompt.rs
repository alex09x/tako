// 1:1 ports of upstream OSC 133 semantic-prompt tests
// (upstream `Terminal` + upstream `stream_terminal`).

use tako_core::grid::SemanticPrompt;
use tako_core::terminal::{SemanticContent, Terminal};

/// Upstream test: "Terminal: cursorIsAtPrompt"
#[test]
fn cursor_is_at_prompt() {
    let mut term = Terminal::new(10, 3);
    assert!(!term.cursor_is_at_prompt());
    term.feed(b"\x1b]133;P\x07"); // prompt_start
    assert!(term.cursor_is_at_prompt());
    term.feed(b"$ ");

    term.feed(b"\x1b]133;B\x07"); // end_prompt_start_input
    assert!(term.cursor_is_at_prompt());
    term.feed(b"ls");

    term.feed(b"\x1b]133;C\x07"); // start output; cursor not at x=0
    assert!(term.cursor_is_at_prompt()); // row still marked
    term.feed(b"\r\n");
    assert!(!term.cursor_is_at_prompt());

    term.feed(b"\r\n");
    term.feed(b"\x1b]133;P\x07");
    assert!(term.cursor_is_at_prompt());
}

/// Upstream test: "Terminal: cursorIsAtPrompt alternate screen"
#[test]
fn cursor_is_at_prompt_alternate_screen() {
    let mut term = Terminal::new(3, 2);
    assert!(!term.cursor_is_at_prompt());
    term.feed(b"\x1b]133;P\x07");
    assert!(term.cursor_is_at_prompt());

    term.feed(b"\x1b[?1049h"); // alternate screen is never a prompt
    assert!(!term.cursor_is_at_prompt());
    term.feed(b"\x1b]133;P\x07");
    assert!(!term.cursor_is_at_prompt());
}

/// Upstream test: "Terminal: index in prompt mode marks new row as prompt continuation"
#[test]
fn index_in_prompt_mode_marks_new_row_as_prompt_continuation() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]133;P\x07");
    term.feed(b"hello");
    assert_eq!(term.active_grid().row_semantic_prompt(0), SemanticPrompt::Prompt);
    term.feed(b"\r\n");
    assert_eq!(
        term.active_grid().row_semantic_prompt(1),
        SemanticPrompt::PromptContinuation
    );
}

/// Upstream test: "Terminal: index in input mode does not mark new row as prompt"
/// (upstream: input mode DOES mark continuation; the name is historical)
#[test]
fn index_in_input_mode_marks_new_row_as_prompt_continuation() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]133;P\x07");
    term.feed(b"$ ");
    term.feed(b"\x1b]133;B\x07");
    term.feed(b"echo \\");
    term.feed(b"\r\n");
    assert_eq!(
        term.active_grid().row_semantic_prompt(1),
        SemanticPrompt::PromptContinuation
    );
    assert_eq!(term.semantic_content(), SemanticContent::Input);
}

/// Upstream test: "Terminal: index in output mode does not mark new row as prompt"
#[test]
fn index_in_output_mode_does_not_mark_new_row_as_prompt() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]133;P\x07");
    term.feed(b"$ ");
    term.feed(b"\x1b]133;C\x07"); // output mode
    term.feed(b"\r\n");
    assert_eq!(term.active_grid().row_semantic_prompt(1), SemanticPrompt::Unset);
}

/// Upstream test: "Terminal: OSC133C at x=0 on prompt row clears prompt mark"
#[test]
fn osc133c_at_x0_on_prompt_row_clears_prompt_mark() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]133;P\x07");
    term.feed(b"$ echo \\");
    term.feed(b"\r\n");
    assert_eq!(
        term.active_grid().row_semantic_prompt(1),
        SemanticPrompt::PromptContinuation
    );
    term.feed(b"\x1b]133;C\x07"); // at column 0 -> clears
    assert_eq!(term.active_grid().row_semantic_prompt(1), SemanticPrompt::Unset);
}

/// Upstream test: "Terminal: OSC133C at x>0 on prompt row does not clear prompt mark"
#[test]
fn osc133c_at_x_gt0_on_prompt_row_does_not_clear_prompt_mark() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]133;P\x07");
    term.feed(b"$ ");
    term.feed(b"\r\n");
    term.feed(b"\x1b]133;P;k=c\x07"); // explicit continuation mark
    term.feed(b"> ");
    assert_eq!(
        term.active_grid().row_semantic_prompt(1),
        SemanticPrompt::PromptContinuation
    );
    term.feed(b"\x1b]133;C\x07"); // cursor at x>0 -> mark survives
    assert_eq!(
        term.active_grid().row_semantic_prompt(1),
        SemanticPrompt::PromptContinuation
    );
}

/// Upstream test: "Terminal: multiple newlines in prompt mode marks all rows"
#[test]
fn multiple_newlines_in_prompt_mode_marks_all_rows() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]133;P\x07");
    term.feed(b"line1\r\nline2\r\nline3");
    assert_eq!(term.active_grid().row_semantic_prompt(0), SemanticPrompt::Prompt);
    assert_eq!(
        term.active_grid().row_semantic_prompt(1),
        SemanticPrompt::PromptContinuation
    );
    assert_eq!(
        term.active_grid().row_semantic_prompt(2),
        SemanticPrompt::PromptContinuation
    );
}

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
    assert_eq!(term.active_grid().row_semantic_prompt(1), SemanticPrompt::Prompt);
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
    assert_eq!(term.active_grid().row_semantic_prompt(0), SemanticPrompt::Prompt);
}

/// Upstream (stream): "semantic prompt new_command at column zero" -- a
/// fresh-line request at column 0 must not consume a line.
#[test]
fn semantic_prompt_new_command_at_column_zero() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"\x1b]133;A\x07");
    assert_eq!(term.cursor(), (0, 0));
    assert_eq!(term.active_grid().row_semantic_prompt(0), SemanticPrompt::Prompt);
}
