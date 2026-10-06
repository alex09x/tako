/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::cursor_style::{CursorShape, CursorStyle};
use crate::grid::{CellAttrs, Color};
use crate::terminal::*;

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
    g.set(
        0,
        0,
        crate::grid::Cell {
            char: 'A',
            ..Default::default()
        },
    );
    g.set(
        0,
        1,
        crate::grid::Cell {
            char: 'B',
            ..Default::default()
        },
    );
    g.set(
        1,
        0,
        crate::grid::Cell {
            char: 'C',
            ..Default::default()
        },
    );
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
    assert_eq!(
        g.row_semantic_prompt(2),
        crate::grid::SemanticPrompt::Prompt
    );
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
fn test_rep_repeats_last_printed_char() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"A\x1b[3b"); // print 'A', then REP(3) repeats it 3 more times
    let row: String = (0..4)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .collect();
    assert_eq!(row, "AAAA");
}

#[test]
fn test_decscusr_sets_cursor_style() {
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
    assert!(
        !term
            .active_grid()
            .get(0, 0)
            .unwrap()
            .attrs
            .contains(CellAttrs::BOLD)
    );
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
    assert!(
        !term
            .active_grid()
            .get(0, 0)
            .unwrap()
            .attrs
            .contains(CellAttrs::BOLD)
    );
}

#[test]
fn test_osc4_set_and_query_palette() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]4;1;#ff8000\x07"); // set palette index 1
    assert_eq!(term.palette().get(1), (255, 128, 0));
    term.feed(b"\x1b]4;1;?\x07"); // query it back
    assert_eq!(
        term.take_output(),
        b"\x1b]4;1;rgb:ffff/8080/0000\x1b\\".to_vec()
    );
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
    let row0: String = (0..3)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .collect();
    assert_eq!(row0, "BBB");
    term.feed(b"\x1b[1T"); // SD: content moves back down, top row blank
    let row0b: String = (0..3)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    let row1: String = (0..3)
        .map(|c| term.active_grid().get(1, c).unwrap().char)
        .collect();
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
