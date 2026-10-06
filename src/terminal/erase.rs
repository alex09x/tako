/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::ops::RangeInclusive;

use crate::grid::{RowOwner, SemanticPrompt};

use super::state::Terminal;
use super::types::{ProtectedMode, ScreenBuffer};

impl Terminal {
    pub(crate) fn erase_in_display(&mut self, mode: u16) {
        let respect = self.protected_mode == ProtectedMode::Iso;
        self.erase_in_display_protected(mode, respect);
    }

    pub(crate) fn erase_in_display_protected(&mut self, mode: u16, respect: bool) {
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        let blank = self.bce_blank();
        match mode {
            0 => {
                let row = self.cursor.row;
                let col = self.cursor.col;
                let here = self.cursor_absolute_line();
                if self.input_start.is_some_and(|(line, _)| line > here) {
                    self.input_start = None;
                }
                self.active_grid_mut()
                    .fill_cells_respecting(row, col, cols, blank, respect);
                for r in (row + 1)..rows {
                    self.active_grid_mut()
                        .fill_cells_respecting(r, 0, cols, blank, respect);
                    self.active_grid_mut().set_line_wrapped(r, false);
                }
            }
            1 => {
                let row = self.cursor.row;
                let col = self.cursor.col;
                let here = self.cursor_absolute_line();
                if self.input_start.is_some_and(|(line, _)| line < here) {
                    self.input_start = None;
                }
                for r in 0..row {
                    self.active_grid_mut()
                        .fill_cells_respecting(r, 0, cols, blank, respect);
                    self.active_grid_mut().set_line_wrapped(r, false);
                }
                self.active_grid_mut().fill_cells_respecting(
                    row,
                    0,
                    col.saturating_add(1),
                    blank,
                    respect,
                );
            }
            2 | 3 => {
                self.input_start = None;
                for r in 0..rows {
                    self.active_grid_mut()
                        .fill_cells_respecting(r, 0, cols, blank, respect);
                    self.active_grid_mut().set_line_wrapped(r, false);
                }
            }
            _ => {}
        }
    }

    pub(crate) fn erase_in_line(&mut self, mode: u16) {
        let respect = self.protected_mode == ProtectedMode::Iso;
        self.erase_in_line_protected(mode, respect);
    }

    pub(crate) fn erase_in_line_protected(&mut self, mode: u16, respect: bool) {
        let row = self.cursor.row;
        let col = self.cursor.col;
        let cols = self.active_grid().cols();
        let blank = self.bce_blank();
        match mode {
            0 => self
                .active_grid_mut()
                .fill_cells_respecting(row, col, cols, blank, respect),
            1 => self.active_grid_mut().fill_cells_respecting(
                row,
                0,
                col.saturating_add(1),
                blank,
                respect,
            ),
            2 => {
                if self
                    .input_start
                    .is_some_and(|(line, _)| self.cursor_absolute_line() >= line)
                {
                    self.input_start = None;
                }
                self.active_grid_mut()
                    .fill_cells_respecting(row, 0, cols, blank, respect)
            }
            _ => {}
        }
    }

    pub(crate) fn insert_lines(&mut self, n: usize) {
        if n == 0 || self.cursor.row < self.scroll_top || self.cursor.row > self.scroll_bottom {
            return;
        }
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        self.cursor.col = hl;
        self.input_start = None;
        self.pending_wrap = false;
        let rows = self.active_grid().rows();
        let top = self.cursor.row;
        let bottom = self.scroll_bottom.min(rows.saturating_sub(1));
        if top > bottom {
            return;
        }
        let region_height = bottom - top + 1;
        let n = n.min(region_height);
        let full_width = self.h_margins_full();
        if n < region_height {
            for row in (top..=(bottom - n)).rev() {
                for col in hl..=hr {
                    let cell = self
                        .active_grid()
                        .get(row, col)
                        .copied()
                        .unwrap_or_default();
                    self.active_grid_mut().set(row + n, col, cell);
                }
                if full_width {
                    let wrapped = self.active_grid().is_line_wrapped(row);
                    self.active_grid_mut().set_line_wrapped(row + n, wrapped);
                    let owner = self.active_grid().row_owner(row);
                    self.active_grid_mut().set_row_owner(row + n, owner);
                    let prompt = self.active_grid().row_semantic_prompt(row);
                    self.active_grid_mut()
                        .set_row_semantic_prompt(row + n, prompt);
                }
            }
        }
        let blank = self.bce_blank();
        for row in top..(top + n) {
            self.active_grid_mut().fill_cells(row, hl, hr + 1, blank);
            if full_width {
                self.active_grid_mut().set_line_wrapped(row, false);
                self.active_grid_mut().set_row_owner(row, RowOwner::Empty);
                self.active_grid_mut()
                    .set_row_semantic_prompt(row, SemanticPrompt::Unset);
            }
        }
        if full_width {
            self.active_grid_mut().set_line_wrapped(bottom, false);
        } else {
            for row in top..=bottom {
                self.fix_wide_orphans(row);
            }
        }
        if full_width && self.active == ScreenBuffer::Primary {
            self.remap_screen_rows_down(top, bottom, n);
        }
    }

    pub(crate) fn delete_lines(&mut self, n: usize) {
        if n == 0 || self.cursor.row < self.scroll_top || self.cursor.row > self.scroll_bottom {
            return;
        }
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        self.cursor.col = hl;
        self.input_start = None;
        self.pending_wrap = false;
        let rows = self.active_grid().rows();
        let top = self.cursor.row;
        let bottom = self.scroll_bottom.min(rows.saturating_sub(1));
        if top > bottom {
            return;
        }
        let region_height = bottom - top + 1;
        let n = n.min(region_height);
        let full_width = self.h_margins_full();
        if n < region_height {
            for row in top..=(bottom - n) {
                for col in hl..=hr {
                    let cell = self
                        .active_grid()
                        .get(row + n, col)
                        .copied()
                        .unwrap_or_default();
                    self.active_grid_mut().set(row, col, cell);
                }
                if full_width {
                    let wrapped = self.active_grid().is_line_wrapped(row + n);
                    self.active_grid_mut().set_line_wrapped(row, wrapped);
                    let owner = self.active_grid().row_owner(row + n);
                    self.active_grid_mut().set_row_owner(row, owner);
                    let prompt = self.active_grid().row_semantic_prompt(row + n);
                    self.active_grid_mut().set_row_semantic_prompt(row, prompt);
                }
            }
        }
        let blank = self.bce_blank();
        for row in (bottom + 1 - n)..=bottom {
            self.active_grid_mut().fill_cells(row, hl, hr + 1, blank);
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
            self.remap_screen_rows_up(top, bottom, n);
        }
        self.fix_spacer_heads();
    }

    pub(crate) fn remap_screen_rows_down(&mut self, top: usize, bottom: usize, n: usize) {
        let sb = self.primary.scrollback_len() as u64;
        let first = self.primary.first_retained_line();
        let region_height = bottom - top + 1;
        let (shift_range, discard_range) = if n >= region_height {
            (
                None,
                (first + sb + top as u64)..=(first + sb + bottom as u64),
            )
        } else {
            let shift = (first + sb + top as u64)..=(first + sb + (bottom - n) as u64);
            let discard = (first + sb + (bottom - n + 1) as u64)..=(first + sb + bottom as u64);
            (Some(shift), discard)
        };

        if let Some(prompt) = self.last_prompt_line {
            if discard_range.contains(&prompt) {
                self.last_prompt_line = None;
            } else if shift_range
                .as_ref()
                .is_some_and(|shift| shift.contains(&prompt))
            {
                self.last_prompt_line = Some(prompt + n as u64);
            }
        }

        self.commands
            .shift_screen_prompts_down(shift_range, n as u64, discard_range);
    }

    pub(crate) fn remap_screen_rows_up(&mut self, top: usize, bottom: usize, n: usize) {
        let sb = self.primary.scrollback_len() as u64;
        let first = self.primary.first_retained_line();
        let region_height = bottom - top + 1;
        let (shift_range, discard_range) = if n >= region_height {
            (
                None,
                (first + sb + top as u64)..=(first + sb + bottom as u64),
            )
        } else {
            let discard = (first + sb + top as u64)..=(first + sb + (top + n - 1) as u64);
            let shift = (first + sb + (top + n) as u64)..=(first + sb + bottom as u64);
            (Some(shift), discard)
        };

        if let Some(prompt) = self.last_prompt_line {
            if discard_range.contains(&prompt) {
                self.last_prompt_line = None;
            } else if shift_range
                .as_ref()
                .is_some_and(|shift| shift.contains(&prompt))
            {
                self.last_prompt_line = Some(prompt - n as u64);
            }
        }

        self.commands
            .shift_screen_prompts_up(shift_range, n as u64, discard_range);
    }

    pub(crate) fn remap_prompts_below_scroll_region(
        &mut self,
        shift_range: RangeInclusive<u64>,
        delta: u64,
    ) {
        if let Some(prompt) = self.last_prompt_line
            && shift_range.contains(&prompt)
        {
            self.last_prompt_line = Some(prompt + delta);
        }
        self.commands.shift_prompts_forward(shift_range, delta);
    }
}
