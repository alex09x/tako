/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: setCursorPos (original test)" -- the pending-wrap
/// portion: printing in the last column parks the cursor there; the wrap is
/// deferred to the next printable.
#[test]
fn printing_last_column_sets_pending_wrap_instead_of_wrapping_immediately() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert_eq!(term.cursor(), (0, 4)); // parked, NOT already on row 1
    assert!(!term.active_grid().is_line_wrapped(0)); // no wrap recorded yet
    term.feed(b"F");
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'F');
    // The continuation marker belongs to the destination row. This keeps
    // logical-line extraction and scrollback reflow aligned on one meaning:
    // `wrapped(row)` says that `row` continues the row immediately above it.
    assert!(!term.active_grid().is_line_wrapped(0));
    assert!(term.active_grid().is_line_wrapped(1));
}

/// Upstream test: "Terminal: carriage return unsets pending wrap"
#[test]
fn carriage_return_unsets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\rX");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'X');
    assert_eq!(term.cursor(), (0, 1)); // still on row 0: the wrap never fired
}

/// Upstream test: "Terminal: linefeed unsets pending wrap"
#[test]
fn linefeed_unsets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\nX");
    // LF moved to row 1 keeping the column; X prints there, no double-advance.
    assert_eq!(term.active_grid().get(1, 4).unwrap().char, 'X');
    assert_eq!(term.cursor(), (1, 4)); // parked again after printing in the last column
}

/// Upstream test: "Terminal: cursorUp resets wrap"
#[test]
fn cursor_up_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[AX");
    let row: String = (0..5)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row, "ABCDX");
}

/// Upstream test: "Terminal: cursorDown resets wrap"
#[test]
fn cursor_down_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[BX");
    assert_eq!(term.active_grid().get(1, 4).unwrap().char, 'X');
    let row0: String = (0..5)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row0, "ABCDE");
}

/// Upstream test: "Terminal: cursorRight resets wrap"
#[test]
fn cursor_right_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[CX");
    let row: String = (0..5)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row, "ABCDX");
}

/// Upstream test: "Terminal: eraseLine resets pending wrap"
#[test]
fn erase_line_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[KX");
    let row: String = (0..5)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row, "ABCDX");
}

/// Upstream test: "Terminal: saveCursor pending wrap state"
#[test]
fn save_restore_cursor_round_trips_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;5HA"); // print in the last column -> pending wrap set
    term.feed(b"\x1b7"); // DECSC saves it
    term.feed(b"\x1b[1;1H"); // movement clears it
    term.feed(b"\x1b8"); // DECRC restores it
    term.feed(b"B"); // so this print wraps to row 1
    assert_eq!(term.active_grid().get(0, 4).unwrap().char, 'A');
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'B');
}

/// Upstream test: "Terminal: eraseChars simple operation"
#[test]
fn erase_chars_simple_operation() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC\x1b[1;1H\x1b[2X");
    let row: String = (0..3)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row, "  C");
}

/// Upstream test: "Terminal: eraseChars minimum one"
#[test]
fn erase_chars_minimum_one() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC\x1b[1;1H\x1b[X");
    let row: String = (0..3)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row, " BC");
}
