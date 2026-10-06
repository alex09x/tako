/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::collections::VecDeque;

use super::grapheme::{GraphemeTable, MAX_EXTRA_BYTES};
use super::types::{Cell, Grid, RowOwner, ScrollbackRow, SemanticPrompt};

impl Grid {
    /// Every cell that holds a grapheme cluster, as `(line, col, extra,
    /// wide)`: `line` counts the scrollback oldest-first and then the visible
    /// rows, `extra` is the cluster after the cell's `char`.
    pub(crate) fn clusters(&self) -> Vec<(usize, usize, &str, bool)> {
        let history = self.scrollback.iter().map(|row| row.cells.as_slice());
        let visible = (0..self.rows).map(|row| self.row_slice(row));
        let mut found = Vec::new();
        for (line, cells) in history.chain(visible).enumerate() {
            for (col, cell) in cells.iter().enumerate() {
                if cell.grapheme != 0 {
                    let wide = self.graphemes.is_wide(cell.grapheme).unwrap_or(false);
                    found.push((line, col, self.graphemes.text(cell.grapheme), wide));
                }
            }
        }
        found
    }

    /// Gives the cell at `line` (numbered as in [`Self::clusters`]) and `col`
    /// the cluster `extra`. False when there is no such cell or no room in
    /// the table, leaving the cell its base character.
    pub(crate) fn restore_cluster(
        &mut self,
        line: usize,
        col: usize,
        extra: &str,
        wide: bool,
    ) -> bool {
        let history = self.scrollback.len();
        let exists = if line < history {
            col < self.scrollback[line].cells.len()
        } else {
            line - history < self.rows && col < self.cols
        };
        if !exists || extra.is_empty() || extra.len() > MAX_EXTRA_BYTES {
            return false;
        }
        let id = self.intern_grapheme(extra, wide);
        if id == 0 {
            return false;
        }
        if line < history {
            self.scrollback[line].cells[col].grapheme = id;
        } else {
            let physical = self.phys(line - history);
            self.cells[physical][col].grapheme = id;
        }
        true
    }

    /// Heap this grid holds, counted by *capacity* rather than length.
    pub fn retained_capacity_bytes(&self) -> u64 {
        let cell = std::mem::size_of::<Cell>() as u64;
        let mut total: u64 = 0;
        total = total.saturating_add(
            (self.cells.capacity() as u64).saturating_mul(std::mem::size_of::<Vec<Cell>>() as u64),
        );
        for row in &self.cells {
            total = total.saturating_add((row.capacity() as u64).saturating_mul(cell));
        }
        total = total.saturating_add(self.line_wrapped.capacity() as u64);
        total = total.saturating_add(
            (self.row_semantic.capacity() as u64)
                .saturating_mul(std::mem::size_of::<SemanticPrompt>() as u64),
        );
        total = total.saturating_add(
            (self.row_owner.capacity() as u64)
                .saturating_mul(std::mem::size_of::<RowOwner>() as u64),
        );
        total = total.saturating_add(self.dirty.capacity() as u64);
        total = total.saturating_add(self.row_may_have_wide.capacity() as u64);
        total = total.saturating_add(
            (self.row_slots.capacity() as u64).saturating_mul(std::mem::size_of::<usize>() as u64),
        );
        total = total.saturating_add(
            (self.scrollback.capacity() as u64)
                .saturating_mul(std::mem::size_of::<ScrollbackRow>() as u64),
        );
        for row in &self.scrollback {
            total = total.saturating_add((row.cells.capacity() as u64).saturating_mul(cell));
        }
        total.saturating_add(self.graphemes.heap_bytes())
    }

    pub fn raw_parts(
        &self,
    ) -> (
        usize,
        usize,
        usize,
        usize,
        Vec<Vec<Cell>>,
        Vec<bool>,
        Vec<SemanticPrompt>,
        Vec<ScrollbackRow>,
    ) {
        let mut cells = Vec::with_capacity(self.rows);
        let mut line_wrapped = Vec::with_capacity(self.rows);
        let mut row_semantic = Vec::with_capacity(self.rows);
        for r in 0..self.rows {
            cells.push(self.row_slice(r).to_vec());
            line_wrapped.push(self.is_line_wrapped(r));
            row_semantic.push(self.row_semantic_prompt(r));
        }
        let scrollback = self.scrollback.iter().cloned().collect();
        (
            self.cols,
            self.rows,
            self.scrollback_capacity,
            self.history_evicted,
            cells,
            line_wrapped,
            row_semantic,
            scrollback,
        )
    }

    pub fn from_raw_parts(
        cols: usize,
        rows: usize,
        scrollback_capacity: usize,
        history_evicted: usize,
        mut visible_cells: Vec<Vec<Cell>>,
        mut line_wrapped: Vec<bool>,
        mut row_semantic: Vec<SemanticPrompt>,
        scrollback: Vec<ScrollbackRow>,
    ) -> Self {
        let cols = cols.max(1);
        let rows = rows.max(1);
        visible_cells.resize_with(rows, || vec![Cell::default(); cols]);
        for r in &mut visible_cells {
            r.resize(cols, Cell::default());
        }
        line_wrapped.resize(rows, false);
        row_semantic.resize(rows, SemanticPrompt::Unset);
        let row_owner = visible_cells
            .iter()
            .map(|r| RowOwner::of_cells(r))
            .collect();
        let dirty = vec![true; rows];
        let mut row_may_have_wide = vec![false; rows];
        for (i, r) in visible_cells.iter().enumerate() {
            if r.iter().any(|c| c.is_wide_spacer || c.is_wide_spacer_head) {
                row_may_have_wide[i] = true;
            }
        }
        let mut sb: VecDeque<ScrollbackRow> = scrollback.into();
        while sb.len() > scrollback_capacity && scrollback_capacity > 0 {
            sb.pop_front();
        }
        Self {
            cols,
            rows,
            cells: visible_cells,
            line_wrapped,
            row_semantic,
            row_owner,
            pen_owner: None,
            dirty,
            row_may_have_wide,
            row_offset: 0,
            row_slots: (0..rows).collect(),
            scrollback: sb,
            scrollback_capacity,
            history_evicted,
            graphemes: GraphemeTable::default(),
        }
    }
}
