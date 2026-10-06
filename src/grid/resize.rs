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
    /// Resize without reflow: each row is truncated or padded to the new
    /// width, rows are truncated/padded to the new height. Used when
    /// wraparound is off (rows can't be soft-wrapped continuations).
    pub fn resize_no_reflow(&mut self, new_cols: usize, new_rows: usize) {
        let new_cols = new_cols.max(1);
        let new_rows = new_rows.max(1);

        let old_cols = self.cols;
        let old_rows = self.rows;
        let min_rows = old_rows.min(new_rows);
        let min_cols = old_cols.min(new_cols);

        // Snapshot the retained rows in *logical* order before the physical
        // layout (and `row_offset`) is thrown away.
        let kept: Vec<(Vec<Cell>, bool, SemanticPrompt, RowOwner)> = (0..min_rows)
            .map(|r| {
                (
                    self.row_slice(r).to_vec(),
                    self.is_line_wrapped(r),
                    self.row_semantic_prompt(r),
                    self.row_owner(r),
                )
            })
            .collect();

        self.cols = new_cols;
        self.rows = new_rows;
        self.row_offset = 0;
        self.row_slots = (0..new_rows).collect();
        self.cells = vec![vec![Cell::default(); new_cols]; new_rows];
        self.line_wrapped = vec![false; new_rows];
        self.row_semantic = vec![SemanticPrompt::Unset; new_rows];
        self.row_owner = vec![RowOwner::Empty; new_rows];
        self.dirty = vec![true; new_rows];
        self.row_may_have_wide = vec![false; new_rows];

        for (r, (old_row, wrapped, semantic, owner)) in kept.into_iter().enumerate() {
            self.line_wrapped[r] = wrapped;
            self.row_semantic[r] = semantic;
            self.row_owner[r] = owner;

            self.cells[r][..min_cols].copy_from_slice(&old_row[..min_cols]);

            if new_cols < old_cols && min_cols > 0 {
                // The truncation would leave a wide cell whose spacer fell
                // off the right edge: blank the orphan.
                if !old_row[min_cols - 1].is_wide_spacer
                    && matches!(old_row.get(min_cols), Some(c) if c.is_wide_spacer)
                {
                    self.cells[r][min_cols - 1] = Cell::default();
                }
            }
            self.row_may_have_wide[r] = self.cells[r]
                .iter()
                .any(|cell| cell.is_wide_spacer || cell.is_wide_spacer_head);
        }
    }

    /// Resize the grid to `new_cols` x `new_rows`.
    pub fn resize(&mut self, new_cols: usize, new_rows: usize) {
        self.resize_with_cursor(new_cols, new_rows, None);
    }

    /// Resize while keeping the active cursor row and column meaningful across
    /// row adjustments and width reflow.
    pub(crate) fn resize_with_cursor(
        &mut self,
        new_cols: usize,
        new_rows: usize,
        cursor: Option<(usize, usize)>,
    ) -> Option<(usize, usize)> {
        self.resize_with_cursor_and_remaps(new_cols, new_rows, cursor)
            .0
    }

    pub(crate) fn resize_rows_only(
        &mut self,
        new_rows: usize,
        cursor: Option<(usize, usize)>,
    ) -> (usize, Option<(usize, usize)>) {
        use std::cmp::Ordering;
        if new_rows == self.rows {
            return (0, cursor);
        }
        self.normalize();
        match new_rows.cmp(&self.rows) {
            Ordering::Equal => (0, cursor),
            Ordering::Greater => {
                let extra = new_rows - self.rows;
                let cursor_row = cursor.map(|(row, _)| row.min(self.rows.saturating_sub(1)));
                let cursor_at_bottom = cursor_row
                    .map(|row| row >= self.rows.saturating_sub(1))
                    .unwrap_or(false);
                let restored_count = if cursor_at_bottom {
                    extra.min(self.scrollback.len())
                } else {
                    0
                };

                if restored_count > 0 {
                    let restore_from = self.scrollback.len() - restored_count;
                    let restored: Vec<ScrollbackRow> =
                        self.scrollback.drain(restore_from..).collect();

                    let old_cells = std::mem::take(&mut self.cells);
                    let old_wrapped = std::mem::take(&mut self.line_wrapped);
                    let old_semantic = std::mem::take(&mut self.row_semantic);
                    let old_owner = std::mem::take(&mut self.row_owner);
                    let old_dirty = std::mem::take(&mut self.dirty);
                    let old_wide = std::mem::take(&mut self.row_may_have_wide);

                    self.cells = Vec::with_capacity(new_rows);
                    self.line_wrapped = Vec::with_capacity(new_rows);
                    self.row_semantic = Vec::with_capacity(new_rows);
                    self.row_owner = Vec::with_capacity(new_rows);
                    self.dirty = Vec::with_capacity(new_rows);
                    self.row_may_have_wide = Vec::with_capacity(new_rows);

                    for mut history_row in restored {
                        let old_len = history_row.cells.len();
                        if old_len > self.cols
                            && self.cols > 0
                            && !history_row.cells[self.cols - 1].is_wide_spacer
                            && history_row.cells[self.cols].is_wide_spacer
                        {
                            history_row.cells[self.cols - 1] = Cell::default();
                        }
                        history_row.cells.resize(self.cols, Cell::default());
                        history_row.cells.truncate(self.cols);
                        let may_have_wide = history_row
                            .cells
                            .iter()
                            .any(|cell| cell.is_wide_spacer || cell.is_wide_spacer_head);
                        self.cells.push(history_row.cells);
                        self.line_wrapped.push(history_row.wrapped);
                        self.row_semantic.push(history_row.semantic);
                        self.row_owner.push(history_row.owner);
                        self.dirty.push(true);
                        self.row_may_have_wide.push(may_have_wide);
                    }

                    self.cells.extend(old_cells);
                    self.line_wrapped.extend(old_wrapped);
                    self.row_semantic.extend(old_semantic);
                    self.row_owner.extend(old_owner);
                    self.dirty.extend(old_dirty);
                    self.row_may_have_wide.extend(old_wide);
                }

                let blank_rows = extra - restored_count;
                self.cells
                    .extend((0..blank_rows).map(|_| vec![Cell::default(); self.cols]));
                self.line_wrapped
                    .extend(std::iter::repeat_n(false, blank_rows));
                self.row_semantic
                    .extend(std::iter::repeat_n(SemanticPrompt::Unset, blank_rows));
                self.row_owner
                    .extend(std::iter::repeat_n(RowOwner::Empty, blank_rows));
                self.dirty.extend(std::iter::repeat_n(true, blank_rows));
                self.row_may_have_wide
                    .extend(std::iter::repeat_n(false, blank_rows));
                self.rows = new_rows;
                self.row_slots = (0..new_rows).collect();
                if restored_count > 0 {
                    self.mark_all_dirty();
                }
                let new_cursor = cursor.map(|(r, c)| {
                    (
                        r.saturating_add(restored_count)
                            .min(new_rows.saturating_sub(1)),
                        c.min(self.cols.saturating_sub(1)),
                    )
                });
                (restored_count, new_cursor)
            }
            Ordering::Less => {
                let removed = self.rows - new_rows;

                let cursor_row = cursor.map(|(row, _)| row.min(self.rows.saturating_sub(1)));
                let mut trim_bottom = 0;
                while trim_bottom < removed {
                    let row = self.rows - trim_bottom - 1;
                    if cursor_row.is_some_and(|cursor| row <= cursor) {
                        break;
                    }
                    let has_text = self.row_slice(row).iter().any(|cell| cell.char != '\0');
                    let has_semantic_mark = self.row_semantic_prompt(row) != SemanticPrompt::Unset;
                    if has_text || has_semantic_mark {
                        break;
                    }
                    trim_bottom += 1;
                }

                if trim_bottom > 0 {
                    let kept = self.rows - trim_bottom;
                    self.cells.truncate(kept);
                    self.line_wrapped.truncate(kept);
                    self.row_semantic.truncate(kept);
                    self.row_owner.truncate(kept);
                    self.dirty.truncate(kept);
                    self.row_may_have_wide.truncate(kept);
                    self.rows = kept;
                    self.row_slots = (0..kept).collect();
                }

                let remove_top = removed - trim_bottom;
                for row in 0..remove_top {
                    let line: Vec<Cell> = self.row_slice(row).to_vec();
                    let wrapped = self.is_line_wrapped(row);
                    let owner = self.row_owner(row);
                    let semantic = self.row_semantic_prompt(row);
                    self.push_scrollback(line, wrapped, owner, semantic);
                }
                self.cells.drain(0..remove_top);
                self.line_wrapped.drain(0..remove_top);
                self.row_semantic.drain(0..remove_top);
                self.row_owner.drain(0..remove_top);
                self.dirty.drain(0..remove_top);
                self.row_may_have_wide.drain(0..remove_top);
                self.rows = new_rows;
                self.row_slots = (0..new_rows).collect();
                self.mark_all_dirty();

                let new_cursor = cursor.map(|(r, c)| {
                    (
                        r.saturating_sub(remove_top).min(new_rows.saturating_sub(1)),
                        c.min(self.cols.saturating_sub(1)),
                    )
                });
                (0, new_cursor)
            }
        }
    }
}
