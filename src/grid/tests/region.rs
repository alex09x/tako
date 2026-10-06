/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{fill_row, row_chars};
use crate::grid::*;

#[test]
fn test_scroll_region_up_rotates_only_region_after_global_wraparound() {
    let mut g = Grid::with_scrollback_capacity(2, 5, 0);
    for (row, ch) in ['A', 'B', 'C', 'D', 'E'].into_iter().enumerate() {
        fill_row(&mut g, row, ch);
    }

    // Put the global circular origin in the middle of the physical buffer,
    // then repopulate the newly-exposed bottom row.
    g.scroll_up(1);
    fill_row(&mut g, 4, 'F');
    g.set_line_wrapped(1, true);
    g.set_line_wrapped(2, false);
    g.set_row_semantic_prompt(1, SemanticPrompt::Prompt);
    g.set_row_semantic_prompt(2, SemanticPrompt::PromptContinuation);
    g.set_row_semantic_prompt(3, SemanticPrompt::Prompt);
    g.clear_dirty();

    let blank = Cell {
        char: '#',
        ..Cell::default()
    };
    g.scroll_region_up_with_blank(1, 3, 1, blank);

    assert_eq!(row_chars(&g, 0), "BB");
    assert_eq!(row_chars(&g, 1), "DD");
    assert_eq!(row_chars(&g, 2), "EE");
    assert_eq!(row_chars(&g, 3), "##");
    assert_eq!(row_chars(&g, 4), "FF");
    assert!(!g.is_line_wrapped(1));
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::PromptContinuation);
    assert_eq!(g.row_semantic_prompt(2), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(3), SemanticPrompt::Unset);
    assert!(!g.is_dirty(0));
    assert!(g.is_dirty(1));
    assert!(g.is_dirty(2));
    assert!(g.is_dirty(3));
    assert!(!g.is_dirty(4));
    assert_eq!(g.scrollback_len(), 0);
}

#[test]
fn test_region_rotation_normalizes_for_resize_and_composes_with_full_scroll() {
    let mut g = Grid::with_scrollback_capacity(1, 5, 10);
    for (row, ch) in ['A', 'B', 'C', 'D', 'E'].into_iter().enumerate() {
        fill_row(&mut g, row, ch);
    }

    g.scroll_region_up_with_blank(1, 3, 1, Cell::default());
    g.resize(1, 6);
    assert_eq!(
        (0..6).map(|row| row_chars(&g, row)).collect::<Vec<_>>(),
        vec!["A", "C", "D", "\0", "E", "\0"]
    );

    g.scroll_up(1);
    assert_eq!(
        (0..6).map(|row| row_chars(&g, row)).collect::<Vec<_>>(),
        vec!["C", "D", "\0", "E", "\0", "\0"]
    );
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'A');
}

#[test]
fn test_wide_row_hint_follows_rotations_and_full_clears() {
    let mut g = Grid::with_scrollback_capacity(4, 4, 0);
    assert!((0..4).all(|row| !g.row_may_have_wide(row)));

    assert!(g.set_wide(
        1,
        1,
        Cell {
            char: '界',
            ..Cell::default()
        }
    ));
    assert!(g.row_may_have_wide(1));
    assert!(!g.row_may_have_wide(0));
    assert!(!g.row_may_have_wide(2));

    g.scroll_up(1);
    assert!(g.row_may_have_wide(0));
    assert!(!g.row_may_have_wide(3));

    g.scroll_region_up_with_blank(0, 2, 1, Cell::default());
    assert!(!g.row_may_have_wide(0));
    assert!(!g.row_may_have_wide(2));

    assert!(g.set_wide(
        3,
        0,
        Cell {
            char: '界',
            ..Cell::default()
        }
    ));
    g.clear_line_full(3);
    assert!(!g.row_may_have_wide(3));
}

#[test]
fn test_full_scroll_moves_and_recycles_row_buffers() {
    let mut g = Grid::with_scrollback_capacity(4, 2, 1);
    g.set(
        0,
        0,
        Cell {
            char: 'A',
            ..Cell::default()
        },
    );
    g.set(
        1,
        0,
        Cell {
            char: 'B',
            ..Cell::default()
        },
    );

    let first_row_buffer = g.row_slice(0).as_ptr();
    g.scroll_up(1);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'A');
    assert_eq!(g.scrollback_line(0).unwrap().as_ptr(), first_row_buffer);

    g.scroll_up(1);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'B');
    assert_eq!(g.row_slice(1).as_ptr(), first_row_buffer);
    assert!(g.row_slice(1).iter().all(|cell| *cell == Cell::default()));
}

#[test]
fn test_recycled_scrollback_row_adopts_current_width() {
    let mut g = Grid::with_scrollback_capacity(2, 2, 1);
    g.set(
        0,
        0,
        Cell {
            char: 'A',
            ..Cell::default()
        },
    );
    g.scroll_up(1);

    g.resize(4, 2);
    g.scroll_up(1);

    assert_eq!(g.row_slice(1).len(), 4);
    assert!(g.row_slice(1).iter().all(|cell| *cell == Cell::default()));
}

#[test]
fn test_portrait_landscape_portrait_terminal_stale_suffix_regression() {
    use crate::terminal::Terminal;

    let mut term = Terminal::with_scrollback(53, 26, 1000);
    for i in 1..26 {
        term.feed(format!("line {}\r\n", i).as_bytes());
    }
    term.feed(b"prompt$ ");
    assert_eq!(term.cursor(), (25, 8));

    // Rotate to landscape (101 x 11)
    term.resize(101, 11);
    assert_eq!(term.cursor(), (10, 8));

    // Run command in landscape
    term.feed(b"stty size\r\n11 101\r\nRESTORED_11 101\r\nprompt$ ");
    assert_eq!(term.cursor(), (10, 8));

    // Rotate back to portrait (53 x 26)
    term.resize(53, 26);
    assert_eq!(term.cursor(), (25, 8));

    // Run shorter subsequent command in portrait
    term.feed(b"stty size\r\n26 53\r\nRESTORED_26 53\r\n");

    // Scan all rows to verify exact lines: no stale "01" suffix and no "stty sizesize"
    let mut found_exact_restored = false;
    for r in 0..term.active_grid().rows() {
        let line_chars = row_chars(term.active_grid(), r);
        let trimmed = line_chars.trim_end_matches('\0').trim();
        assert!(
            !trimmed.contains("RESTORED_26 5301"),
            "row {r} has corrupted stale suffix: {trimmed:?}"
        );
        assert!(
            !trimmed.contains("stty sizesize"),
            "row {r} has duplicated command text: {trimmed:?}"
        );
        if trimmed == "RESTORED_26 53" {
            found_exact_restored = true;
        }
    }
    assert!(
        found_exact_restored,
        "must contain the clean exact line RESTORED_26 53"
    );
}

#[test]
fn test_grid_portrait_landscape_portrait_cursor_and_reflow() {
    let mut g = Grid::with_scrollback_capacity(53, 26, 1000);
    for i in 0..25 {
        for (col, ch) in format!("item {}", i).chars().enumerate() {
            g.set(
                i,
                col,
                Cell {
                    char: ch,
                    ..Cell::default()
                },
            );
        }
        g.set_line_wrapped(i, false);
    }
    for (col, ch) in "prompt$ ".chars().enumerate() {
        g.set(
            25,
            col,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }

    // Resize to landscape: 101 x 11
    let pos1 = g.resize_with_cursor(101, 11, Some((25, 8)));
    assert_eq!(pos1, Some((10, 8)));
    assert_eq!(g.cols(), 101);
    assert_eq!(g.rows(), 11);

    // Resize back to portrait: 53 x 26
    let pos2 = g.resize_with_cursor(53, 26, Some((10, 8)));
    assert_eq!(pos2, Some((25, 8)));
    assert_eq!(g.cols(), 53);
    assert_eq!(g.rows(), 26);
    assert_eq!(&row_chars(&g, 25)[..8], "prompt$ ");
}
