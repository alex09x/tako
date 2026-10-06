/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::wide;
use crate::grid::*;

#[test]
fn test_grid_resize_reflow_cursor_placement_wrapped_lines() {
    let mut g = Grid::new(10, 4);
    // Write a 25-char line across rows 0, 1, 2
    let text = "abcdefghijklmnopqrstuvwxy";
    for (i, ch) in text.chars().enumerate() {
        let r = i / 10;
        let c = i % 10;
        g.set(
            r,
            c,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
        if r > 0 {
            g.set_line_wrapped(r, true);
        }
    }
    // Cursor on 'm' (index 12 -> row 1, col 2 at width 10)
    assert_eq!(g.get(1, 2).unwrap().char, 'm');

    // Resize to width 5, height 8
    // In width 5, 'm' (index 12) is at row 2, col 2 (12 / 5 = 2, 12 % 5 = 2)
    let new_pos = g.resize_with_cursor(5, 8, Some((1, 2)));
    assert_eq!(new_pos, Some((2, 2)));
    assert_eq!(g.get(2, 2).unwrap().char, 'm');

    // Resize to width 25, height 4
    // In width 25, 'm' (index 12) is at row 0, col 12
    let new_pos = g.resize_with_cursor(25, 4, Some((2, 2)));
    assert_eq!(new_pos, Some((0, 12)));
    assert_eq!(g.get(0, 12).unwrap().char, 'm');
}

#[test]
fn test_grid_resize_reflow_cursor_on_trailing_blank_cells() {
    let mut g = Grid::new(20, 2);
    // Write 5 characters on row 0
    for (c, ch) in "hello".chars().enumerate() {
        g.set(
            0,
            c,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }
    // Cursor is at col 15 (a blank cell on row 0)
    let new_pos = g.resize_with_cursor(10, 4, Some((0, 15)));
    // At width 10, offset 15 is row 1, col 5
    assert_eq!(new_pos, Some((1, 5)));

    // Resize back to width 20, height 2
    let new_pos2 = g.resize_with_cursor(20, 2, Some((1, 5)));
    assert_eq!(new_pos2, Some((0, 15)));
}

#[test]
fn test_grid_resize_reflow_cursor_with_wide_characters() {
    let mut g = Grid::new(10, 2);
    g.set(
        0,
        0,
        Cell {
            char: 'a',
            ..Cell::default()
        },
    );
    g.set_wide(0, 1, wide('あ')); // cols 1 and 2
    g.set(
        0,
        3,
        Cell {
            char: 'b',
            ..Cell::default()
        },
    );

    // Cursor on 'あ' (col 1)
    let pos = g.resize_with_cursor(4, 4, Some((0, 1)));
    assert_eq!(pos, Some((0, 1)));
    assert_eq!(g.get(0, 1).unwrap().char, 'あ');

    // Cursor on spacer (col 2)
    let pos = g.resize_with_cursor(4, 4, Some((0, 2)));
    assert_eq!(pos, Some((0, 2)));
    assert!(g.get(0, 2).unwrap().is_wide_spacer);

    // Cursor on 'b' (col 3)
    let pos = g.resize_with_cursor(4, 4, Some((0, 3)));
    assert_eq!(pos, Some((0, 3)));
    assert_eq!(g.get(0, 3).unwrap().char, 'b');

    // If width shrinks to 2: 'a' is at (0, 0), wide pair 'あ' cannot fit on row 0, wraps to (1, 0)
    let pos = g.resize_with_cursor(2, 4, Some((0, 1)));
    assert_eq!(pos, Some((1, 0)));
    assert_eq!(g.get(1, 0).unwrap().char, 'あ');
}

#[test]
fn grapheme_clusters_are_interned_once_per_width() {
    let mut g = Grid::new(4, 2);
    assert_eq!(g.intern_grapheme("", false), 0);
    let narrow = g.intern_grapheme("\u{0301}", false);
    assert_ne!(narrow, 0);
    assert_eq!(g.intern_grapheme("\u{0301}", false), narrow);
    let wide = g.intern_grapheme("\u{0301}", true);
    assert_ne!(wide, narrow);
    let before = g.retained_capacity_bytes();
    g.set(
        0,
        0,
        Cell {
            char: 'q',
            grapheme: narrow,
            ..Cell::default()
        },
    );
    g.set_wide(
        0,
        1,
        Cell {
            char: '\u{1F44D}',
            grapheme: wide,
            ..Cell::default()
        },
    );
    let cell = *g.get(0, 0).unwrap();
    assert_eq!(g.grapheme(&cell), "\u{0301}");
    assert!(!g.cell_is_wide(&cell));
    assert!(g.cell_is_wide(g.get(0, 1).unwrap()));
    // The spacer names no cluster of its own.
    assert_eq!(g.get(0, 2).unwrap().grapheme, 0);
    let mut text = String::new();
    for col in 0..4 {
        g.push_cell_text(&mut text, g.get(0, col).unwrap());
    }
    assert_eq!(text, "q\u{0301}\u{1F44D}\u{0301}  ");
    assert_eq!(g.grapheme(&Cell::default()), "");
    assert!(g.retained_capacity_bytes() >= before);
}

#[test]
fn unused_grapheme_entries_are_reclaimed_and_live_ones_kept() {
    let mut g = Grid::with_scrollback_capacity(4, 2, 4);
    let kept = g.intern_grapheme("\u{0301}", false);
    g.set(
        0,
        0,
        Cell {
            char: 'q',
            grapheme: kept,
            ..Cell::default()
        },
    );
    g.scroll_up(1);
    let visible = g.intern_grapheme("\u{0302}", false);
    g.set(
        1,
        0,
        Cell {
            char: 'a',
            grapheme: visible,
            ..Cell::default()
        },
    );
    for n in 0..10_000 {
        g.intern_grapheme(&format!("\u{0303}{n}"), false);
    }
    assert!(g.graphemes.live() <= 4096, "{}", g.graphemes.live());
    let history = g.scrollback_line(0).unwrap()[0];
    assert_eq!(g.grapheme(&history), "\u{0301}");
    assert_eq!(g.grapheme(g.get(1, 0).unwrap()), "\u{0302}");
    // A reclaimed cluster interns again under a fresh or reused id.
    let again = g.intern_grapheme("\u{0303}0", false);
    assert_ne!(again, 0);
}

#[test]
fn a_full_grapheme_table_refuses_new_clusters_until_ids_are_free() {
    let mut g = Grid::with_scrollback_capacity(256, 256, 0);
    let mut stored = 0;
    'fill: for row in 0..256 {
        for col in 0..256 {
            let id = g.intern_grapheme(&format!("{row}:{col}"), false);
            if id == 0 {
                break 'fill;
            }
            g.set(
                row,
                col,
                Cell {
                    char: 'a',
                    grapheme: id,
                    ..Cell::default()
                },
            );
            stored += 1;
        }
    }
    assert_eq!(stored, u16::MAX as usize);
    assert_eq!(g.intern_grapheme("more", false), 0);
    // Clusters already interned are still found.
    assert_eq!(
        g.intern_grapheme("0:0", false),
        g.get(0, 0).unwrap().grapheme
    );

    // Once cells stop naming them, a later collection frees the ids; until
    // then the table refuses without rescanning the grid every time.
    g.clear_all();
    let mut refused = 0;
    while g.intern_grapheme("more", false) == 0 {
        refused += 1;
        assert!(refused <= 4096, "never collected");
    }
    assert!(refused > 0);
    assert!(g.graphemes.live() < 16);
}

#[test]
fn a_grapheme_id_costs_a_cell_no_bytes() {
    // The id sits in padding the cell already had.
    assert_eq!(std::mem::size_of::<Cell>(), 32);
}

#[test]
fn test_row_owner_transitions() {
    let empty = RowOwner::Empty;
    let unowned = RowOwner::Unowned;
    let mixed = RowOwner::Mixed;
    let cmd1 = RowOwner::Command(1);

    assert_eq!(empty.after_write(Some(1)), cmd1);
    assert_eq!(empty.after_write(None), unowned);

    // Unowned + partial print gives Mixed
    assert_eq!(unowned.after_write(Some(1)), mixed);
    assert_eq!(unowned.after_write(None), unowned);

    // Command + same command stays
    assert_eq!(cmd1.after_write(Some(1)), cmd1);
    // Command + different command gives Mixed
    assert_eq!(cmd1.after_write(Some(2)), mixed);
    // Command + outside command gives Mixed
    assert_eq!(cmd1.after_write(None), mixed);

    // Mixed -> print outside command -> new command
    assert_eq!(mixed.after_write(None), mixed);
    assert_eq!(mixed.after_write(Some(2)), mixed);
}
