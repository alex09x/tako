/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{assert_no_orphans, row_chars, wide};
use crate::grid::*;

#[test]
fn test_resize_shrink_rows_pushes_scrollback() {
    let mut g = Grid::new(3, 4);
    for row in 0..4 {
        g.set(
            row,
            0,
            Cell {
                char: (b'a' + row as u8) as char,
                ..Cell::default()
            },
        );
    }
    g.resize(3, 2);
    assert_eq!(g.rows(), 2);
    // Top two rows ('a','b') should have been pushed to scrollback.
    assert_eq!(g.scrollback_len(), 2);
    // Remaining visible rows should be 'c' and 'd'.
    assert_eq!(g.get(0, 0).unwrap().char, 'c');
    assert_eq!(g.get(1, 0).unwrap().char, 'd');
    // Scrollback nearest bottom should be 'b' (most recently pushed off).
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'b');
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'a');
}

#[test]
fn test_resize_shrink_trims_blank_bottom_before_scrollback() {
    let mut g = Grid::new(3, 5);
    g.set(
        0,
        0,
        Cell {
            char: 'a',
            ..Cell::default()
        },
    );
    g.set(
        1,
        0,
        Cell {
            char: 'b',
            ..Cell::default()
        },
    );

    g.resize(3, 3);

    assert_eq!(g.rows(), 3);
    assert_eq!(g.scrollback_len(), 0);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(1, 0).unwrap().char, 'b');
    assert_eq!(g.get(2, 0).unwrap(), &Cell::default());
}

#[test]
fn test_resize_shrink_does_not_trim_the_cursor_row() {
    let mut g = Grid::new(3, 5);
    g.set(
        0,
        0,
        Cell {
            char: 'a',
            ..Cell::default()
        },
    );

    g.resize_with_cursor(3, 2, Some((3, 0)));

    // Row 4 is disposable padding, but the blank cursor row 3 is meaningful.
    // Two additional rows therefore leave through the top so the cursor stays
    // visible at the bottom of the smaller grid.
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(g.get(1, 0).unwrap(), &Cell::default());
}

#[test]
fn test_resize_grow_pulls_adjacent_history_when_cursor_was_at_bottom() {
    let mut g = Grid::new(3, 4);
    for (row, ch) in ['a', 'b', 'c', 'd'].into_iter().enumerate() {
        g.set(
            row,
            0,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }

    g.resize_with_cursor(3, 2, Some((3, 0)));
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(row_chars(&g, 0), "c\0\0");
    assert_eq!(row_chars(&g, 1), "d\0\0");

    let cursor_pos = g.resize_with_cursor(3, 4, Some((1, 0)));
    assert_eq!(cursor_pos, Some((3, 0)));
    assert_eq!(g.scrollback_len(), 0);
    assert_eq!(row_chars(&g, 0), "a\0\0");
    assert_eq!(row_chars(&g, 1), "b\0\0");
    assert_eq!(row_chars(&g, 2), "c\0\0");
    assert_eq!(row_chars(&g, 3), "d\0\0");
}

#[test]
fn test_resize_grow_keeps_history_when_cursor_was_above_bottom() {
    let mut g = Grid::new(3, 4);
    for (row, ch) in ['a', 'b', 'c', 'd'].into_iter().enumerate() {
        g.set(
            row,
            0,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }
    g.resize_with_cursor(3, 2, Some((3, 0)));

    let cursor_pos = g.resize_with_cursor(3, 4, Some((0, 0)));
    assert_eq!(cursor_pos, Some((0, 0)));
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(row_chars(&g, 0), "c\0\0");
    assert_eq!(row_chars(&g, 1), "d\0\0");
    assert_eq!(row_chars(&g, 2), "\0\0\0");
    assert_eq!(row_chars(&g, 3), "\0\0\0");
}

#[test]
fn test_resize_grow_keeps_history_when_grid_has_no_active_cursor() {
    let mut g = Grid::new(3, 4);
    for (row, ch) in ['a', 'b', 'c', 'd'].into_iter().enumerate() {
        g.set(
            row,
            0,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }
    g.resize_with_cursor(3, 2, Some((3, 0)));

    // Terminal::resize passes None for the inactive primary/alternate grid.
    // Without evidence that its own cursor was at the bottom, growing that
    // grid must append blanks rather than silently changing its viewport.
    let cursor_pos = g.resize_with_cursor(3, 4, None);
    assert_eq!(cursor_pos, None);
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(row_chars(&g, 0), "c\0\0");
    assert_eq!(row_chars(&g, 1), "d\0\0");
    assert_eq!(row_chars(&g, 2), "\0\0\0");
    assert_eq!(row_chars(&g, 3), "\0\0\0");
}

#[test]
fn test_resize_grow_cols_preserves_content() {
    let mut g = Grid::new(3, 2);
    g.set(
        0,
        0,
        Cell {
            char: 'a',
            ..Cell::default()
        },
    );
    g.set(
        0,
        1,
        Cell {
            char: 'b',
            ..Cell::default()
        },
    );
    g.set(
        0,
        2,
        Cell {
            char: 'c',
            ..Cell::default()
        },
    );
    g.resize(6, 2);
    assert_eq!(g.cols(), 6);
    assert_eq!(g.rows(), 2);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(0, 1).unwrap().char, 'b');
    assert_eq!(g.get(0, 2).unwrap().char, 'c');
    assert_eq!(g.get(0, 3).unwrap(), &Cell::default());
}

#[test]
fn test_resize_shrink_cols_rewraps_line() {
    let mut g = Grid::new(6, 2);
    // Single hard line "abcdef" on row 0 (row 1 stays blank/hard).
    for (i, ch) in "abcdef".chars().enumerate() {
        g.set(
            0,
            i,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }
    g.resize(3, 4);
    assert_eq!(g.cols(), 3);
    assert_eq!(g.rows(), 4);
    // "abcdef" should now be wrapped across two rows of width 3: "abc","def"
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(0, 1).unwrap().char, 'b');
    assert_eq!(g.get(0, 2).unwrap().char, 'c');
    assert_eq!(g.get(1, 0).unwrap().char, 'd');
    assert_eq!(g.get(1, 1).unwrap().char, 'e');
    assert_eq!(g.get(1, 2).unwrap().char, 'f');
    assert!(g.is_line_wrapped(1));
    assert!(!g.is_line_wrapped(0));
}

#[test]
fn test_resize_does_not_panic_on_various_sizes() {
    let mut g = Grid::new(10, 10);
    g.resize(1, 1);
    assert_eq!(g.cols(), 1);
    assert_eq!(g.rows(), 1);
    g.resize(80, 24);
    assert_eq!(g.cols(), 80);
    assert_eq!(g.rows(), 24);
    // Resizing to 0 should clamp to 1 rather than panic/produce empty grid.
    g.resize(0, 0);
    assert_eq!(g.cols(), 1);
    assert_eq!(g.rows(), 1);
}

#[test]
fn test_scrollback_iter_oldest_first() {
    let mut g = Grid::new(2, 1);
    for i in 0..3u8 {
        g.set(
            0,
            0,
            Cell {
                char: (b'a' + i) as char,
                ..Cell::default()
            },
        );
        g.scroll_up(1);
    }
    let chars: Vec<char> = g.scrollback_iter().map(|line| line[0].char).collect();
    assert_eq!(chars, vec!['a', 'b', 'c']);
}

#[test]
fn test_set_wide_writes_pair_and_returns_true() {
    let mut g = Grid::new(4, 2);
    let cell = wide('あ');
    assert!(g.set_wide(1, 1, cell));

    let head = *g.get(1, 1).unwrap();
    assert_eq!(head, cell);
    assert!(!head.is_wide_spacer);

    let spacer = *g.get(1, 2).unwrap();
    assert_eq!(spacer.char, ' ');
    assert!(spacer.is_wide_spacer);
    assert_eq!(spacer.fg, cell.fg);
    assert_eq!(spacer.bg, cell.bg);
    assert_eq!(spacer.attrs, cell.attrs);
    assert_eq!(spacer.hyperlink, cell.hyperlink);

    // Neighbors untouched.
    assert_eq!(g.get(1, 0).unwrap(), &Cell::default());
    assert_eq!(g.get(1, 3).unwrap(), &Cell::default());
}

#[test]
fn test_set_wide_at_last_column_returns_false_and_writes_nothing() {
    let mut g = Grid::new(4, 1);
    assert!(!g.set_wide(0, 3, wide('あ')));
    for col in 0..4 {
        assert_eq!(g.get(0, col).unwrap(), &Cell::default());
    }
    // Out-of-range rows are rejected too.
    assert!(!g.set_wide(9, 0, wide('あ')));
}

#[test]
fn test_clear_line_full_clears_whole_pair() {
    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    g.clear_line_full(0);
    for col in 0..4 {
        assert_eq!(g.get(0, col).unwrap(), &Cell::default());
    }
}

#[test]
fn test_clear_all_clears_whole_pair() {
    let mut g = Grid::new(4, 2);
    assert!(g.set_wide(1, 2, wide('あ')));
    g.clear_all();
    for row in 0..2 {
        for col in 0..4 {
            assert_eq!(g.get(row, col).unwrap(), &Cell::default());
        }
    }
}

#[test]
fn test_clearing_wide_half_also_clears_spacer() {
    // clear_line starts at the wide cell; the spacer to its right is in
    // range anyway, but clear_line_to must reach forward to it.
    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    g.clear_line_to(0, 1);
    assert_eq!(g.get(0, 1).unwrap(), &Cell::default());
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());
    assert_no_orphans(&(0..4).map(|c| *g.get(0, c).unwrap()).collect::<Vec<_>>());
}

#[test]
fn test_clearing_spacer_half_also_clears_wide_cell() {
    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    // Range starts at the spacer: must reach back to the wide half.
    g.clear_line(0, 2);
    assert_eq!(g.get(0, 1).unwrap(), &Cell::default());
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());
    assert_no_orphans(&(0..4).map(|c| *g.get(0, c).unwrap()).collect::<Vec<_>>());

    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    g.clear_line_full(0);
    assert!(g.set_wide(0, 1, wide('い')));
    g.clear_line_to(0, 2);
    assert_eq!(g.get(0, 1).unwrap(), &Cell::default());
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());
}

#[test]
fn test_scroll_up_preserves_wide_pair_in_scrollback() {
    let mut g = Grid::new(4, 2);
    assert!(g.set_wide(0, 0, wide('あ')));
    g.scroll_up(1);

    let line = g.scrollback_line(0).unwrap();
    assert_eq!(line[0].char, 'あ');
    assert!(!line[0].is_wide_spacer);
    assert!(line[1].is_wide_spacer);
    assert_eq!(line[1].bg, Color::Rgb(1, 2, 3));
    assert_no_orphans(line);

    // The vacated row is blank.
    assert_eq!(g.get(1, 0).unwrap(), &Cell::default());
}
