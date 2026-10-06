/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::{Cell, Grid, RowOwner, SemanticPrompt};

impl Grid {
    pub fn mark_dirty(&mut self, row: usize) {
        if row >= self.rows {
            return;
        }
        let p = self.phys(row);
        self.dirty[p] = true;
    }

    /// Mark every row as needing a redraw.
    pub fn mark_all_dirty(&mut self) {
        for slot in self.dirty.iter_mut() {
            *slot = true;
        }
    }

    /// Whether `row` changed since the last `clear_dirty`.
    pub fn is_dirty(&self, row: usize) -> bool {
        if row >= self.rows {
            return false;
        }
        self.dirty[self.phys(row)]
    }

    /// Whether ANY row is currently dirty, without clearing anything.
    pub fn has_dirty(&self) -> bool {
        self.dirty.iter().any(|&dirty| dirty)
    }

    /// Clear every row's damage flag (the host redrew).
    pub fn clear_dirty(&mut self) {
        for slot in self.dirty.iter_mut() {
            *slot = false;
        }
    }

    /// The OSC 133 semantic-prompt mark for `row`.
    pub fn row_semantic_prompt(&self, row: usize) -> SemanticPrompt {
        if row >= self.rows {
            return SemanticPrompt::default();
        }
        self.row_semantic[self.phys(row)]
    }

    /// Total retained rows across scrollback and live grid.
    #[inline]
    pub fn retained_rows(&self) -> usize {
        self.scrollback.len() + self.rows
    }

    /// Owner of retained line `index` (0 = oldest retained line).
    pub fn retained_owner(&self, index: usize) -> RowOwner {
        let sb = self.scrollback.len();
        if index < sb {
            self.scrollback[index].owner
        } else if index - sb < self.rows {
            self.row_owner(index - sb)
        } else {
            RowOwner::Empty
        }
    }

    /// The OSC 133 semantic-prompt mark for retained line `index` (0 = oldest in scrollback).
    pub fn retained_semantic_prompt(&self, index: usize) -> SemanticPrompt {
        let sb = self.scrollback.len();
        if index < sb {
            self.scrollback[index].semantic
        } else if index - sb < self.rows {
            self.row_semantic_prompt(index - sb)
        } else {
            SemanticPrompt::Unset
        }
    }

    /// Set the OSC 133 semantic-prompt mark for `row`.
    pub fn set_row_semantic_prompt(&mut self, row: usize, mark: SemanticPrompt) {
        if row >= self.rows {
            return;
        }
        let p = self.phys(row);
        self.row_semantic[p] = mark;
    }

    /// Which command's output `row` holds.
    pub fn row_owner(&self, row: usize) -> RowOwner {
        if row >= self.rows {
            return RowOwner::Empty;
        }
        self.row_owner[self.phys(row)]
    }

    /// Overwrite `row`'s owner (checkpoint import).
    pub(crate) fn set_row_owner(&mut self, row: usize, owner: RowOwner) {
        if row >= self.rows {
            return;
        }
        let p = self.phys(row);
        self.row_owner[p] = owner;
    }

    /// The command whose output writes claim rows for, if any.
    pub fn pen_owner(&self) -> Option<u64> {
        self.pen_owner
    }

    /// Start (`Some`) or stop (`None`) claiming written rows for a command.
    pub fn set_pen_owner(&mut self, pen: Option<u64>) {
        self.pen_owner = pen;
    }

    /// Record a write into physical row `p`.
    #[inline]
    pub(crate) fn touch_owner(&mut self, p: usize) {
        let owner = &mut self.row_owner[p];
        *owner = owner.after_write(self.pen_owner);
    }

    /// Record a write or row advancement into logical row `row`.
    #[inline]
    pub fn touch_row_owner(&mut self, row: usize) {
        if row < self.rows {
            let p = self.phys(row);
            self.touch_owner(p);
        }
    }

    /// Owner of the scrollback line at `index` (oldest-first).
    pub fn scrollback_owner(&self, index: usize) -> RowOwner {
        self.scrollback
            .get(index)
            .map(|r| r.owner)
            .unwrap_or_default()
    }

    /// Overwrite the owner of the scrollback line at `index` (oldest-first).
    pub(crate) fn set_scrollback_owner(&mut self, index: usize, owner: RowOwner) {
        if let Some(r) = self.scrollback.get_mut(index) {
            r.owner = owner;
        }
    }

    /// Whether `row` is a soft-wrapped continuation of the row above it.
    pub fn is_line_wrapped(&self, row: usize) -> bool {
        if row >= self.rows {
            return false;
        }
        self.line_wrapped[self.phys(row)]
    }

    /// Mark whether `row` is a soft-wrapped continuation of the row above it.
    pub fn set_line_wrapped(&mut self, row: usize, wrapped: bool) {
        if row >= self.rows {
            return;
        }
        let p = self.phys(row);
        self.line_wrapped[p] = wrapped;
    }

    pub(crate) fn row_slice(&self, row: usize) -> &[Cell] {
        &self.cells[self.phys(row)]
    }

    pub(crate) fn row_slice_mut(&mut self, row: usize) -> &mut [Cell] {
        let physical = self.phys(row);
        &mut self.cells[physical]
    }

    /// The grid's rows, borrowed in display order.
    pub fn row_cells(&self, row: usize) -> &[Cell] {
        self.row_slice(row)
    }

    /// Clear the entire visible grid to blank cells (does not touch scrollback).
    pub fn clear_all(&mut self) {
        for row in self.cells.iter_mut() {
            row.fill(Cell::default());
        }
        for w in self.line_wrapped.iter_mut() {
            *w = false;
        }
        self.row_owner.fill(RowOwner::Empty);
        self.row_may_have_wide.fill(false);
    }

    /// Blank `[start, end)` on `row`, widening the range so that a
    /// double-width pair is never half-cleared.
    pub(crate) fn clear_range(&mut self, row: usize, start: usize, end: usize) {
        self.fill_cells(row, start, end, Cell::default());
    }

    /// Fill `[start, end)` on `row` with `blank`, widening the range so a
    /// double-width pair is never half-overwritten.
    pub fn fill_cells(&mut self, row: usize, start: usize, end: usize, blank: Cell) {
        self.fill_cells_respecting(row, start, end, blank, false);
    }

    /// [`Self::fill_cells`], optionally skipping cells whose `protected`
    /// flag is set (DECSCA/SPA selective-erase semantics).
    pub fn fill_cells_respecting(
        &mut self,
        row: usize,
        start: usize,
        end: usize,
        blank: Cell,
        respect_protected: bool,
    ) {
        self.mark_dirty(row);
        if row >= self.rows {
            return;
        }
        let cols = self.cols;
        let start = start.min(cols);
        let end = end.min(cols);
        if start >= end {
            return;
        }
        let row_cells = self.row_slice_mut(row);
        let start = if start > 0 && row_cells[start].is_wide_spacer {
            start - 1
        } else {
            start
        };
        let end = if end < cols && row_cells[end].is_wide_spacer {
            end + 1
        } else {
            end
        };
        let mut kept = false;
        for c in start..end {
            if respect_protected && row_cells[c].protected {
                kept = true;
                continue;
            }
            row_cells[c] = blank;
        }
        let physical = self.phys(row);
        if start == 0 && end == cols && !kept {
            // The whole row is blank again, whoever wrote it.
            self.row_owner[physical] = RowOwner::Empty;
        } else {
            self.touch_owner(physical);
        }
        if blank.is_wide_spacer || blank.is_wide_spacer_head {
            self.row_may_have_wide[physical] = true;
        }
    }

    /// Clear cells `[from_col, cols)` on `row`.
    pub fn clear_line(&mut self, row: usize, from_col: usize) {
        if row >= self.rows {
            return;
        }
        self.clear_range(row, from_col, self.cols);
    }

    /// Clear cells `[0, to_col]` (inclusive) on `row`.
    pub fn clear_line_to(&mut self, row: usize, to_col: usize) {
        if row >= self.rows {
            return;
        }
        self.clear_range(row, 0, to_col.saturating_add(1));
    }

    /// Clear the entire row. Covers whole pairs by construction.
    pub fn clear_line_full(&mut self, row: usize) {
        if row >= self.rows {
            return;
        }
        let row_cells = self.row_slice_mut(row);
        for c in row_cells.iter_mut() {
            *c = Cell::default();
        }
        let physical = self.phys(row);
        self.row_may_have_wide[physical] = false;
        self.row_owner[physical] = RowOwner::Empty;
        self.set_line_wrapped(row, false);
    }
}
