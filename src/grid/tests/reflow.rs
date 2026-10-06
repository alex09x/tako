/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{assert_no_orphans, fill_row, row_chars, wide};
use crate::grid::*;

#[test]
fn test_reflow_never_splits_wide_pair() {
    let mut g = Grid::new(6, 2);
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
    assert!(g.set_wide(0, 2, wide('あ')));
    g.set(
        0,
        4,
        Cell {
            char: 'c',
            ..Cell::default()
        },
    );
    g.set(
        0,
        5,
        Cell {
            char: 'd',
            ..Cell::default()
        },
    );

    // Width 3 would put the wide cell in the last column of row 0 and its
    // spacer at the start of row 1; the pair must move down together.
    g.resize(3, 6);
    assert_eq!(g.cols(), 3);

    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(0, 1).unwrap().char, 'b');
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());

    assert_eq!(g.get(1, 0).unwrap().char, 'あ');
    assert!(g.get(1, 1).unwrap().is_wide_spacer);
    assert_eq!(g.get(1, 2).unwrap().char, 'c');
    assert_eq!(g.get(2, 0).unwrap().char, 'd');
    assert!(g.is_line_wrapped(1));

    for row in 0..g.rows() {
        let line: Vec<Cell> = (0..g.cols()).map(|c| *g.get(row, c).unwrap()).collect();
        assert_no_orphans(&line);
        // A wide cell must never end a line: its spacer would have to live
        // on the next row.
        let last = line[g.cols() - 1];
        assert!(
            last.is_wide_spacer || last.char != 'あ',
            "wide cell orphaned in the last column of row {row}"
        );
    }
    assert_eq!(g.scrollback_len(), 0);
}

#[test]
fn test_reflow_grow_keeps_pair_together() {
    let mut g = Grid::new(3, 3);
    assert!(g.set_wide(0, 0, wide('あ')));
    g.set(
        0,
        2,
        Cell {
            char: 'x',
            ..Cell::default()
        },
    );
    g.set_line_wrapped(1, true);
    assert!(g.set_wide(1, 0, wide('い')));

    g.resize(5, 3);
    let line: Vec<Cell> = (0..5).map(|c| *g.get(0, c).unwrap()).collect();
    assert_no_orphans(&line);
    assert_eq!(line[0].char, 'あ');
    assert!(line[1].is_wide_spacer);
    assert_eq!(line[2].char, 'x');
    assert_eq!(line[3].char, 'い');
    assert!(line[4].is_wide_spacer);
}

#[test]
fn test_reflow_after_wraparound_reads_logical_rows() {
    let mut g = Grid::with_scrollback_capacity(6, 3, 100);
    for _ in 0..7 {
        g.scroll_up(1);
    }
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
    for (i, ch) in "ghi".chars().enumerate() {
        g.set(
            1,
            i,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }
    let scrollback_before = g.scrollback_len();

    g.resize(3, 4);
    assert_eq!(g.cols(), 3);
    assert_eq!(g.rows(), 4);
    assert_eq!(row_chars(&g, 0), "abc");
    assert_eq!(row_chars(&g, 1), "def");
    assert_eq!(row_chars(&g, 2), "ghi");
    assert_eq!(row_chars(&g, 3), "\0\0\0");
    assert!(!g.is_line_wrapped(0));
    assert!(g.is_line_wrapped(1));
    assert!(!g.is_line_wrapped(2));
    // Reflow of the visible screen must not disturb scrollback.
    assert_eq!(g.scrollback_len(), scrollback_before);

    // Scrolling still works against the rebuilt storage.
    g.scroll_up(1);
    assert_eq!(row_chars(&g, 0), "def");
    assert_eq!(row_chars(&g, 1), "ghi");
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'a');
}

#[test]
fn test_resize_no_reflow_after_wraparound() {
    let mut g = Grid::new(4, 3);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }
    g.set_line_wrapped(1, true);
    g.set_row_semantic_prompt(1, SemanticPrompt::PromptContinuation);

    g.resize_no_reflow(2, 2);
    assert_eq!(g.cols(), 2);
    assert_eq!(g.rows(), 2);
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert!(!g.is_line_wrapped(0));
    assert!(g.is_line_wrapped(1));
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Unset);
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::PromptContinuation);

    g.scroll_up(1);
    assert_eq!(row_chars(&g, 0), "bb");
    assert_eq!(row_chars(&g, 1), "\0\0");
}

#[test]
fn test_resize_no_reflow_after_wraparound_trims_orphan_wide_cell() {
    let mut g = Grid::new(4, 2);
    for _ in 0..3 {
        g.scroll_up(1);
    }
    assert!(g.set_wide(0, 1, wide('あ')));
    // Truncating to 2 columns would keep the wide half but drop its spacer.
    g.resize_no_reflow(2, 2);
    assert_eq!(g.cols(), 2);
    let line: Vec<Cell> = (0..2).map(|c| *g.get(0, c).unwrap()).collect();
    assert_eq!(line[1], Cell::default());
    assert_no_orphans(&line);
}
