/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

mod basic;
mod cursor_grapheme;
mod reflow;
mod region;
mod resize;
mod scroll;

use crate::grid::*;

pub(crate) fn fill_row(g: &mut Grid, row: usize, ch: char) {
    for col in 0..g.cols() {
        g.set(
            row,
            col,
            Cell {
                char: ch,
                ..Cell::default()
            },
        );
    }
}

pub(crate) fn row_chars(g: &Grid, row: usize) -> String {
    (0..g.cols()).map(|c| g.get(row, c).unwrap().char).collect()
}

pub(crate) fn wide(ch: char) -> Cell {
    Cell {
        char: ch,
        fg: Color::Indexed(3),
        bg: Color::Rgb(1, 2, 3),
        attrs: CellAttrs::BOLD,
        hyperlink: Some(7),
        ..Cell::default()
    }
}

pub(crate) fn assert_no_orphans(line: &[Cell]) {
    for (i, cell) in line.iter().enumerate() {
        if cell.is_wide_spacer {
            assert!(i > 0, "spacer at column 0 has no wide half");
            assert!(
                !line[i - 1].is_wide_spacer,
                "spacer at column {i} follows another spacer"
            );
        }
    }
}
