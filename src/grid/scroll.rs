/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::{Cell, Grid, RowOwner, ScrollbackRow, SemanticPrompt};

impl Grid {
    /// Scroll the visible grid up by `n` lines: the top `n` rows are pushed
    /// into scrollback (oldest-first push order preserved), remaining rows
    /// shift up, and `n` new blank rows appear at the bottom.
    pub fn scroll_up(&mut self, n: usize) {
        self.scroll_up_with_blank(n, Cell::default());
    }

    /// [`Self::scroll_up`] with a caller-supplied template for the rows
    /// scrolled in at the bottom.
    pub fn scroll_up_with_blank(&mut self, n: usize, blank: Cell) {
        if n == 0 {
            return;
        }
        self.mark_all_dirty();
        let n = n.min(self.rows);

        // Move the archived row buffers into history. Once history is full,
        // its evicted row becomes the blank replacement, so steady-state
        // scrolling copies no cell data at all.
        for row in 0..n {
            let wrapped = self.is_line_wrapped(row);
            self.archive_scrolled_row(row, wrapped, blank);
            let p = self.phys(row);
            self.line_wrapped[p] = false;
            self.row_semantic[p] = SemanticPrompt::Unset;
            self.row_owner[p] = RowOwner::Empty;
            self.row_may_have_wide[p] = blank.is_wide_spacer || blank.is_wide_spacer_head;
        }

        // Rotate the logical origin. When `n == self.rows` every row was
        // just blanked, so the offset legitimately stays put.
        self.row_offset = self.slot(n % self.rows);
    }

    /// Scroll a full-width visible row region `[top, bottom]` upward.
    pub fn scroll_region_up_with_blank(
        &mut self,
        top: usize,
        bottom: usize,
        n: usize,
        blank: Cell,
    ) {
        if n == 0 || top >= self.rows || bottom >= self.rows || top > bottom {
            return;
        }

        let n = n.min(bottom - top + 1);
        for row in top..=bottom {
            let physical = self.phys(row);
            self.dirty[physical] = true;
        }

        for _ in 0..n {
            let recycled = self.phys(top);
            self.cells[recycled].fill(blank);
            self.line_wrapped[recycled] = false;
            self.row_semantic[recycled] = SemanticPrompt::Unset;
            self.row_owner[recycled] = RowOwner::Empty;
            self.row_may_have_wide[recycled] = blank.is_wide_spacer || blank.is_wide_spacer_head;

            for row in top..bottom {
                let destination = self.slot(row);
                let source = self.slot(row + 1);
                self.row_slots[destination] = self.row_slots[source];
            }
            let bottom_slot = self.slot(bottom);
            self.row_slots[bottom_slot] = recycled;
        }
    }

    /// Copy rows `0..n` into scrollback without shifting anything.
    pub fn stash_top_rows(&mut self, n: usize) {
        for row in 0..n.min(self.rows) {
            let wrapped = self.is_line_wrapped(row);
            self.push_scrollback_row(row, wrapped);
        }
    }

    /// Copy one visible row into scrollback, reusing the evicted row's cell
    /// allocation once the ring is full.
    pub(crate) fn push_scrollback_row(&mut self, row: usize, wrapped: bool) {
        if self.scrollback_capacity == 0 {
            self.history_evicted += 1;
            return;
        }

        let mut entry = if self.scrollback.len() >= self.scrollback_capacity {
            self.history_evicted += 1;
            self.scrollback.pop_front().unwrap()
        } else {
            ScrollbackRow {
                cells: Vec::with_capacity(self.cols),
                wrapped,
                owner: RowOwner::Empty,
                semantic: SemanticPrompt::Unset,
            }
        };

        let physical = self.phys(row);
        entry.cells.clear();
        entry.cells.extend_from_slice(&self.cells[physical]);
        entry.wrapped = wrapped;
        entry.owner = self.row_owner[physical];
        entry.semantic = self.row_semantic[physical];
        self.scrollback.push_back(entry);
    }

    /// Move a row into scrollback and install a recycled, blank row buffer in its place.
    pub(crate) fn archive_scrolled_row(&mut self, row: usize, wrapped: bool, blank: Cell) {
        let physical = self.phys(row);
        if self.scrollback_capacity == 0 {
            self.history_evicted += 1;
            self.cells[physical].fill(blank);
            return;
        }

        let mut replacement = if self.scrollback.len() >= self.scrollback_capacity {
            self.history_evicted += 1;
            self.scrollback.pop_front().unwrap().cells
        } else {
            vec![blank; self.cols]
        };
        replacement.resize(self.cols, blank);
        replacement.fill(blank);

        let archived = std::mem::replace(&mut self.cells[physical], replacement);
        self.scrollback.push_back(ScrollbackRow {
            cells: archived,
            wrapped,
            owner: self.row_owner[physical],
            semantic: self.row_semantic[physical],
        });
    }

    pub(crate) fn push_scrollback(
        &mut self,
        line: Vec<Cell>,
        wrapped: bool,
        owner: RowOwner,
        semantic: SemanticPrompt,
    ) {
        if self.scrollback_capacity == 0 {
            self.history_evicted += 1;
            return;
        }
        if self.scrollback.len() >= self.scrollback_capacity {
            self.scrollback.pop_front();
            self.history_evicted += 1;
        }
        self.scrollback.push_back(ScrollbackRow {
            cells: line,
            wrapped,
            owner,
            semantic,
        });
    }

    /// Total number of scrollback lines that have been evicted (dropped)
    /// over the lifetime of this grid.
    #[inline]
    pub fn history_evicted(&self) -> usize {
        self.history_evicted
    }

    /// Number of lines currently retained in scrollback.
    pub fn scrollback_len(&self) -> usize {
        self.scrollback.len()
    }

    /// Fetch a scrollback line by distance from the bottom of scrollback.
    pub fn scrollback_line(&self, index_from_bottom: usize) -> Option<&[Cell]> {
        let len = self.scrollback.len();
        if index_from_bottom >= len {
            return None;
        }
        let idx = len - 1 - index_from_bottom;
        self.scrollback.get(idx).map(|row| row.cells.as_slice())
    }

    /// Fetch whether a scrollback line was a soft-wrapped continuation row.
    pub fn scrollback_line_wrapped(&self, index_from_bottom: usize) -> bool {
        let len = self.scrollback.len();
        if index_from_bottom >= len {
            return false;
        }
        let idx = len - 1 - index_from_bottom;
        self.scrollback
            .get(idx)
            .map(|row| row.wrapped)
            .unwrap_or(false)
    }

    /// Iterate scrollback lines oldest-first.
    pub fn scrollback_iter(&self) -> impl DoubleEndedIterator<Item = &[Cell]> {
        self.scrollback.iter().map(|row| row.cells.as_slice())
    }

    pub fn scrollback_capacity(&self) -> usize {
        self.scrollback_capacity
    }

    /// Changes how many lines of history the scrollback keeps.
    pub fn set_scrollback_capacity(&mut self, capacity: usize) {
        while self.scrollback.len() > capacity {
            self.scrollback.pop_front();
            self.history_evicted += 1;
        }
        self.scrollback_capacity = capacity;
    }

    /// The scrollback, borrowed oldest-first, with each row's wrap flag intact.
    pub fn scrollback_rows(&self) -> impl ExactSizeIterator<Item = &ScrollbackRow> {
        self.scrollback.iter()
    }
}
