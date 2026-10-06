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
    pub(crate) fn resize_with_cursor_and_remaps(
        &mut self,
        new_cols: usize,
        new_rows: usize,
        cursor: Option<(usize, usize)>,
    ) -> (Option<(usize, usize)>, Vec<(u64, u64)>) {
        let new_cols = new_cols.max(1);
        let new_rows = new_rows.max(1);
        let mut active_cursor = cursor.map(|(r, c)| {
            (
                r.min(self.rows.saturating_sub(1)),
                c.min(self.cols.saturating_sub(1)),
            )
        });

        // Upstream grows the active area into adjacent history when the cursor
        // is at the bottom. Do this at the old width before column reflow so
        // rows archived by a transient one-row orientation geometry become
        // visible input to the reflow instead of remaining stranded in
        // scrollback. A cursor away from the bottom intentionally keeps its
        // y coordinate and receives blank rows below it instead.
        if new_rows > self.rows {
            let (_, moved_cursor) = self.resize_rows_only(new_rows, active_cursor);
            active_cursor = moved_cursor;
        }

        if new_cols == self.cols {
            if new_rows < self.rows {
                let (_, moved_cursor) = self.resize_rows_only(new_rows, active_cursor);
                active_cursor = moved_cursor;
            }
            return (active_cursor, Vec::new());
        }

        // Width change: unwrap visible lines into logical lines, then
        // rewrap at the new width.
        let (target_cursor_row, target_cursor_col) = match active_cursor {
            Some((r, c)) => (
                Some(r.min(self.rows.saturating_sub(1))),
                Some(c.min(self.cols.saturating_sub(1))),
            ),
            None => (None, None),
        };

        struct PromptSpan {
            cell_offset: usize,
            semantic: SemanticPrompt,
            original_abs_line: u64,
        }

        struct LogicalLine {
            cells: Vec<Cell>,
            prompts: Vec<PromptSpan>,
            owner: RowOwner,
            cursor_offset: Option<usize>,
        }

        let base_line = (self.history_evicted() + self.scrollback_len()) as u64;
        let mut logical_lines: Vec<LogicalLine> = Vec::new();
        for row in 0..self.rows {
            let wrapped = self.is_line_wrapped(row);
            let row_cells = self.row_slice(row);
            let semantic = self.row_semantic_prompt(row);
            let owner = self.row_owner(row);
            let is_cursor_row = target_cursor_row == Some(row);

            if wrapped && !logical_lines.is_empty() {
                let last = logical_lines.last_mut().unwrap();
                let start_offset = last.cells.len();
                last.cells.extend_from_slice(row_cells);
                last.owner = last.owner.joined(owner);
                if is_cursor_row {
                    last.cursor_offset = Some(start_offset + target_cursor_col.unwrap_or(0));
                }
                last.prompts.push(PromptSpan {
                    cell_offset: start_offset,
                    semantic,
                    original_abs_line: base_line + row as u64,
                });
            } else {
                let cursor_offset = if is_cursor_row {
                    Some(target_cursor_col.unwrap_or(0))
                } else {
                    None
                };
                logical_lines.push(LogicalLine {
                    cells: row_cells.to_vec(),
                    prompts: vec![PromptSpan {
                        cell_offset: 0,
                        semantic,
                        original_abs_line: base_line + row as u64,
                    }],
                    owner,
                    cursor_offset,
                });
            }
        }
        if logical_lines.is_empty() {
            logical_lines.push(LogicalLine {
                cells: Vec::new(),
                prompts: vec![PromptSpan {
                    cell_offset: 0,
                    semantic: SemanticPrompt::Unset,
                    original_abs_line: base_line,
                }],
                owner: RowOwner::Empty,
                cursor_offset: if target_cursor_row.is_some() {
                    Some(0)
                } else {
                    None
                },
            });
        }

        // Trailing blank content must not consume rows after the rewrap:
        // drop trailing all-blank logical lines, and trailing blanks inside each line.
        let is_blank =
            |cell: &Cell| (cell.char == '\0' || cell.is_wide_spacer_head) && !cell.is_wide_spacer;
        for line in logical_lines.iter_mut() {
            while line.cells.last().is_some_and(&is_blank) {
                line.cells.pop();
            }
        }
        while logical_lines.len() > 1
            && logical_lines.last().is_some_and(|l| {
                l.cells.is_empty()
                    && l.cursor_offset.is_none()
                    && l.prompts
                        .iter()
                        .all(|p| p.semantic == SemanticPrompt::Unset)
            })
        {
            logical_lines.pop();
        }

        struct NewRow {
            cells: Vec<Cell>,
            wrapped: bool,
            semantic: SemanticPrompt,
            owner: RowOwner,
        }

        let mut new_rows_data: Vec<NewRow> = Vec::new();
        let mut final_cursor: Option<(usize, usize)> = None;
        let mut line_remaps: Vec<(u64, u64)> = Vec::new();

        for line in logical_lines {
            let start_new_row_idx = new_rows_data.len();
            let offsets: Vec<usize> = line.prompts.iter().map(|p| p.cell_offset).collect();
            let (mut wrapped_rows, line_cursor, mapped_sub_rows) =
                Self::rewrap_line_with_cursor(&line.cells, new_cols, line.cursor_offset, &offsets);
            if let Some((sub_r, sub_c)) = line_cursor {
                while wrapped_rows.len() <= sub_r {
                    wrapped_rows.push(vec![Cell::default(); new_cols]);
                }
                let global_row = start_new_row_idx + sub_r;
                final_cursor = Some((global_row, sub_c));
            }
            for &sub_r in &mapped_sub_rows {
                while wrapped_rows.len() <= sub_r {
                    wrapped_rows.push(vec![Cell::default(); new_cols]);
                }
            }

            for (p_idx, p) in line.prompts.iter().enumerate() {
                if p.semantic == SemanticPrompt::Prompt {
                    let sub_r = mapped_sub_rows[p_idx];
                    let new_abs_line = base_line + (start_new_row_idx + sub_r) as u64;
                    line_remaps.push((p.original_abs_line, new_abs_line));
                }
            }

            let mut sub_row_semantics = vec![SemanticPrompt::Unset; wrapped_rows.len()];
            let mut current_semantic = SemanticPrompt::Unset;
            let mut prompt_iter = line.prompts.iter().enumerate().peekable();

            for (r, sem) in sub_row_semantics.iter_mut().enumerate() {
                let mut matched_prompt = false;
                while let Some(&(p_idx, p)) = prompt_iter.peek() {
                    let p_sub_r = mapped_sub_rows[p_idx];
                    if p_sub_r <= r {
                        if p.semantic == SemanticPrompt::Prompt {
                            current_semantic = SemanticPrompt::Prompt;
                            matched_prompt = true;
                        } else if !matched_prompt && p.semantic != SemanticPrompt::Unset {
                            current_semantic = p.semantic;
                        }
                        prompt_iter.next();
                    } else {
                        break;
                    }
                }
                *sem = current_semantic;
                if current_semantic == SemanticPrompt::Prompt {
                    current_semantic = SemanticPrompt::PromptContinuation;
                }
            }

            for (i, row) in wrapped_rows.into_iter().enumerate() {
                let wrapped = i > 0;
                let semantic = sub_row_semantics[i];
                new_rows_data.push(NewRow {
                    cells: row,
                    wrapped,
                    semantic,
                    owner: line.owner,
                });
            }
        }

        // Build new backing storage at new_cols width. Anything beyond
        // new_rows going off the top becomes scrollback (oldest rows
        // first); anything short is padded with blank rows.
        let total = new_rows_data.len();
        let scrollback_extra: Vec<NewRow> = if total > new_rows {
            let overflow = total - new_rows;
            new_rows_data.drain(0..overflow).collect()
        } else {
            Vec::new()
        };

        let final_cursor = final_cursor.map(|(r, c)| {
            let overflow = scrollback_extra.len();
            let new_r = r.saturating_sub(overflow).min(new_rows.saturating_sub(1));
            let new_c = c.min(new_cols.saturating_sub(1));
            (new_r, new_c)
        });

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

        for (r, row_data) in new_rows_data.into_iter().enumerate() {
            if r >= new_rows {
                break;
            }
            let len = row_data.cells.len().min(new_cols);
            self.cells[r][..len].copy_from_slice(&row_data.cells[..len]);
            self.line_wrapped[r] = row_data.wrapped;
            self.row_semantic[r] = row_data.semantic;
            self.row_owner[r] = row_data.owner;
            self.row_may_have_wide[r] = self.cells[r]
                .iter()
                .any(|cell| cell.is_wide_spacer || cell.is_wide_spacer_head);
        }

        for row_data in scrollback_extra {
            self.push_scrollback(
                row_data.cells,
                row_data.wrapped,
                row_data.owner,
                row_data.semantic,
            );
        }

        (final_cursor, line_remaps)
    }

    /// Split one logical line into `new_cols`-wide rows while carrying an
    /// optional logical cursor offset and a set of cell offsets through the reflow.
    pub(crate) fn rewrap_line_with_cursor(
        logical: &[Cell],
        new_cols: usize,
        cursor_offset: Option<usize>,
        offsets: &[usize],
    ) -> (Vec<Vec<Cell>>, Option<(usize, usize)>, Vec<usize>) {
        if logical.is_empty() {
            let cursor_pos = cursor_offset.map(|offset| {
                let r = offset / new_cols;
                let c = offset % new_cols;
                (r, c)
            });
            let mapped_offsets = offsets.iter().map(|&offset| offset / new_cols).collect();
            return (
                vec![vec![Cell::default(); new_cols]],
                cursor_pos,
                mapped_offsets,
            );
        }
        let mut out: Vec<Vec<Cell>> = Vec::new();
        let mut row: Vec<Cell> = Vec::with_capacity(new_cols);
        let mut cursor_pos: Option<(usize, usize)> = None;
        let mut mapped_offsets: Vec<Option<usize>> = vec![None; offsets.len()];
        let mut i = 0;
        while i < logical.len() {
            let paired = !logical[i].is_wide_spacer
                && matches!(logical.get(i + 1), Some(next) if next.is_wide_spacer);
            let width = if paired { 2 } else { 1 };

            if width > new_cols {
                if !row.is_empty() {
                    row.resize(new_cols, Cell::default());
                    out.push(std::mem::take(&mut row));
                }
                for (idx, &off) in offsets.iter().enumerate() {
                    if mapped_offsets[idx].is_none() && off <= i {
                        mapped_offsets[idx] = Some(out.len());
                    }
                }
                if cursor_offset == Some(i) || (paired && cursor_offset == Some(i + 1)) {
                    cursor_pos = Some((out.len(), 0));
                }
                let mut only = vec![logical[i]];
                only.resize(new_cols, Cell::default());
                out.push(only);
                i += width;
                continue;
            }

            if row.len() + width > new_cols {
                row.resize(new_cols, Cell::default());
                out.push(std::mem::take(&mut row));
            }

            for (idx, &off) in offsets.iter().enumerate() {
                if mapped_offsets[idx].is_none() && off <= i {
                    mapped_offsets[idx] = Some(out.len());
                }
            }
            if cursor_offset == Some(i) {
                cursor_pos = Some((out.len(), row.len()));
            } else if paired && cursor_offset == Some(i + 1) {
                cursor_pos = Some((out.len(), row.len() + 1));
            }

            row.push(logical[i]);
            if paired {
                row.push(logical[i + 1]);
            }
            i += width;

            if row.len() == new_cols {
                out.push(std::mem::take(&mut row));
            }
        }

        if let Some(target_offset) = cursor_offset
            && cursor_pos.is_none()
        {
            let extra = target_offset.saturating_sub(logical.len());
            let current_sub_row = out.len();
            let current_sub_col = row.len();
            let total_col = current_sub_col + extra;
            let sub_row = current_sub_row + total_col / new_cols;
            let sub_col = total_col % new_cols;
            cursor_pos = Some((sub_row, sub_col));
        }

        for (idx, &off) in offsets.iter().enumerate() {
            if mapped_offsets[idx].is_none() {
                let extra = off.saturating_sub(logical.len());
                let total_col = row.len() + extra;
                let sub_row = out.len() + total_col / new_cols;
                mapped_offsets[idx] = Some(sub_row);
            }
        }

        if !row.is_empty() {
            row.resize(new_cols, Cell::default());
            out.push(row);
        }
        let mapped = mapped_offsets.into_iter().map(|m| m.unwrap_or(0)).collect();
        (out, cursor_pos, mapped)
    }
}
