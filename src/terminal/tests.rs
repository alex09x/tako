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

#[test]
fn test_selection_linear_within_one_row() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"hello");
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(0, 4);
    assert_eq!(term.selection_range(), Some(((0, 0), (0, 4))));
    assert_eq!(term.selected_text(), Some("hello".to_string()));
}

#[test]
fn test_selection_linear_multi_row_joins_with_newline_and_trims_trailing_space() {
    let mut term = Terminal::new(10, 3);
    // "abc" on row 0, hard newline (not a soft wrap), "def" on row 1.
    term.feed(b"abc\r\ndef");
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(1, 2);
    assert!(!term.active_grid().is_line_wrapped(1));
    // Row 0 has 7 trailing blank cells after "abc" that must not appear.
    assert_eq!(term.selected_text(), Some("abc\ndef".to_string()));
}

#[test]
fn test_selection_linear_across_soft_wrap_has_no_newline_and_no_trim() {
    let mut term = Terminal::new(5, 3);
    // Fills row 0 exactly ("abcde") and soft-wraps 'f' onto row 1.
    term.feed(b"abcdef");
    assert!(term.active_grid().is_line_wrapped(1));
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(1, 0);
    // No "\n" at the wrap point, and row 0's full width is kept verbatim
    // (it's a mid-word wrap, not trailing padding).
    assert_eq!(term.selected_text(), Some("abcdef".to_string()));
}

#[test]
fn test_selection_rectangular_multi_row_narrower_than_full_width() {
    let mut term = Terminal::new(12, 3);
    term.feed(b"0123456789\r\nabcdefghij\r\nABCDEFGHIJ");
    term.start_selection(0, 2, SelectionMode::Rectangular);
    term.extend_selection(2, 5);
    assert_eq!(term.selection_range(), Some(((0, 2), (2, 5))));
    assert_eq!(
        term.selected_text(),
        Some("2345\ncdef\nCDEF".to_string())
    );
}

#[test]
fn test_selection_reversed_anchor_active_matches_forward_drag() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"abc\r\ndef");

    let mut forward = Terminal::new(10, 3);
    forward.feed(b"abc\r\ndef");
    forward.start_selection(0, 0, SelectionMode::Linear);
    forward.extend_selection(1, 2);

    // Same span, but dragged backward: mouse-down at the end, drag up to
    // the start.
    term.start_selection(1, 2, SelectionMode::Linear);
    term.extend_selection(0, 0);

    assert_eq!(term.selected_text(), forward.selected_text());
    assert_eq!(term.selected_text(), Some("abc\ndef".to_string()));
}

#[test]
fn test_clear_selection_and_has_selection() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"hello");
    assert!(!term.has_selection());
    assert_eq!(term.selected_text(), None);

    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(0, 4);
    assert!(term.has_selection());
    assert_eq!(term.selected_text(), Some("hello".to_string()));

    term.clear_selection();
    assert!(!term.has_selection());
    assert_eq!(term.selected_text(), None);
    assert_eq!(term.selection_range(), None);
}

#[test]
fn test_resize_with_active_selection_does_not_panic_and_stays_in_bounds() {
    let mut term = Terminal::new(10, 5);
    term.start_selection(4, 9, SelectionMode::Linear);
    term.extend_selection(0, 0);
    assert!(term.has_selection());

    term.resize(4, 3);

    assert!(term.has_selection());
    let (start, end) = term.selection_range().unwrap();
    assert!(start.0 < 3 && start.1 < 4);
    assert!(end.0 < 3 && end.1 < 4);
    // Extracting text must not panic even though the grid shrank out
    // from under the selection.
    let _ = term.selected_text();
}


#[test]
fn test_dec_special_graphics_charset_translates_and_restores_via_feed() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b(0q\x1b(Bq");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\u{2500}');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, 'q');
}

#[test]
fn test_shift_out_shift_in_switches_between_g0_and_g1() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b)0\x0eq\x0fq");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\u{2500}');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, 'q');
}

#[test]
fn test_tab_uses_real_tabstops_set_by_hts() {
    let mut term = Terminal::new(20, 3);
    term.feed(b"\x1b[3g");
    for _ in 0..5 {
        term.feed(b"\x1b[C");
    }
    term.feed(b"\x1bH");
    term.feed(b"\r\t");
    assert_eq!(term.cursor(), (0, 5));
}

#[test]
fn ios_surface_destructive_resize_prevention() {
    let mut g = crate::grid::Grid::new(10, 4);
    g.set(0, 0, crate::grid::Cell { char: 'A', ..Default::default() });
    g.set(0, 1, crate::grid::Cell { char: 'B', ..Default::default() });
    g.set(1, 0, crate::grid::Cell { char: 'C', ..Default::default() });
    g.set_line_wrapped(1, true);
    g.set_row_semantic_prompt(2, crate::grid::SemanticPrompt::Prompt);

    // Shrink grid dimensions without reflow
    g.resize_no_reflow(8, 3);
    assert_eq!(g.cols(), 8);
    assert_eq!(g.rows(), 3);

    // Overlapping cells must be preserved
    assert_eq!(g.get(0, 0).map(|c| c.char), Some('A'));
    assert_eq!(g.get(0, 1).map(|c| c.char), Some('B'));
    assert_eq!(g.get(1, 0).map(|c| c.char), Some('C'));

    // Wrapped and semantic prompt states must be preserved
    assert!(g.is_line_wrapped(1));
    assert_eq!(g.row_semantic_prompt(2), crate::grid::SemanticPrompt::Prompt);
    assert!(g.is_dirty(0));
    assert!(g.is_dirty(1));

    // Expand grid dimensions without reflow
    g.resize_no_reflow(12, 5);
    assert_eq!(g.cols(), 12);
    assert_eq!(g.rows(), 5);
    assert_eq!(g.get(0, 0).map(|c| c.char), Some('A'));
    assert_eq!(g.get(0, 1).map(|c| c.char), Some('B'));
    assert_eq!(g.get(1, 0).map(|c| c.char), Some('C'));
    assert_eq!(g.get(0, 10).map(|c| c.char), Some('\0'));
}

#[test]
fn ios_surface_wrap_exact_row_boundaries() {
    let mut term = Terminal::new(5, 3);
    // Write 5 chars on line 1, wrapping to line 2 (abs row 0 wrapped to abs row 1)
    term.feed(b"123456");
    term.feed(b"\r\nline3\r\nline4\r\nline5\r\nline6");

    let scrollback_len = term.active_grid().scrollback_len();
    assert!(scrollback_len >= 3);

    // Oldest scrollback row is line start (not continuation)
    assert!(!term.is_line_wrapped_abs(0));
    // Row 1 is wrapped continuation of row 0
    assert!(term.is_line_wrapped_abs(1));

    // Boundary check at scrollback/live border
    let live_border = scrollback_len;
    assert!(!term.is_line_wrapped_abs(live_border));

    // Bottom live row check
    let total_rows = scrollback_len + term.active_grid().rows();
    assert!(!term.is_line_wrapped_abs(total_rows - 1));
}

#[test]
fn ios_surface_eviction_before_inside_active_selection() {
    let mut term = Terminal::with_scrollback(10, 3, 4);
    term.feed(b"Line 1\r\nLine 2\r\nLine 3\r\nLine 4\r\nLine 5\r\nLine 6\r\nLine 7");

    // Start a selection on the oldest retained line
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(2, 5);
    assert!(term.has_selection());

    let initial_text = term.selected_text();
    assert!(initial_text.is_some());

    // Scroll more lines to trigger scrollback eviction
    term.feed(b"\r\nLine 8\r\nLine 9\r\nLine 10");

    // Selection spanning boundary should remain valid and clamp upper evicted lines deterministically
    assert!(term.has_selection());
    let remaining_text = term.selected_text();
    assert!(remaining_text.is_some());

    // Feed many more lines to completely evict the selection
    for i in 11..=30 {
        term.feed(format!("\r\nLine {}", i).as_bytes());
    }

    // Selection should be completely evicted and return None
    assert!(!term.has_selection());
    assert_eq!(term.selected_text(), None);
}

#[test]
fn ios_surface_forward_reverse_rectangular_selection() {
    let mut term = Terminal::new(10, 4);
    term.feed(b"AAAA\r\nBBBB\r\nCCCC\r\nDDDD");

    // Forward linear selection
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(1, 3);
    let fwd_linear = term.selected_text();

    // Reverse linear selection
    term.start_selection(1, 3, SelectionMode::Linear);
    term.extend_selection(0, 0);
    let rev_linear = term.selected_text();
    assert_eq!(fwd_linear, rev_linear);

    // Forward rectangular selection (drag top-left to bottom-right)
    term.start_selection(0, 1, SelectionMode::Rectangular);
    term.extend_selection(2, 2);
    let fwd_rect = term.selected_text();
    assert_eq!(fwd_rect, Some("AA\nBB\nCC".to_string()));

    // Reverse rectangular selection (drag bottom-right to top-left)
    term.start_selection(2, 2, SelectionMode::Rectangular);
    term.extend_selection(0, 1);
    let rev_rect1 = term.selected_text();
    assert_eq!(rev_rect1, Some("AA\nBB\nCC".to_string()));

    // Reverse rectangular selection (drag top-right to bottom-left)
    term.start_selection(0, 2, SelectionMode::Rectangular);
    term.extend_selection(2, 1);
    let rev_rect2 = term.selected_text();
    assert_eq!(rev_rect2, Some("AA\nBB\nCC".to_string()));
}

#[test]
fn ios_surface_resize_history_interactions() {
    let mut term = Terminal::with_scrollback(10, 4, 100);
    for i in 1..=20 {
        term.feed(format!("Item {}\r\n", i).as_bytes());
    }

    // Start a selection in history
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(2, 5);
    assert!(term.has_selection());

    // Resize grid
    term.resize(15, 6);
    assert!(term.has_selection());
    assert!(term.selected_text().is_some());

    term.resize(5, 2);
    assert!(term.selected_text().is_some() || !term.has_selection());
}

#[test]
fn test_autowrap_disabled_overwrites_last_column_instead_of_wrapping() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"\x1b[?7l");
    term.feed(b"abcdef");
    assert_eq!(term.cursor(), (0, 4));
    assert_eq!(term.active_grid().get(0, 4).unwrap().char, 'f');
    assert!(!term.active_grid().is_line_wrapped(0));
}

#[test]
fn test_wide_char_occupies_two_columns_with_spacer() {
    let mut term = Terminal::new(10, 3);
    term.feed("\u{4e2d}".as_bytes());
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\u{4e2d}');
    assert!(!term.active_grid().get(0, 0).unwrap().is_wide_spacer);
    assert!(term.active_grid().get(0, 1).unwrap().is_wide_spacer);
    assert_eq!(term.cursor(), (0, 2));
}

#[test]
fn test_da1_response_is_queued_and_drained() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[c");
    assert_eq!(term.take_output(), b"\x1b[?62;22c".to_vec());
    assert!(term.take_output().is_empty());
}

#[test]
fn test_dsr_cursor_position_report() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[2;3H");
    term.feed(b"\x1b[6n");
    assert_eq!(term.take_output(), b"\x1b[2;3R".to_vec());
}

#[test]
fn test_kitty_keyboard_push_and_query_round_trip() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[>5u");
    term.feed(b"\x1b[?u");
    assert_eq!(term.take_output(), b"\x1b[?5u".to_vec());
    term.feed(b"\x1b[<1u");
    term.feed(b"\x1b[?u");
    assert_eq!(term.take_output(), b"\x1b[?0u".to_vec());
}

#[test]
fn test_kitty_graphics_apc_transmit_and_display_records_placement() {
    use crate::ffi::TakoCore;
    use base64::Engine as _;
    let term = TakoCore::new(10, 6);
    term.feed(b"\x1b[5;5H".to_vec());

    let pixel = [0xFFu8, 0x80, 0x00, 0xFF];
    let payload = base64::engine::general_purpose::STANDARD.encode(pixel);
    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=7;");
    apc.extend_from_slice(payload.as_bytes());
    apc.extend_from_slice(b"\x1b\\");
    term.feed(apc);

    let placements = term.graphics_placements();
    assert_eq!(placements.len(), 1);
    assert_eq!(placements[0].image_id, 7);
    assert_eq!(placements[0].row, 4);
    assert_eq!(placements[0].col, 4);

    let image = term.graphics_image(7).unwrap();
    assert_eq!(image.pixels, pixel.to_vec());

    let metadata = term.graphics_image_metadata(7).unwrap();
    assert_eq!(metadata.format, crate::ffi::FfiImageFormat::Rgba);
    assert_eq!(metadata.width, 1);
    assert_eq!(metadata.height, 1);
    assert_eq!(metadata.generation, 1);
}

#[test]
fn test_kitty_graphics_metadata_changes_on_replace_and_deletes_with_none() {
    use crate::ffi::TakoCore;
    use base64::Engine as _;
    let core = TakoCore::new(10, 6);
    core.feed(b"\x1b[5;5H".to_vec());

    let pixel_a = [0xFF_u8, 0x80, 0x00, 0xFF];
    let pixel_b = [0x00_u8, 0xFF, 0x80, 0x00];

    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=7;");
    apc.extend_from_slice(
        base64::engine::general_purpose::STANDARD
            .encode(pixel_a)
            .as_bytes(),
    );
    apc.extend_from_slice(b"\x1b\\");
    core.feed(apc);

    let first = core.graphics_image_metadata(7).unwrap();
    let first_image = core.graphics_image(7).unwrap();
    assert_eq!(first.width, 1);
    assert_eq!(first.height, 1);
    assert_eq!(first.format, crate::ffi::FfiImageFormat::Rgba);
    assert_eq!(first.generation, 1);
    assert_eq!(first_image.pixels, pixel_a.to_vec());

    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=t,t=d,f=32,s=1,v=1,i=7;");
    apc.extend_from_slice(
        base64::engine::general_purpose::STANDARD
            .encode(pixel_b)
            .as_bytes(),
    );
    apc.extend_from_slice(b"\x1b\\");
    core.feed(apc);
    let second = core.graphics_image_metadata(7).unwrap();
    assert_eq!(second.generation, first.generation + 1);

    let mut delete = Vec::new();
    delete.extend_from_slice(b"\x1b_Ga=d,d=i,i=7;");
    delete.extend_from_slice(b"\x1b\\");
    core.feed(delete);

    assert!(core.graphics_image(7).is_none());
    assert!(core.graphics_image_metadata(7).is_none());

    let mut recreate = Vec::new();
    recreate.extend_from_slice(b"\x1b_Ga=t,t=d,f=32,s=1,v=1,i=7;");
    recreate.extend_from_slice(
        base64::engine::general_purpose::STANDARD
            .encode(pixel_a)
            .as_bytes(),
    );
    recreate.extend_from_slice(b"\x1b\\");
    core.feed(recreate);

    let third = core.graphics_image_metadata(7).unwrap();
    assert_eq!(third.generation, second.generation + 1);
    assert_eq!(core.graphics_image(7).unwrap().pixels, pixel_a.to_vec());
}


#[test]
fn test_rep_repeats_last_printed_char() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"A\x1b[3b"); // print 'A', then REP(3) repeats it 3 more times
    let row: String = (0..4).map(|c| term.active_grid().get(0, c).unwrap().char).collect();
    assert_eq!(row, "AAAA");
}

#[test]
fn test_decscusr_sets_cursor_style() {
    use crate::cursor_style::{CursorShape, CursorStyle};
    let mut term = Terminal::new(10, 3);
    assert_eq!(term.cursor_style(), CursorStyle::new());
    term.feed(b"\x1b[3 q"); // DECSCUSR 3 = blinking underline
    assert_eq!(term.cursor_style().shape, CursorShape::Underline);
    assert!(term.cursor_style().blinking);
}

#[test]
fn test_decstr_soft_reset_restores_scroll_region_and_attrs() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[2;4r"); // narrow the scroll region
    term.feed(b"\x1b[1m"); // bold
    term.feed(b"\x1b[!p"); // DECSTR
    term.feed(b"X");
    assert!(!term.active_grid().get(0, 0).unwrap().attrs.contains(CellAttrs::BOLD));
    // Scroll region back to the full screen: cursor-down from row 0 should
    // reach the last row, not stop at the old margin.
    term.feed(b"\x1b[10B");
    assert_eq!(term.cursor(), (4, 1));
}

#[test]
fn test_ris_hard_reset_clears_screen_and_state() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[1mABC\x1b[3;3H");
    term.feed(b"\x1bc"); // RIS
    assert_eq!(term.cursor(), (0, 0));
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\0');
    assert!(!term.active_grid().get(0, 0).unwrap().attrs.contains(CellAttrs::BOLD));
}

#[test]
fn test_osc4_set_and_query_palette() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]4;1;#ff8000\x07"); // set palette index 1
    assert_eq!(term.palette().get(1), (255, 128, 0));
    term.feed(b"\x1b]4;1;?\x07"); // query it back
    assert_eq!(term.take_output(), b"\x1b]4;1;rgb:ffff/8080/0000\x1b\\".to_vec());
}

#[test]
fn test_osc104_resets_palette() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]4;1;#ff8000\x07");
    term.feed(b"\x1b]104\x07"); // reset all
    assert_eq!(term.palette().get(1), (0xCC, 0x66, 0x66)); // back to upstream's default red
}

#[test]
fn test_xtwinops_title_push_and_pop() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]0;first\x07");
    term.feed(b"\x1b[22t"); // push
    term.feed(b"\x1b]0;second\x07");
    assert_eq!(term.title(), "second");
    term.feed(b"\x1b[23t"); // pop
    assert_eq!(term.title(), "first");
}


#[test]
fn test_cha_vpa_absolute_positioning() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[5G"); // CHA: column 5 (1-based)
    assert_eq!(term.cursor(), (0, 4));
    term.feed(b"\x1b[3d"); // VPA: row 3 (1-based), column untouched
    assert_eq!(term.cursor(), (2, 4));
    term.feed(b"\x1b[99G\x1b[99d"); // both clamp to the grid edge
    assert_eq!(term.cursor(), (4, 9));
}

#[test]
fn test_cnl_cpl_move_and_reset_column() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[2;5H"); // (1,4)
    term.feed(b"\x1b[2E"); // CNL 2 -> row 3, column 0
    assert_eq!(term.cursor(), (3, 0));
    term.feed(b"\x1b[5G\x1b[1F"); // column 5, then CPL 1 -> row 2, column 0
    assert_eq!(term.cursor(), (2, 0));
}

#[test]
fn test_su_sd_scroll_without_moving_cursor() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"AAA\r\nBBB\r\nCCC");
    term.feed(b"\x1b[1S"); // SU: content moves up one row
    let row0: String = (0..3).map(|c| term.active_grid().get(0, c).unwrap().char).collect();
    assert_eq!(row0, "BBB");
    term.feed(b"\x1b[1T"); // SD: content moves back down, top row blank
    let row0b: String = (0..3)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    let row1: String = (0..3).map(|c| term.active_grid().get(1, c).unwrap().char).collect();
    assert_eq!(row0b, "   ");
    assert_eq!(row1, "BBB");
}

#[test]
fn test_decaln_fills_screen_and_homes_cursor() {
    let mut term = Terminal::new(4, 3);
    term.feed(b"\x1b[2;2H"); // move away from home first
    term.feed(b"\x1b#8");
    for row in 0..3 {
        for col in 0..4 {
            assert_eq!(term.active_grid().get(row, col).unwrap().char, 'E');
        }
    }
    assert_eq!(term.cursor(), (0, 0));
}

#[test]
fn test_ech_preserves_background_color() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"AB\x1b[44m\x1b[1;1H\x1b[2X"); // blank A,B with blue bg active
    let cell = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell.char, '\0');
    assert_eq!(cell.bg, Color::Indexed(4));
    // Content past the erased span is untouched.
    assert_eq!(term.active_grid().get(0, 2).unwrap().char, '\0');
}


#[test]
fn test_plain_string_matches_upstream_semantics() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;1HA\x1b[10A"); // 'A' on row 2, CUU clamps to row 0
    term.feed(b"X");
    assert_eq!(term.plain_string(), " X\n\nA");

    // Soft-wrapped rows stay visual rows -- upstream's "soft wrap" test
    // expects "hel\nlo" for a wrapped "hello", so ours matches that shape.
    let mut term2 = Terminal::new(5, 5);
    term2.feed(b"ABCDEFG");
    assert_eq!(term2.plain_string(), "ABCDE\nFG");
}


#[test]
fn test_events_bell_title_clipboard_notify_pwd() {
    use crate::terminal::TerminalEvent;
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x07");
    term.feed(b"\x1b]0;hi\x07");
    term.feed(b"\x1b]52;c;aGVsbG8=\x07"); // base64 "hello"
    term.feed(b"\x1b]52;c;?\x07");
    term.feed(b"\x1b]9;ping\x07");
    term.feed(b"\x1b]777;notify;T;B\x07");
    term.feed(b"\x1b]7;file://host/tmp\x07");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![
            TerminalEvent::Bell,
            TerminalEvent::TitleChanged("hi".into()),
            TerminalEvent::ClipboardSet("hello".into()),
            TerminalEvent::ClipboardQuery,
            TerminalEvent::Notification { title: String::new(), body: "ping".into() },
            TerminalEvent::Notification { title: "T".into(), body: "B".into() },
            TerminalEvent::PwdChanged("file://host/tmp".into()),
        ]
    );
    assert!(term.take_events().is_empty());
}

#[test]
fn test_osc10_11_set_and_query_default_colors() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]10;#ff8000\x07");
    term.feed(b"\x1b]11;rgb:00/11/22\x07");
    assert_eq!(term.default_colors().0, Some((255, 128, 0)));
    assert_eq!(term.default_colors().1, Some((0, 17, 34)));
    term.feed(b"\x1b]10;?\x07");
    // BEL-terminated query -> BEL-terminated reply (terminator mirrors).
    assert_eq!(term.take_output(), b"\x1b]10;rgb:ffff/8080/0000\x07".to_vec());
    term.feed(b"\x1b]110\x07\x1b]111\x07");
    assert_eq!(term.default_colors().0, None);
    assert_eq!(term.default_colors().1, None);
}

#[test]
fn test_decrqm_reports_mode_state() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[?6$p");
    assert_eq!(term.take_output(), b"\x1b[?6;2$y".to_vec());
    term.feed(b"\x1b[?6h\x1b[?6$p");
    assert_eq!(term.take_output(), b"\x1b[?6;1$y".to_vec());
    term.feed(b"\x1b[4h\x1b[4$p");
    assert_eq!(term.take_output(), b"\x1b[4;1$y".to_vec());
    term.feed(b"\x1b[?9999$p");
    assert_eq!(term.take_output(), b"\x1b[?9999;0$y".to_vec());
}

#[test]
fn test_sgr_colon_underline_styles_and_color() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[4:3m\x1b[58:2::10:20:30mX");
    let cell = term.active_grid().get(0, 0).unwrap();
    assert!(cell.attrs.contains(CellAttrs::UNDERLINE));
    assert_eq!(cell.underline_style, 3);
    assert_eq!(cell.underline_color, Color::Rgb(10, 20, 30));
    term.feed(b"\x1b[59m\x1b[4:0mY");
    let cell = term.active_grid().get(0, 1).unwrap();
    assert!(!cell.attrs.contains(CellAttrs::UNDERLINE));
    assert_eq!(cell.underline_color, Color::Default);
}

#[test]
fn test_sgr_overline_and_double_underline() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[53m\x1b[21mX\x1b[55m\x1b[24mY");
    let x = term.active_grid().get(0, 0).unwrap();
    assert!(x.attrs.contains(CellAttrs::OVERLINE));
    assert_eq!(x.underline_style, 2);
    let y = term.active_grid().get(0, 1).unwrap();
    assert!(!y.attrs.contains(CellAttrs::OVERLINE));
    assert_eq!(y.underline_style, 0);
}

#[test]
fn test_legacy_semicolon_truecolor_still_works() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[38;2;1;2;3m\x1b[48;5;20mZ");
    let z = term.active_grid().get(0, 0).unwrap();
    assert_eq!(z.fg, Color::Rgb(1, 2, 3));
    assert_eq!(z.bg, Color::Indexed(20));
}

#[test]
fn test_decic_decdc_insert_delete_columns() {
    let mut term = Terminal::new(6, 2);
    term.feed(b"ABCDEF\r\nabcdef");
    term.feed(b"\x1b[1;2H"); // col 1
    term.feed(b"\x1b[2'}"); // DECIC 2
    assert_eq!(term.plain_string(), "A  BCD\na  bcd");
    term.feed(b"\x1b[2'~"); // DECDC 2
    assert_eq!(term.plain_string(), "ABCD\nabcd");
}

#[test]
fn test_decbi_decfi_at_margins_shift_columns() {
    let mut term = Terminal::new(4, 2);
    term.feed(b"ABCD\r\nabcd");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b6"); // DECBI at left margin: shift right
    assert_eq!(term.plain_string(), " ABC\n abc");
    term.feed(b"\x1b[1;4H");
    term.feed(b"\x1b9"); // DECFI at right margin: shift left
    assert_eq!(term.plain_string(), "ABC\nabc");
}

#[test]
fn test_uk_charset_pound() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"\x1b(A#\x1b(B#");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\u{00A3}');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, '#');
}


#[test]
fn test_damage_tracking_reports_only_changed_rows() {
    let mut term = Terminal::new(10, 4);
    term.take_damage(); // clear the initial full-damage state
    assert!(term.take_damage().is_empty());

    term.feed(b"\x1b[2;1Hhello"); // writes row 1 only
    assert_eq!(term.take_damage(), vec![1]);
    assert!(term.take_damage().is_empty());

    term.feed(b"\x1b[4;1Hx");
    assert_eq!(term.take_damage(), vec![3]);
}

#[test]
fn test_scroll_and_resize_damage_everything() {
    let mut term = Terminal::new(5, 3);
    term.take_damage();
    term.feed(b"\r\n\r\n\r\n\r\n"); // forces a scroll
    assert_eq!(term.take_damage(), vec![0, 1, 2]);

    term.take_damage();
    term.resize(8, 3);
    assert_eq!(term.take_damage(), vec![0, 1, 2]);
}

#[test]
fn test_mark_all_damaged_forces_full_redraw() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"hi");
    let _ = term.take_damage();
    term.mark_all_damaged();
    assert_eq!(term.take_damage(), vec![0, 1, 2]);
}

#[test]
fn ios_surface_soft_wrap_accessibility_and_plain_text() {
    use crate::ffi::TakoCore;
    let handle = TakoCore::new(5, 4);
    // Print 5 chars to trigger pending wrap, then next char wrapped to row 1
    handle.feed(b"ABCDE".to_vec());
    handle.feed(b"FGH".to_vec());
    // Explicit newline to row 2
    handle.feed(b"\r\nIJ".to_vec());

    assert_eq!(handle.get_plain_text(0, 4), "ABCDEFGH\nIJ");

    // Test wide character wrap
    let handle_wide = TakoCore::new(4, 4);
    // 3 ASCII + 1 wide char ("界" wide) at col 3 cannot fit, so wraps to row 1
    handle_wide.feed("ABC界".as_bytes().to_vec());
    assert_eq!(handle_wide.get_plain_text(0, 4), "ABC界");

    // Accessibility follows the same scrolled viewport as the renderer,
    // including soft-wrap bits archived with history rows. Previously this
    // always read the live grid, so VoiceOver described text that was no
    // longer on screen after a finger scrolled into history.
    let scrolled = TakoCore::new(5, 2);
    scrolled.feed(b"ABCDEFGHIJKLMNOP".to_vec());
    assert_eq!(scrolled.get_plain_text(0, 2), "KLMNOP");
    scrolled.scroll_viewport_up(2);
    assert_eq!(scrolled.get_plain_text(0, 2), "ABCDEFGHIJ");
}

#[test]
fn ios_surface_soft_wrap_scrollback_eviction_boundary() {
    let mut term = Terminal::with_scrollback(5, 2, 2);
    // "ABCDE" -> row 0, "FGHIJ" -> row 1 (wrapped), "KLMNO" -> row 2 (wrapped), "PQRST" -> row 3 (wrapped)
    term.feed(b"ABCDEFGHIJKLMNOPQRST");
    assert_eq!(term.active_grid().scrollback_len(), 2);

    // Line 0 in scrollback (oldest remaining, abs 0) was old live row 0 (start of line) -> not wrapped
    assert!(!term.is_line_wrapped_abs(0));
    // Line 1 in scrollback (abs 1) was old live row 1 -> wrapped continuation of abs 0
    assert!(term.is_line_wrapped_abs(1));
    // Live row 0 (abs 2) -> wrapped continuation of abs 1
    assert!(term.is_line_wrapped_abs(2));
    // Live row 1 (abs 3) -> wrapped continuation of abs 2
    assert!(term.is_line_wrapped_abs(3));

    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(1, 4);
    assert_eq!(term.selected_text(), Some("KLMNOPQRST".to_string()));
}

#[test]
fn ios_surface_input_encoding_decomposed_grapheme_and_multi_scalar_emoji() {
    use crate::ffi::{FfiKey, FfiKeyEvent, TakoCore};

    let core = TakoCore::new(80, 24);

    // 1. Decomposed grapheme e + combining acute accent
    let bytes_decomposed = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "e\u{0301}".to_string(),
        physical_text: "e".to_string(),
        unshifted_text: "e".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_decomposed, "e\u{0301}".as_bytes());

    // 2. Multi-scalar ZWJ family emoji
    let bytes_emoji = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "👨‍👩‍👧‍👦".to_string(),
        physical_text: "👨".to_string(),
        unshifted_text: "👨".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_emoji, "👨‍👩‍👧‍👦".as_bytes());

    // 3. Multi-scalar flag emoji
    let bytes_flag = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "🇦🇺".to_string(),
        physical_text: "🇦".to_string(),
        unshifted_text: "🇦".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_flag, "🇦🇺".as_bytes());

    // 4. Negative assertion: Ctrl+C with text still emits C0 control byte (0x03)
    let bytes_ctrl = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "c".to_string(),
        physical_text: "c".to_string(),
        unshifted_text: "c".to_string(),
        shift: false,
        alt: false,
        ctrl: true,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_ctrl, vec![0x03]);

    // 5. Negative assertion: Alt+'e' with decomposed text emits ESC prefix (\x1be), not raw text
    let bytes_alt = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "e\u{0301}".to_string(),
        physical_text: "e".to_string(),
        unshifted_text: "e".to_string(),
        shift: false,
        alt: true,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_alt, vec![0x1b, b'e']);

    // 6. Negative assertion: Super+A with text emits empty bytes
    let bytes_super = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "a".to_string(),
        physical_text: "a".to_string(),
        unshifted_text: "a".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: true,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_super, Vec::<u8>::new());

    // 7. Negative assertion: Kitty keyboard protocol active -> Ctrl+A emits CSI u sequence, not text
    core.feed(b"\x1b[>1u".to_vec());
    let bytes_kitty = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "a".to_string(),
        physical_text: "a".to_string(),
        unshifted_text: "a".to_string(),
        shift: false,
        alt: false,
        ctrl: true,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_kitty, b"\x1b[97;5u".to_vec());
}

// ── Viewport / scroll-to-bottom tests ────────────────────────────────────────
// These cover the "prompt not visible after cat / large output" scenario:
// the viewport must stay at the live screen bottom while PTY data arrives,
// and scroll_viewport_bottom must be a cheap no-op when already there.

#[test]
fn viewport_stays_at_bottom_after_large_output() {
    let mut term = Terminal::new(80, 24);
    // Feed 100 lines — well beyond screen height — to build scrollback.
    for i in 0..100u32 {
        term.feed(format!("line {}\r\n", i).as_bytes());
    }
    // viewport_offset 0 means "live screen bottom"; it must never drift up
    // on its own while PTY data arrives.
    assert_eq!(term.viewport_offset(), 0);
}

#[test]
fn scroll_viewport_bottom_is_noop_when_already_at_zero() {
    let mut term = Terminal::new(80, 24);
    for _ in 0..50 {
        term.feed(b"line\r\n");
    }
    // Already at bottom.
    assert_eq!(term.viewport_offset(), 0);
    term.take_damage(); // drain damage flags

    // Calling scroll_viewport_bottom when already at offset 0 must NOT
    // mark rows dirty (it would force a full redraw on every PTY batch).
    term.scroll_viewport_bottom();
    assert_eq!(term.viewport_offset(), 0);
    assert!(term.take_damage().is_empty(), "spurious full-redraw triggered");
}

#[test]
fn scroll_viewport_bottom_snaps_from_scrolled_position() {
    let mut term = Terminal::new(80, 24);
    // Build at least 10 lines of scrollback.
    for _ in 0..40 {
        term.feed(b"line\r\n");
    }
    term.scroll_viewport_up(10);
    assert_eq!(term.viewport_offset(), 10);
    term.take_damage(); // drain

    term.scroll_viewport_bottom();
    assert_eq!(term.viewport_offset(), 0);
    // After actually moving the viewport, all rows must be re-rendered.
    assert!(!term.take_damage().is_empty(), "no damage reported after viewport snap");
}

#[test]
fn prompt_visible_after_cat_like_output() {
    // Simulate: shell prompt → user runs cat on a 66-line file → new prompt.
    // After the cat output, scroll_viewport_bottom should leave the live
    // screen visible so the shell prompt is on-screen without user action.
    let mut term = Terminal::new(80, 24);

    // Initial prompt.
    term.feed(b"$ ");

    // 66 lines of cat output (simulating cat backend_prompt.md).
    for i in 0..66u32 {
        term.feed(format!("output line {}\r\n", i).as_bytes());
    }

    // New prompt after command exits.
    term.feed(b"$ ");

    // The terminal is at the live screen bottom — prompt is on row 23
    // (or wherever the cursor landed). scroll_viewport_bottom is a no-op.
    assert_eq!(term.viewport_offset(), 0);

    // The cursor must be on the last live screen row (bottom area), not
    // stuck at the top because 66 lines scrolled past.
    let (row, _col) = term.cursor();
    assert!(row > 0, "cursor never moved after 66 lines of output");
}

#[test]
fn viewport_scrolled_up_then_new_output_snaps_back() {
    // User scrolls back in history while a command is running, then the
    // command finishes and the host calls scroll_viewport_bottom (which our
    // Swift PTY-read loop now does on every damage batch).
    let mut term = Terminal::new(80, 24);
    for _ in 0..50 {
        term.feed(b"history line\r\n");
    }
    // User scrolled up 15 lines.
    term.scroll_viewport_up(15);
    assert_eq!(term.viewport_offset(), 15);

    // New PTY data arrives (command output + prompt).
    term.feed(b"command output\r\n$ ");
    // Host calls scroll_viewport_bottom (done in the Swift PTY read loop).
    term.scroll_viewport_bottom();

    assert_eq!(term.viewport_offset(), 0, "viewport must snap to live screen");

    // The prompt text must be on the live screen.
    let live_rows: Vec<String> = (0..term.active_grid().rows())
        .map(|r| {
            term.viewport_row(r)
                .iter()
                .map(|c| if c.char == '\0' { ' ' } else { c.char })
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect();
    let screen = live_rows.join("\n");
    assert!(screen.contains("command output"), "command output missing from live screen");
    assert!(screen.contains('$'), "prompt missing from live screen");
}

#[test]
fn has_damage_reflects_synchronized_output_state() {
    let mut term = Terminal::new(80, 24);
    term.take_damage(); // clear initial damage

    // Open a Synchronized Output frame (mode 2026).
    term.feed(b"\x1b[?2026h");
    term.feed(b"mid-frame content\r\n");

    // While mode 2026 is active, has_damage must return false so hosts
    // don't paint a partial frame.
    assert!(!term.has_damage(), "must not report damage inside sync frame");

    // Close the frame.
    term.feed(b"\x1b[?2026l");
    assert!(term.has_damage(), "must report damage after sync frame closes");
}
