/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{CellAttrs, Color};
use crate::modes::MouseTracking;
use crate::terminal::*;

#[test]
fn test_print_plain_text_advances_cursor() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"abc");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'a');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, 'b');
    assert_eq!(term.active_grid().get(0, 2).unwrap().char, 'c');
    assert_eq!(term.cursor(), (0, 3));
}

#[test]
fn test_print_wraps_at_end_of_line() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"abcdef");
    // Row 0 is filled with 'a'..'e' and marked wrapped.
    for (col, expected) in ['a', 'b', 'c', 'd', 'e'].into_iter().enumerate() {
        assert_eq!(term.active_grid().get(0, col).unwrap().char, expected);
    }
    assert!(!term.active_grid().is_line_wrapped(0));
    assert!(term.active_grid().is_line_wrapped(1));
    // 'f' lands at the start of row 1, cursor sits right after it.
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'f');
    assert_eq!(term.cursor(), (1, 1));
}

#[test]
fn test_sgr_bold_red_fg_applies_to_printed_cell() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[1;31mX");
    let cell = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell.char, 'X');
    assert!(cell.attrs.contains(CellAttrs::BOLD));
    assert_eq!(cell.fg, Color::Indexed(1));
}

#[test]
fn test_sgr_reset_clears_attrs_and_colors() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[1;31mA\x1b[0mB");
    let a = term.active_grid().get(0, 0).unwrap();
    assert!(a.attrs.contains(CellAttrs::BOLD));
    let b = term.active_grid().get(0, 1).unwrap();
    assert!(!b.attrs.contains(CellAttrs::BOLD));
    assert_eq!(b.fg, Color::Default);
}

#[test]
fn test_sgr_extended_truecolor_fg() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[38;2;10;20;30mX");
    let cell = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell.fg, Color::Rgb(10, 20, 30));
}

#[test]
fn test_cup_cursor_positioning() {
    let mut term = Terminal::new(20, 10);
    term.feed(b"\x1b[5;10H");
    assert_eq!(term.cursor(), (4, 9));
}

#[test]
fn test_cursor_movement_a_b_c_d() {
    let mut term = Terminal::new(20, 10);
    term.feed(b"\x1b[5;5H"); // (4, 4)
    term.feed(b"\x1b[2B"); // down 2 -> row 6
    term.feed(b"\x1b[3C"); // right 3 -> col 7
    assert_eq!(term.cursor(), (6, 7));
    term.feed(b"\x1b[1A"); // up 1 -> row 5
    term.feed(b"\x1b[2D"); // left 2 -> col 5
    assert_eq!(term.cursor(), (5, 5));
}

#[test]
fn test_erase_in_display_full_clears_grid() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"hello");
    term.feed(b"\x1b[2J");
    for col in 0..10 {
        assert_eq!(term.active_grid().get(0, col).unwrap().char, '\0');
    }
}

#[test]
fn test_erase_in_line() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"hello world");
    term.feed(b"\x1b[5;3H"); // move to (4, 2) -- irrelevant row, just testing col math
    term.feed(b"\x1b[1;3H"); // row 0, col 2 (0-indexed 0,2)
    term.feed(b"\x1b[K"); // erase from cursor (col 2) to end of line
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'h');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, 'e');
    assert_eq!(term.active_grid().get(0, 2).unwrap().char, '\0');
    assert_eq!(term.active_grid().get(0, 9).unwrap().char, '\0');
}

#[test]
fn test_alt_screen_switch_and_restore() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"hello");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);

    term.feed(b"\x1b[?1049h");
    assert_eq!(term.active_screen(), ScreenBuffer::Alternate);
    // Alt screen must be blank on entry.
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\0');

    term.feed(b"\x1b[1;1H"); // home the cursor before writing to the alt screen
    term.feed(b"world");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'w');

    term.feed(b"\x1b[?1049l");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
    // Prior primary-screen content survived the round trip.
    for (col, expected) in ['h', 'e', 'l', 'l', 'o'].into_iter().enumerate() {
        assert_eq!(term.active_grid().get(0, col).unwrap().char, expected);
    }
}

#[test]
fn test_alternate_screen_has_zero_scrollback_and_mode_1007_semantics() {
    let mut term = Terminal::new(10, 3);
    // Primary screen accumulates scrollback
    term.feed(b"line1\r\nline2\r\nline3\r\nline4\r\n");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
    assert_eq!(term.active_grid().scrollback_len(), 2);

    // Mode 1007 is enabled by default
    assert!(term.modes().alternate_scroll);

    // Mode 1007 can be toggled via DECSET/DECRST
    term.feed(b"\x1b[?1007l");
    assert!(!term.modes().alternate_scroll);
    term.feed(b"\x1b[?1007h");
    assert!(term.modes().alternate_scroll);

    // Mode 1007 can be queried via DECRQM
    term.feed(b"\x1b[?1007$p");
    let resp = term.take_output();
    assert_eq!(resp, b"\x1b[?1007;1$y".to_vec());

    term.feed(b"\x1b[?1007l");
    term.feed(b"\x1b[?1007$p");
    let resp = term.take_output();
    assert_eq!(resp, b"\x1b[?1007;2$y".to_vec());

    // Enter alternate screen via 1049
    term.feed(b"\x1b[?1049h");
    assert_eq!(term.active_screen(), ScreenBuffer::Alternate);
    assert_eq!(term.active_grid().scrollback_len(), 0);

    // Alternate screen output never accumulates scrollback
    term.feed(b"alt1\r\nalt2\r\nalt3\r\nalt4\r\n");
    assert_eq!(term.active_grid().scrollback_len(), 0);

    // Switch back to primary restores previous scrollback
    term.feed(b"\x1b[?1049l");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
    assert_eq!(term.active_grid().scrollback_len(), 2);

    // Also test 47 and 1047 screen switches
    term.feed(b"\x1b[?47h");
    assert_eq!(term.active_screen(), ScreenBuffer::Alternate);
    assert_eq!(term.active_grid().scrollback_len(), 0);
    term.feed(b"\x1b[?47l");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);

    term.feed(b"\x1b[?1047h");
    assert_eq!(term.active_screen(), ScreenBuffer::Alternate);
    assert_eq!(term.active_grid().scrollback_len(), 0);
    term.feed(b"\x1b[?1047l");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
}

#[test]
fn test_claude_and_tui_mode_sequences_and_snapshot_fidelity() {
    let mut term = Terminal::new(80, 24);
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
    assert_eq!(term.modes().mouse_tracking, MouseTracking::Off);
    assert!(!term.modes().mouse_sgr);
    assert!(term.modes().alternate_scroll);

    // 1. Claude Code startup sequence on primary screen:
    // ?25l (hide cursor), ?1000h (normal mouse), ?1002h (button event mouse), ?1006h (SGR), ?2004h (bracketed paste)
    term.feed(b"\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
    assert!(!term.cursor_visible());
    assert_eq!(term.modes().mouse_tracking, MouseTracking::ButtonEvent);
    assert!(term.modes().mouse_sgr);
    assert!(term.modes().bracketed_paste);

    // DECRQM query for 1002 and 1006
    term.feed(b"\x1b[?1002$p");
    let resp = term.take_output();
    assert_eq!(resp, b"\x1b[?1002;1$y".to_vec());

    term.feed(b"\x1b[?1006$p");
    let resp = term.take_output();
    assert_eq!(resp, b"\x1b[?1006;1$y".to_vec());

    // 2. Claude shutdown / restoration sequence:
    term.feed(b"\x1b[?1002l\x1b[?1000l\x1b[?1006l\x1b[?2004l\x1b[?25h");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
    assert!(term.cursor_visible());
    assert_eq!(term.modes().mouse_tracking, MouseTracking::Off);
    assert!(!term.modes().mouse_sgr);
    assert!(!term.modes().bracketed_paste);

    // 3. Full-screen TUI with alternate screen, DECCKM, focus reporting, and AnyEvent mouse:
    // Split sequence across multiple writes
    term.feed(b"\x1b[?1049h\x1b[?1h");
    assert_eq!(term.active_screen(), ScreenBuffer::Alternate);
    assert!(term.modes().cursor_key_app_mode);

    term.feed(b"\x1b[?1003h\x1b[?1004h\x1b[?1006h");
    assert_eq!(term.modes().mouse_tracking, MouseTracking::AnyEvent);
    assert!(term.modes().focus_events);
    assert!(term.modes().mouse_sgr);

    // Exit alternate screen restores primary buffer
    term.feed(b"\x1b[?1049l");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);
}

#[test]
fn test_line_feed_scrolls_at_bottom_of_screen() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"aaaaa"); // fills row 0; cursor parks on its last column (deferred wrap)
    term.feed(b"bbbbb"); // first 'b' wraps to row 1; the rest fill it, parking again
    // Nothing has scrolled yet -- both rows are intact, which is exactly
    // xterm's deferred-wrap behavior on a full bottom row.
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'a');
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'b');
    // The next printable finally triggers the wrap off the bottom row,
    // scrolling the screen: row 0 becomes the 'b' row.
    term.feed(b"c");
    for col in 0..5 {
        assert_eq!(term.active_grid().get(0, col).unwrap().char, 'b');
    }
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'c');
}

#[test]
fn test_save_restore_cursor_csi() {
    let mut term = Terminal::new(20, 10);
    term.feed(b"\x1b[3;4H\x1b[s");
    term.feed(b"\x1b[10;10H");
    assert_eq!(term.cursor(), (9, 9));
    term.feed(b"\x1b[u");
    assert_eq!(term.cursor(), (2, 3));
}

#[test]
fn test_osc_title() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]2;my title\x07");
    assert_eq!(term.title(), "my title");
}

#[test]
fn test_cursor_visibility_decset() {
    let mut term = Terminal::new(10, 5);
    assert!(term.cursor_visible());
    term.feed(b"\x1b[?25l");
    assert!(!term.cursor_visible());
    term.feed(b"\x1b[?25h");
    assert!(term.cursor_visible());
}

#[test]
fn test_resize_clamps_cursor() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[5;10H");
    assert_eq!(term.cursor(), (4, 9));
    term.resize(4, 3);
    let (row, col) = term.cursor();
    assert!(row < 3);
    assert!(col < 4);
}

#[test]
fn test_osc8_hyperlink_stamps_printed_cells_and_resolves_uri() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]8;id=foo;https://example.com\x07link\x1b]8;;\x07");
    for col in 0..4 {
        let cell = term.active_grid().get(0, col).unwrap();
        let id = cell.hyperlink.expect("cell should carry a hyperlink id");
        assert_eq!(term.hyperlink_uri(id), Some("https://example.com"));
    }
}

#[test]
fn test_osc8_close_clears_hyperlink_for_subsequent_text() {
    let mut term = Terminal::new(20, 5);
    term.feed(b"\x1b]8;id=foo;https://example.com\x07link\x1b]8;;\x07plain");
    // "link" is 4 chars (cols 0..4), "plain" follows at cols 4..9.
    for col in 4..9 {
        let cell = term.active_grid().get(0, col).unwrap();
        assert_eq!(cell.hyperlink, None);
    }
}

#[test]
fn test_osc8_same_explicit_id_dedups_across_a_gap() {
    let mut term = Terminal::new(30, 5);
    term.feed(
        b"\x1b]8;id=foo;https://example.com\x07AAA\x1b]8;;\x07 gap \x1b]8;id=foo;https://example.com\x07BBB\x1b]8;;\x07",
    );
    let first_id = term.active_grid().get(0, 0).unwrap().hyperlink.unwrap();
    // "AAA" (3) + " gap " (5) = col 8 is the start of the second "BBB" span.
    let second_id = term.active_grid().get(0, 8).unwrap().hyperlink.unwrap();
    assert_eq!(first_id, second_id);
    assert_eq!(term.hyperlink_uri(first_id), Some("https://example.com"));
}

#[test]
fn test_osc8_implicit_id_opens_are_independent() {
    let mut term = Terminal::new(30, 5);
    // No explicit id=... param -- just an empty params string, per xterm.
    term.feed(
        b"\x1b]8;;https://a.example\x07AAA\x1b]8;;\x07\x1b]8;;https://a.example\x07BBB\x1b]8;;\x07",
    );
    let first_id = term.active_grid().get(0, 0).unwrap().hyperlink.unwrap();
    let second_id = term.active_grid().get(0, 3).unwrap().hyperlink.unwrap();
    // Same URI, but no explicit id -- each open is its own link (xterm's
    // implicit-id behavior), so they must NOT be deduped to the same id.
    assert_ne!(first_id, second_id);
    assert_eq!(term.hyperlink_uri(first_id), Some("https://a.example"));
    assert_eq!(term.hyperlink_uri(second_id), Some("https://a.example"));
}
