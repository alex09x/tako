/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::{Cell, Grid};

impl Grid {
    /// Split one logical line into `new_cols`-wide rows while carrying an
    /// optional logical cursor offset and a set of cell offsets through the reflow.
    pub(crate) fn rewrap_line_with_cursor(
        logical: &[Cell],
        new_cols: usize,
        cursor_offset: Option<usize>,
        offsets: &[usize],
    ) -> (Vec<Vec<Cell>>, Option<(usize, usize)>, Vec<(usize, usize)>) {
        if logical.is_empty() {
            let cursor_pos = cursor_offset.map(|offset| {
                let r = offset / new_cols;
                let c = offset % new_cols;
                (r, c)
            });
            let mapped_offsets = offsets
                .iter()
                .map(|&offset| (offset / new_cols, offset % new_cols))
                .collect();
            return (
                vec![vec![Cell::default(); new_cols]],
                cursor_pos,
                mapped_offsets,
            );
        }
        let mut out: Vec<Vec<Cell>> = Vec::new();
        let mut row: Vec<Cell> = Vec::with_capacity(new_cols);
        let mut cursor_pos: Option<(usize, usize)> = None;
        let mut mapped_offsets: Vec<Option<(usize, usize)>> = vec![None; offsets.len()];
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
                    if mapped_offsets[idx].is_none() && (off <= i || (paired && off == i + 1)) {
                        mapped_offsets[idx] = Some((out.len(), 0));
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
                if mapped_offsets[idx].is_none() && (off <= i || (paired && off == i + 1)) {
                    mapped_offsets[idx] = Some((out.len(), row.len() + usize::from(off == i + 1)));
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
                mapped_offsets[idx] = Some((sub_row, total_col % new_cols));
            }
        }

        if !row.is_empty() {
            row.resize(new_cols, Cell::default());
            out.push(row);
        }
        let mapped = mapped_offsets
            .into_iter()
            .map(|m| m.unwrap_or((0, 0)))
            .collect();
        (out, cursor_pos, mapped)
    }
}
