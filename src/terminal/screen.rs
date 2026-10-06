/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{Cell, RowOwner, SemanticPrompt};
use crate::tabstops::TabStops;

use super::state::Terminal;
use super::types::{ScreenBuffer, SemanticContent};

impl Terminal {
    pub fn resize(&mut self, cols: usize, rows: usize) {
        if cols == 0 || rows == 0 {
            return;
        }
        let cols_changed = cols != self.active_grid().cols();
        let cursor_pos = (self.cursor.row, self.cursor.col);
        self.input_start = None;
        let (new_cursor, line_remaps) = if self.modes.autowrap {
            match self.active {
                ScreenBuffer::Primary => {
                    let (pos, remaps) =
                        self.primary
                            .resize_with_cursor_and_remaps(cols, rows, Some(cursor_pos));
                    self.alternate.resize_with_cursor(cols, rows, None);
                    (pos, remaps)
                }
                ScreenBuffer::Alternate => {
                    let (_, remaps) = self.primary.resize_with_cursor_and_remaps(cols, rows, None);
                    let pos = self
                        .alternate
                        .resize_with_cursor(cols, rows, Some(cursor_pos));
                    (pos, remaps)
                }
            }
        } else {
            self.primary.resize_no_reflow(cols, rows);
            self.alternate.resize_no_reflow(cols, rows);
            (
                Some((
                    self.cursor.row.min(rows.saturating_sub(1)),
                    self.cursor.col.min(cols.saturating_sub(1)),
                )),
                Vec::new(),
            )
        };
        if !line_remaps.is_empty() {
            self.commands.remap_prompt_lines(&line_remaps);
            let map: std::collections::HashMap<u64, u64> = line_remaps.into_iter().collect();
            if let Some(prompt) = self.last_prompt_line
                && let Some(&new_line) = map.get(&prompt)
            {
                self.last_prompt_line = Some(new_line);
            }
        }
        if cols_changed {
            self.tabstops = TabStops::new(cols);
        }
        self.scroll_left = 0;
        self.scroll_right = cols.saturating_sub(1);
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);
        if let Some((r, c)) = new_cursor {
            self.cursor.row = r.min(rows.saturating_sub(1));
            self.cursor.col = c.min(cols.saturating_sub(1));
        } else {
            self.cursor.row = self.cursor.row.min(rows.saturating_sub(1));
            self.cursor.col = self.cursor.col.min(cols.saturating_sub(1));
        }
        self.pending_wrap = false;
        if let Some(sel) = self.selection.as_mut() {
            let clamp = |(r, c): (usize, usize)| (r, c.min(cols.saturating_sub(1)));
            sel.anchor = clamp(sel.anchor);
            sel.active = clamp(sel.active);
        }
        self.viewport_offset = self
            .viewport_offset
            .min(self.active_grid().scrollback_len());
    }

    pub(crate) fn switch_screen(&mut self, to: ScreenBuffer) {
        if to != self.active {
            self.input_start = None;
        }
        self.active = to;
        self.viewport_offset = 0;
    }

    pub(crate) fn h_margins(&self) -> (usize, usize) {
        let cols = self.active_grid().cols();
        (
            self.scroll_left.min(cols.saturating_sub(1)),
            self.scroll_right.min(cols.saturating_sub(1)),
        )
    }

    pub(crate) fn h_margins_full(&self) -> bool {
        let (left, right) = self.h_margins();
        left == 0 && right + 1 == self.active_grid().cols()
    }

    pub(crate) fn bce_blank(&self) -> Cell {
        Cell {
            bg: self.cursor.bg,
            ..Cell::default()
        }
    }

    #[inline]
    pub(crate) fn dissolve_wide_pair_at(&mut self, row: usize, col: usize) {
        if !self.active_grid().row_may_have_wide(row) {
            return;
        }
        let (is_spacer, next_is_spacer) = {
            let grid = self.active_grid();
            (
                grid.get(row, col)
                    .map(|c| c.is_wide_spacer)
                    .unwrap_or(false),
                grid.get(row, col + 1)
                    .map(|c| c.is_wide_spacer)
                    .unwrap_or(false),
            )
        };
        if is_spacer {
            if col > 0 {
                self.active_grid_mut().set(row, col - 1, Cell::default());
            }
        } else if next_is_spacer {
            self.active_grid_mut().set(row, col + 1, Cell::default());
        }
    }

    pub(crate) fn line_feed(&mut self) {
        self.pending_wrap = false;
        let rows = self.active_grid().rows();
        let bottom = self.scroll_bottom.min(rows.saturating_sub(1));
        let mark_continuation = matches!(
            self.semantic_content,
            SemanticContent::Prompt | SemanticContent::Input
        );
        if self.active == ScreenBuffer::Primary && self.primary.pen_owner().is_some() {
            let row = self.cursor.row;
            if self.primary.row_owner(row) == RowOwner::Empty {
                self.primary.touch_row_owner(row);
            }
        }
        if self.cursor.row == bottom {
            let (hl, hr) = self.h_margins();
            if self.cursor.col >= hl && self.cursor.col <= hr {
                self.scroll_region_up(1);
            }
        } else if self.cursor.row + 1 < rows {
            self.cursor.row += 1;
        }
        if mark_continuation {
            let row = self.cursor.row;
            self.active_grid_mut()
                .set_row_semantic_prompt(row, SemanticPrompt::PromptContinuation);
        }
    }

    pub(crate) fn reverse_index(&mut self) {
        self.pending_wrap = false;
        let top = self.scroll_top;
        if self.cursor.row == top {
            let (hl, hr) = self.h_margins();
            if self.cursor.col >= hl && self.cursor.col <= hr {
                self.scroll_region_down(1);
            }
        } else if self.cursor.row > 0 {
            self.cursor.row -= 1;
        }
    }

    pub(crate) fn scroll_region_up(&mut self, n: usize) {
        let scrollback_before = self.active_grid().scrollback_len();
        self.scroll_region_up_inner(n);
        self.keep_viewport_anchored(scrollback_before);
    }

    pub(crate) fn scroll_region_up_inner(&mut self, n: usize) {
        if n == 0 {
            return;
        }
        let rows = self.active_grid().rows();
        let top = self.scroll_top;
        let bottom = self.scroll_bottom.min(rows.saturating_sub(1));
        if top > bottom {
            return;
        }
        let region_height = bottom - top + 1;
        let n = n.min(region_height);

        let (left, right) = self.h_margins();
        if top == 0 && bottom == rows.saturating_sub(1) && self.h_margins_full() {
            let blank = self.bce_blank();
            self.active_grid_mut().scroll_up_with_blank(n, blank);
            return;
        }
        self.input_start = None;

        let full_width = self.h_margins_full();
        let prompt_shift_below = if top == 0
            && full_width
            && bottom + 1 < rows
            && self.active == ScreenBuffer::Primary
        {
            let sb = self.primary.scrollback_len() as u64;
            let first = self.primary.first_retained_line();
            Some((first + sb + (bottom + 1) as u64)..=(first + sb + (rows - 1) as u64))
        } else {
            None
        };

        if top == 0 && full_width {
            self.active_grid_mut().stash_top_rows(n);
        }
        if full_width {
            let blank = self.bce_blank();
            self.active_grid_mut()
                .scroll_region_up_with_blank(top, bottom, n, blank);
            if let Some(shift_range) = prompt_shift_below {
                self.remap_prompts_below_scroll_region(shift_range, n as u64);
            } else if top > 0 && self.active == ScreenBuffer::Primary {
                self.remap_screen_rows_up(top, bottom, n);
            }
            return;
        }
        if n < region_height {
            for row in top..=(bottom - n) {
                for col in left..=right {
                    let cell = self
                        .active_grid()
                        .get(row + n, col)
                        .copied()
                        .unwrap_or_default();
                    self.active_grid_mut().set(row, col, cell);
                }
            }
        }
        let blank = self.bce_blank();
        for row in (bottom + 1 - n)..=bottom {
            self.active_grid_mut()
                .fill_cells(row, left, right + 1, blank);
        }
        for row in top..=bottom {
            self.fix_wide_orphans(row);
        }
        self.fix_spacer_heads();
    }

    pub(crate) fn scroll_region_down(&mut self, n: usize) {
        if n == 0 {
            return;
        }
        let rows = self.active_grid().rows();
        let top = self.scroll_top;
        let bottom = self.scroll_bottom.min(rows.saturating_sub(1));
        if top > bottom {
            return;
        }
        let region_height = bottom - top + 1;
        let n = n.min(region_height);
        let (left, right) = self.h_margins();
        let full_width = self.h_margins_full();
        self.input_start = None;

        if n < region_height {
            for row in (top + n..=bottom).rev() {
                for col in left..=right {
                    let cell = self
                        .active_grid()
                        .get(row - n, col)
                        .copied()
                        .unwrap_or_default();
                    self.active_grid_mut().set(row, col, cell);
                }
                if full_width {
                    let wrapped = self.active_grid().is_line_wrapped(row - n);
                    self.active_grid_mut().set_line_wrapped(row, wrapped);
                    let owner = self.active_grid().row_owner(row - n);
                    self.active_grid_mut().set_row_owner(row, owner);
                    let prompt = self.active_grid().row_semantic_prompt(row - n);
                    self.active_grid_mut().set_row_semantic_prompt(row, prompt);
                }
            }
        }
        let blank = self.bce_blank();
        for row in top..(top + n) {
            self.active_grid_mut()
                .fill_cells(row, left, right + 1, blank);
            if full_width {
                self.active_grid_mut().set_line_wrapped(row, false);
                self.active_grid_mut().set_row_owner(row, RowOwner::Empty);
                self.active_grid_mut()
                    .set_row_semantic_prompt(row, SemanticPrompt::Unset);
            }
        }
        if !full_width {
            for row in top..=bottom {
                self.fix_wide_orphans(row);
            }
        }
        if full_width && self.active == ScreenBuffer::Primary {
            self.remap_screen_rows_down(top, bottom, n);
        }
        self.fix_spacer_heads();
    }
}
