/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{
    Cell, MAX_EXTRA_BYTES, always_breaks, continues_cluster, unicode_cluster_is_wide,
};
use unicode_normalization::char::compose;
use unicode_width::UnicodeWidthChar;

use super::state::Terminal;

impl Terminal {
    pub(crate) fn join_previous_cluster(&mut self, c: char) -> bool {
        let plain = always_breaks(c);
        let zero_width = !plain && UnicodeWidthChar::width(c) == Some(0);
        let unicode = self.modes.grapheme_cluster;
        if !zero_width && !unicode {
            return false;
        }
        let row = self.cursor.row;
        let previous = if self.pending_wrap {
            Some(self.cursor.col)
        } else {
            self.cursor.col.checked_sub(1)
        };
        let grid = self.active_grid();
        let target = previous.and_then(|mut col| {
            if col > 0 && grid.get(row, col).is_some_and(|cell| cell.is_wide_spacer) {
                col -= 1;
            }
            let cell = *grid.get(row, col)?;
            let has_text = cell.char != '\0' && !cell.is_wide_spacer && !cell.is_wide_spacer_head;
            has_text.then_some((col, cell))
        });
        let Some((col, mut cell)) = target else {
            return zero_width;
        };
        let extra = grid.grapheme(&cell);
        if !continues_cluster(cell.char, extra, c) {
            return zero_width;
        }
        if extra.is_empty()
            && let Some(composed) = compose(cell.char, c)
        {
            cell.char = composed;
            self.active_grid_mut().set(row, col, cell);
            return true;
        }
        if extra.len() + c.len_utf8() > MAX_EXTRA_BYTES {
            return true;
        }
        let mut joined = String::with_capacity(extra.len() + c.len_utf8());
        joined.push_str(extra);
        joined.push(c);
        let was_wide = grid.cell_is_wide(&cell);
        let wide = if unicode {
            unicode_cluster_is_wide(cell.char, &joined)
        } else {
            was_wide
        };
        let id = self.active_grid_mut().intern_grapheme(&joined, wide);
        if id == 0 {
            return true;
        }
        cell.grapheme = id;
        match (was_wide, wide) {
            (false, true) => self.widen_cluster(row, col, cell),
            (true, false) => self.narrow_cluster(row, col, cell),
            _ => self.active_grid_mut().set(row, col, cell),
        }
        true
    }

    pub(crate) fn widen_cluster(&mut self, row: usize, col: usize, cell: Cell) {
        let cols = self.active_grid().cols();
        let (left, right) = self.h_margins();
        let right_bound = if col <= right { right } else { cols - 1 };
        let (mut row, mut col) = (row, col);
        if col >= right_bound {
            if !self.modes.autowrap || right_bound < left + 1 {
                return;
            }
            let leftover = if right_bound + 1 == cols {
                Cell {
                    char: ' ',
                    is_wide_spacer_head: true,
                    bg: cell.bg,
                    hyperlink: cell.hyperlink,
                    protected: cell.protected,
                    ..Cell::default()
                }
            } else {
                self.bce_blank()
            };
            self.active_grid_mut().set(row, col, leftover);
            self.cursor.col = left;
            self.line_feed();
            row = self.cursor.row;
            col = left;
            if right_bound + 1 == cols {
                self.active_grid_mut().set_line_wrapped(row, true);
            }
        }
        self.dissolve_wide_pair_at(row, col);
        self.dissolve_wide_pair_at(row, col + 1);
        self.active_grid_mut().set_wide(row, col, cell);
        if col + 1 >= right_bound {
            self.cursor.col = right_bound;
            self.pending_wrap = self.modes.autowrap;
        } else {
            self.cursor.col = col + 2;
            self.pending_wrap = false;
        }
    }

    pub(crate) fn narrow_cluster(&mut self, row: usize, col: usize, cell: Cell) {
        let spacer = self.active_grid().get(row, col + 1).copied();
        self.active_grid_mut().set(row, col, cell);
        if let Some(spacer) = spacer.filter(|spacer| spacer.is_wide_spacer) {
            let freed = Cell {
                char: '\0',
                is_wide_spacer: false,
                ..spacer
            };
            self.active_grid_mut().set(row, col + 1, freed);
        }
        if self.pending_wrap {
            self.pending_wrap = false;
        } else {
            self.cursor.col = self.cursor.col.saturating_sub(1);
        }
    }
}
