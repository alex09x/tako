/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{fill_row, row_chars, wide};
use crate::grid::*;

#[test]
fn test_scroll_up_across_many_wraparounds() {
    const ROWS: usize = 3;
    let mut g = Grid::with_scrollback_capacity(2, ROWS, 100);
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    let labels: Vec<char> = "defghijklm".chars().collect();
    let mut history: Vec<char> = vec!['a', 'b', 'c'];
    for (i, &ch) in labels.iter().enumerate() {
        g.scroll_up(1);
        fill_row(&mut g, ROWS - 1, ch);
        history.push(ch);

        // The visible window is always the last ROWS labels written.
        for (row, &expected) in history[history.len() - ROWS..].iter().enumerate() {
            assert_eq!(
                row_chars(&g, row),
                expected.to_string().repeat(2),
                "row {row} after scroll {i}"
            );
        }
        assert_eq!(g.scrollback_len(), i + 1);
        assert_eq!(
            g.scrollback_line(0).unwrap()[0].char,
            history[history.len() - ROWS - 1],
            "newest scrollback line after scroll {i}"
        );
    }

    // Scrollback keeps every evicted row in oldest-first order.
    let sb: Vec<char> = g.scrollback_iter().map(|line| line[0].char).collect();
    assert_eq!(sb, history[..history.len() - ROWS].to_vec());
}

#[test]
fn test_scroll_up_with_blank_uses_template_across_wraparound() {
    let mut g = Grid::new(3, 2);
    let blank = Cell {
        char: ' ',
        bg: Color::Rgb(9, 8, 7),
        attrs: CellAttrs::REVERSE,
        protected: true,
        ..Cell::default()
    };

    for i in 0..7 {
        g.scroll_up_with_blank(1, blank);
        for col in 0..3 {
            assert_eq!(g.get(1, col).unwrap(), &blank, "iteration {i}");
        }
    }

    // Mark the top row so a full-height scroll has something to overwrite.
    fill_row(&mut g, 0, 'k');
    g.scroll_up_with_blank(2, blank);
    for row in 0..2 {
        for col in 0..3 {
            assert_eq!(g.get(row, col).unwrap(), &blank, "row {row} col {col}");
        }
    }
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'k');
}

#[test]
fn test_line_wrapped_and_semantic_follow_rows_across_wraparound() {
    let mut g = Grid::new(2, 3);
    for i in 0..7 {
        g.scroll_up(1);
        // The row scrolled in at the bottom is always hard and unmarked.
        assert!(!g.is_line_wrapped(2), "iteration {i}");
        assert_eq!(
            g.row_semantic_prompt(2),
            SemanticPrompt::Unset,
            "iteration {i}"
        );
        g.set_line_wrapped(2, true);
        g.set_row_semantic_prompt(2, SemanticPrompt::Prompt);
    }

    // Every visible row was marked on one of the last three iterations.
    for row in 0..3 {
        assert!(g.is_line_wrapped(row), "row {row}");
        assert_eq!(
            g.row_semantic_prompt(row),
            SemanticPrompt::Prompt,
            "row {row}"
        );
    }

    g.scroll_up(1);
    assert!(g.is_line_wrapped(0));
    assert!(g.is_line_wrapped(1));
    assert!(!g.is_line_wrapped(2));
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(2), SemanticPrompt::Unset);
    // The wrapped flag rode into scrollback with its row.
    assert!(g.scrollback_line_wrapped(0));
}

#[test]
fn test_mutations_target_correct_rows_after_wraparound() {
    let mut g = Grid::new(4, 3);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    g.get_mut(1, 0).unwrap().char = 'B';
    assert_eq!(row_chars(&g, 0), "aaaa");
    assert_eq!(row_chars(&g, 1), "Bbbb");
    assert_eq!(row_chars(&g, 2), "cccc");

    g.clear_line(0, 2);
    assert_eq!(row_chars(&g, 0), "aa\0\0");
    assert_eq!(row_chars(&g, 1), "Bbbb");

    g.fill_cells(
        2,
        1,
        3,
        Cell {
            char: '-',
            ..Cell::default()
        },
    );
    assert_eq!(row_chars(&g, 2), "c--c");

    // A wide pair still lands inside a single row.
    assert!(g.set_wide(1, 2, wide('あ')));
    assert_eq!(g.get(1, 2).unwrap().char, 'あ');
    assert!(g.get(1, 3).unwrap().is_wide_spacer);
    assert_eq!(row_chars(&g, 0), "aa\0\0");
    assert_eq!(row_chars(&g, 2), "c--c");

    g.clear_line_full(1);
    assert_eq!(row_chars(&g, 1), "\0\0\0\0");
    assert_eq!(row_chars(&g, 2), "c--c");

    // Out-of-range writes stay no-ops rather than wrapping onto a live row.
    g.set(
        3,
        0,
        Cell {
            char: '!',
            ..Cell::default()
        },
    );
    g.set(
        5,
        0,
        Cell {
            char: '!',
            ..Cell::default()
        },
    );
    assert_eq!(row_chars(&g, 0), "aa\0\0");
    assert_eq!(row_chars(&g, 2), "c--c");
    assert!(g.get(3, 0).is_none());
}

#[test]
fn test_dirty_flags_follow_logical_rows_after_wraparound() {
    let mut g = Grid::new(2, 3);
    for _ in 0..4 {
        g.scroll_up(1);
    }
    g.clear_dirty();
    for row in 0..3 {
        assert!(!g.is_dirty(row), "row {row}");
    }

    g.set(
        1,
        0,
        Cell {
            char: 'x',
            ..Cell::default()
        },
    );
    assert!(!g.is_dirty(0));
    assert!(g.is_dirty(1));
    assert!(!g.is_dirty(2));

    g.clear_dirty();
    g.mark_dirty(2);
    assert!(!g.is_dirty(0));
    assert!(!g.is_dirty(1));
    assert!(g.is_dirty(2));

    // Out-of-range rows must not alias onto a live row.
    g.clear_dirty();
    g.mark_dirty(3);
    g.mark_dirty(5);
    for row in 0..3 {
        assert!(!g.is_dirty(row), "row {row}");
    }
}

#[test]
fn test_scroll_up_clamps_at_grid_height() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    // n == rows, and n > rows, both blank the screen wholesale.
    g.scroll_up(3);
    assert_eq!(g.scrollback_line(2).unwrap()[0].char, 'a');
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'b');
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'c');
    for row in 0..3 {
        assert_eq!(row_chars(&g, row), "\0\0", "row {row}");
    }

    fill_row(&mut g, 1, 'z');
    assert_eq!(row_chars(&g, 0), "\0\0");
    assert_eq!(row_chars(&g, 1), "zz");
    assert_eq!(row_chars(&g, 2), "\0\0");

    let before = g.scrollback_len();
    g.scroll_up(9);
    assert_eq!(g.scrollback_len(), before + 3);
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'z');
    for row in 0..3 {
        assert_eq!(row_chars(&g, row), "\0\0", "row {row}");
    }
}

#[test]
fn test_stash_top_rows_after_wraparound() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for _ in 0..4 {
        g.scroll_up(1);
    }
    let before = g.scrollback_len();
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }
    g.set_line_wrapped(1, true);

    g.stash_top_rows(2);
    assert_eq!(g.scrollback_len(), before + 2);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'b');
    assert!(g.scrollback_line_wrapped(0));
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'a');
    assert!(!g.scrollback_line_wrapped(1));

    // Nothing on screen moved.
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert_eq!(row_chars(&g, 2), "cc");
}

#[test]
fn test_clear_all_after_wraparound() {
    let mut g = Grid::new(3, 3);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for row in 0..3 {
        fill_row(&mut g, row, 'x');
    }
    g.set_line_wrapped(1, true);

    g.clear_all();
    for row in 0..3 {
        assert_eq!(row_chars(&g, row), "\0\0\0", "row {row}");
        assert!(!g.is_line_wrapped(row), "row {row}");
    }
}

#[test]
fn test_resize_rows_after_wraparound() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }
    g.set_line_wrapped(2, true);
    g.set_row_semantic_prompt(1, SemanticPrompt::Prompt);

    // Grow: content stays anchored at the top, blanks appended below.
    g.resize(2, 5);
    assert_eq!(g.rows(), 5);
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert_eq!(row_chars(&g, 2), "cc");
    assert_eq!(row_chars(&g, 3), "\0\0");
    assert_eq!(row_chars(&g, 4), "\0\0");
    assert!(g.is_line_wrapped(2));
    assert!(!g.is_line_wrapped(3));
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Unset);

    // Shrink: blank padding is trimmed first, then only the remaining top row
    // goes to scrollback.
    let before = g.scrollback_len();
    g.resize(2, 2);
    assert_eq!(g.rows(), 2);
    assert_eq!(g.scrollback_len(), before + 1);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'a');
    assert_eq!(row_chars(&g, 0), "bb");
    assert_eq!(row_chars(&g, 1), "cc");
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::Unset);

    // And it still scrolls correctly once the ring has been rebuilt.
    fill_row(&mut g, 1, 'q');
    g.scroll_up(1);
    assert_eq!(row_chars(&g, 0), "qq");
    assert_eq!(row_chars(&g, 1), "\0\0");
}

#[test]
fn test_debug_is_independent_of_physical_rotation() {
    let mut rotated = Grid::with_scrollback_capacity(3, 3, 0);
    for _ in 0..4 {
        rotated.scroll_up(1);
    }
    let mut fresh = Grid::with_scrollback_capacity(3, 3, 0);
    fresh.history_evicted = rotated.history_evicted;

    for g in [&mut rotated, &mut fresh] {
        for row in 0..3 {
            fill_row(g, row, 'q');
        }
        g.set_line_wrapped(2, true);
        g.set_row_semantic_prompt(0, SemanticPrompt::Prompt);
    }

    assert_eq!(rotated.scrollback_len(), 0);
    assert_eq!(format!("{rotated:?}"), format!("{fresh:?}"));

    // A clone of a rotated grid behaves (and formats) like its source.
    let cloned = rotated.clone();
    assert_eq!(format!("{cloned:?}"), format!("{rotated:?}"));
    for row in 0..3 {
        assert_eq!(row_chars(&cloned, row), row_chars(&rotated, row));
    }
}

#[test]
fn test_clone_after_wraparound_scrolls_independently() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    let mut cloned = g.clone();
    cloned.scroll_up(1);
    fill_row(&mut cloned, 2, 'd');

    // Original has a, b, c; clone has b, c, d.
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert_eq!(row_chars(&g, 2), "cc");
    assert_eq!(row_chars(&cloned, 0), "bb");
    assert_eq!(row_chars(&cloned, 1), "cc");
    assert_eq!(row_chars(&cloned, 2), "dd");
}
