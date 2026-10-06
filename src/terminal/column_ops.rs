/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::Cell;

use super::state::Terminal;

impl Terminal {
    /// DECIC: insert `n` blank columns at the cursor, shifting columns
    /// right within the margin box. No-op when the cursor is outside it.
    pub(crate) fn insert_columns(&mut self, n: usize) {
        let (hl, hr) = self.h_margins();
        let (top, bottom) = (
            self.scroll_top,
            self.scroll_bottom
                .min(self.active_grid().rows().saturating_sub(1)),
        );
        if self.cursor.col < hl
            || self.cursor.col > hr
            || self.cursor.row < top
            || self.cursor.row > bottom
        {
            return;
        }
        self.pending_wrap = false;
        let start = self.cursor.col;
        let n = n.min(hr + 1 - start);
        let blank = self.bce_blank();
        for row in top..=bottom {
            for col in (start..=hr.saturating_sub(n)).rev() {
                let cell = self
                    .active_grid()
                    .get(row, col)
                    .copied()
                    .unwrap_or_default();
                self.active_grid_mut().set(row, col + n, cell);
            }
            for col in start..(start + n).min(hr + 1) {
                self.active_grid_mut().set(row, col, blank);
            }
            self.fix_wide_orphans(row);
        }
    }

    /// DECDC: delete `n` columns at the cursor, shifting columns left
    /// within the margin box. No-op when the cursor is outside it.
    pub(crate) fn delete_columns(&mut self, n: usize) {
        let (hl, hr) = self.h_margins();
        let (top, bottom) = (
            self.scroll_top,
            self.scroll_bottom
                .min(self.active_grid().rows().saturating_sub(1)),
        );
        if self.cursor.col < hl
            || self.cursor.col > hr
            || self.cursor.row < top
            || self.cursor.row > bottom
        {
            return;
        }
        self.pending_wrap = false;
        let start = self.cursor.col;
        let n = n.min(hr + 1 - start);
        let blank = self.bce_blank();
        for row in top..=bottom {
            for col in start..=hr {
                let cell = if col + n <= hr {
                    self.active_grid()
                        .get(row, col + n)
                        .copied()
                        .unwrap_or_default()
                } else {
                    blank
                };
                self.active_grid_mut().set(row, col, cell);
            }
            self.fix_wide_orphans(row);
        }
    }

    /// DECBI: back-index -- cursor left, or scroll the box right by one
    /// column when already on the left margin.
    pub(crate) fn back_index(&mut self) {
        self.pending_wrap = false;
        let (hl, _) = self.h_margins();
        if self.cursor.col == hl {
            let saved = self.cursor.col;
            self.cursor.col = hl;
            self.insert_columns(1);
            self.cursor.col = saved;
        } else {
            self.cursor.col = self.cursor.col.saturating_sub(1);
        }
    }

    /// DECFI: forward-index -- cursor right, or scroll the box left by one
    /// column when already on the right margin.
    pub(crate) fn forward_index(&mut self) {
        self.pending_wrap = false;
        let (hl, hr) = self.h_margins();
        if self.cursor.col == hr {
            let saved = self.cursor.col;
            self.cursor.col = hl;
            self.delete_columns(1);
            self.cursor.col = saved;
        } else {
            self.cursor.col =
                (self.cursor.col + 1).min(self.active_grid().cols().saturating_sub(1));
        }
    }

    /// A spacer head is only meaningful while the row below still starts
    /// with the wide glyph it made room for; otherwise it degrades into an
    /// ordinary blank cell (upstream converts it the same way).
    pub(crate) fn fix_spacer_heads(&mut self) {
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        if cols == 0 {
            return;
        }
        for row in 0..rows {
            let has_head = self
                .active_grid()
                .get(row, cols - 1)
                .map(|c| c.is_wide_spacer_head)
                .unwrap_or(false);
            if !has_head {
                continue;
            }
            let grid = self.active_grid();
            let next_starts_wide = row + 1 < rows
                && grid
                    .get(row + 1, 0)
                    .is_some_and(|c| !c.is_wide_spacer && grid.cell_is_wide(c));
            if !next_starts_wide && let Some(cell) = self.active_grid_mut().get_mut(row, cols - 1) {
                cell.is_wide_spacer_head = false;
            }
        }
    }

    /// Repair wide-pair invariants on `row` after a horizontal shift: a
    /// wide head (width >= 2 char) must be followed by its spacer, and a
    /// spacer must follow a wide head -- any orphaned half becomes a blank.
    pub(crate) fn fix_wide_orphans(&mut self, row: usize) {
        let cols = self.active_grid().cols();
        for col in 0..cols {
            let (is_wide, is_spacer) = {
                let grid = self.active_grid();
                let Some(cell) = grid.get(row, col) else {
                    continue;
                };
                (grid.cell_is_wide(cell), cell.is_wide_spacer)
            };
            if is_spacer {
                let grid = self.active_grid();
                let prev_is_head = col > 0
                    && grid
                        .get(row, col - 1)
                        .is_some_and(|p| !p.is_wide_spacer && grid.cell_is_wide(p));
                if !prev_is_head {
                    self.active_grid_mut().set(row, col, Cell::default());
                }
            } else if is_wide {
                let next_is_spacer = col + 1 < cols
                    && self
                        .active_grid()
                        .get(row, col + 1)
                        .is_some_and(|nx| nx.is_wide_spacer);
                if !next_is_spacer {
                    self.active_grid_mut().set(row, col, Cell::default());
                }
            }
        }
    }

    pub(crate) fn insert_chars(&mut self, n: usize) {
        let cols = self.active_grid().cols();
        if cols == 0 || n == 0 {
            return;
        }
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        let row = self.cursor.row;
        let start = self.cursor.col.min(cols - 1);
        self.dissolve_wide_pair_at(row, start);
        let end = hr + 1;
        let n = n.min(end - start);
        if n == 0 {
            return;
        }
        let shift_count = end - start - n;
        if shift_count > 0 {
            for col in (start..start + shift_count).rev() {
                let cell = self
                    .active_grid()
                    .get(row, col)
                    .copied()
                    .unwrap_or_default();
                self.active_grid_mut().set(row, col + n, cell);
            }
        }
        let blank = self.bce_blank();
        for col in start..start + n {
            self.active_grid_mut().set(row, col, blank);
        }
        self.fix_wide_orphans(row);
    }

    pub(crate) fn delete_chars(&mut self, n: usize) {
        let cols = self.active_grid().cols();
        if cols == 0 || n == 0 {
            return;
        }
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        let row = self.cursor.row;
        let start = self.cursor.col.min(cols - 1);
        self.dissolve_wide_pair_at(row, start);
        let end = hr + 1;
        let n = n.min(end - start);
        if n == 0 {
            return;
        }
        let shift_count = end - start - n;
        for i in 0..shift_count {
            let col = start + i;
            let cell = self
                .active_grid()
                .get(row, col + n)
                .copied()
                .unwrap_or_default();
            self.active_grid_mut().set(row, col, cell);
        }
        let blank = self.bce_blank();
        for col in (start + shift_count)..end {
            self.active_grid_mut().set(row, col, blank);
        }
        self.fix_wide_orphans(row);
    }
}
