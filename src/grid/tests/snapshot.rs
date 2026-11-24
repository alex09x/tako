/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! A grid taken apart and put back -- as a checkpoint does -- is the same
//! grid: its rows, wraps, prompt marks and history, with history beyond
//! the capacity dropped oldest first.

use super::{fill_row, row_chars};
use crate::grid::*;

/// A 4x3 grid with two lines of history, a wrapped row and a prompt mark.
fn grid() -> Grid {
    let mut g = Grid::with_scrollback_capacity(4, 3, 10);
    for (row, ch) in ['a', 'b', 'c'].into_iter().enumerate() {
        fill_row(&mut g, row, ch);
    }
    g.scroll_up(2);
    fill_row(&mut g, 1, 'd');
    fill_row(&mut g, 2, 'e');
    g.set_line_wrapped(1, true);
    g.set_row_semantic_prompt(2, SemanticPrompt::Prompt);
    g
}

#[test]
fn a_grid_taken_apart_and_put_back_is_the_same_grid() {
    let g = grid();
    let (cols, rows, capacity, evicted, cells, wrapped, semantic, history) = g.raw_parts();
    assert_eq!((cols, rows, capacity, evicted), (4, 3, 10, 0));
    assert_eq!(
        (wrapped.as_slice(), history.len()),
        ([false, true, false].as_slice(), 2)
    );
    assert_eq!(semantic[2], SemanticPrompt::Prompt);

    let back = Grid::from_raw_parts(
        cols, rows, capacity, evicted, cells, wrapped, semantic, history,
    );
    assert_eq!(
        (0..3).map(|r| row_chars(&back, r)).collect::<Vec<_>>(),
        (0..3).map(|r| row_chars(&g, r)).collect::<Vec<_>>()
    );
    assert_eq!(back.scrollback_len(), 2);
    assert_eq!(
        back.scrollback_line(0).unwrap()[0].char,
        'b',
        "the newest history line"
    );
    assert!(back.is_line_wrapped(1) && !back.is_line_wrapped(0));
    assert_eq!(back.row_semantic_prompt(2), SemanticPrompt::Prompt);
}

#[test]
fn history_beyond_the_capacity_is_dropped_oldest_first() {
    let (cols, rows, _, evicted, cells, wrapped, semantic, history) = grid().raw_parts();
    let back = Grid::from_raw_parts(cols, rows, 1, evicted, cells, wrapped, semantic, history);
    assert_eq!(back.scrollback_len(), 1);
    assert_eq!(
        back.scrollback_line(0).unwrap()[0].char,
        'b',
        "a, the oldest, went"
    );
}

#[test]
fn short_or_narrow_parts_are_padded_to_the_size_given() {
    let back = Grid::from_raw_parts(
        3,
        2,
        5,
        0,
        vec![vec![Cell {
            char: 'x',
            ..Cell::default()
        }]],
        vec![],
        vec![],
        vec![],
    );
    assert_eq!((back.cols(), back.rows()), (3, 2));
    assert_eq!(row_chars(&back, 0), "x\0\0");
    assert_eq!(row_chars(&back, 1), "\0\0\0");
    assert!(!back.is_line_wrapped(1));
    let none = Grid::from_raw_parts(0, 0, 0, 0, vec![], vec![], vec![], vec![]);
    assert_eq!(
        (none.cols(), none.rows()),
        (1, 1),
        "never smaller than one cell"
    );
}

#[test]
fn a_cluster_is_restored_only_onto_a_cell_that_exists() {
    let mut g = grid();
    assert!(g.restore_cluster(0, 1, "\u{301}", false), "a history cell");
    assert!(g.restore_cluster(3, 0, "\u{301}", false), "a visible cell");
    assert!(!g.restore_cluster(9, 0, "\u{301}", false), "no such line");
    assert!(!g.restore_cluster(0, 9, "\u{301}", false), "no such column");
    assert!(!g.restore_cluster(3, 0, "", false), "nothing to add");
    assert_eq!(g.clusters().len(), 2);
    assert!(g.retained_capacity_bytes() > 0);
}
