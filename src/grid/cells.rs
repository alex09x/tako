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

use super::grapheme::GraphemeTable;
use super::types::{Cell, DEFAULT_SCROLLBACK_CAPACITY, Grid, RowOwner, SemanticPrompt};

impl Grid {
    /// Create a new grid of `cols` x `rows`, filled with default (blank)
    /// cells, using the default scrollback capacity.
    pub fn new(cols: usize, rows: usize) -> Self {
        Self::with_scrollback_capacity(cols, rows, DEFAULT_SCROLLBACK_CAPACITY)
    }

    /// Create a new grid with an explicit scrollback capacity (in lines).
    pub fn with_scrollback_capacity(cols: usize, rows: usize, scrollback_capacity: usize) -> Self {
        let cols = cols.max(1);
        let rows = rows.max(1);
        Self {
            cols,
            rows,
            cells: vec![vec![Cell::default(); cols]; rows],
            line_wrapped: vec![false; rows],
            row_semantic: vec![SemanticPrompt::Unset; rows],
            row_owner: vec![RowOwner::Empty; rows],
            pen_owner: None,
            dirty: vec![true; rows],
            row_may_have_wide: vec![false; rows],
            row_offset: 0,
            row_slots: (0..rows).collect(),
            scrollback: VecDeque::new(),
            scrollback_capacity,
            history_evicted: 0,
            graphemes: GraphemeTable::default(),
        }
    }

    #[inline]
    pub fn cols(&self) -> usize {
        self.cols
    }

    #[inline]
    pub fn rows(&self) -> usize {
        self.rows
    }

    /// Translate a logical row into its slot in the circular row-order map.
    #[inline]
    pub(crate) fn slot(&self, row: usize) -> usize {
        debug_assert!(
            row < self.rows,
            "slot() called with out-of-range logical row"
        );
        let raw = self.row_offset + row;
        if raw >= self.rows {
            raw - self.rows
        } else {
            raw
        }
    }

    /// Translate a logical row index into the physical row that currently
    /// backs it. Callers must have already rejected `row >= self.rows`.
    #[inline]
    pub(crate) fn phys(&self, row: usize) -> usize {
        self.row_slots[self.slot(row)]
    }

    /// Rotate the backing storage so that logical row 0 sits at physical
    /// row 0 again. Used by the paths that rebuild or splice the row
    /// vectors wholesale (resize), where a rotation is free relative to the
    /// work they already do.
    pub(crate) fn normalize(&mut self) {
        if self.row_offset == 0 && self.row_slots.iter().copied().eq(0..self.rows) {
            return;
        }
        debug_assert_eq!(self.cells.len(), self.rows);
        debug_assert!(self.cells.iter().all(|row| row.len() == self.cols));
        debug_assert_eq!(self.line_wrapped.len(), self.rows);
        debug_assert_eq!(self.row_semantic.len(), self.rows);
        debug_assert_eq!(self.row_owner.len(), self.rows);
        debug_assert_eq!(self.dirty.len(), self.rows);
        debug_assert_eq!(self.row_may_have_wide.len(), self.rows);
        debug_assert_eq!(self.row_slots.len(), self.rows);

        let physical_order: Vec<usize> = (0..self.rows).map(|row| self.phys(row)).collect();
        let mut old_cells: Vec<Option<Vec<Cell>>> = std::mem::take(&mut self.cells)
            .into_iter()
            .map(Some)
            .collect();
        let cells = physical_order
            .iter()
            .map(|&physical| old_cells[physical].take().unwrap())
            .collect();
        let mut line_wrapped = vec![false; self.rows];
        let mut row_semantic = vec![SemanticPrompt::Unset; self.rows];
        let mut row_owner = vec![RowOwner::Empty; self.rows];
        let mut dirty = vec![false; self.rows];
        let mut row_may_have_wide = vec![false; self.rows];
        for logical in 0..self.rows {
            let physical = self.phys(logical);
            line_wrapped[logical] = self.line_wrapped[physical];
            row_semantic[logical] = self.row_semantic[physical];
            row_owner[logical] = self.row_owner[physical];
            dirty[logical] = self.dirty[physical];
            row_may_have_wide[logical] = self.row_may_have_wide[physical];
        }

        self.cells = cells;
        self.line_wrapped = line_wrapped;
        self.row_semantic = row_semantic;
        self.row_owner = row_owner;
        self.dirty = dirty;
        self.row_may_have_wide = row_may_have_wide;
        self.row_offset = 0;
        self.row_slots = (0..self.rows).collect();
    }

    pub fn get(&self, row: usize, col: usize) -> Option<&Cell> {
        if row >= self.rows || col >= self.cols {
            return None;
        }
        self.cells[self.phys(row)].get(col)
    }

    pub fn get_mut(&mut self, row: usize, col: usize) -> Option<&mut Cell> {
        self.mark_dirty(row);
        if row >= self.rows || col >= self.cols {
            return None;
        }
        let physical = self.phys(row);
        self.row_may_have_wide[physical] = true;
        self.touch_owner(physical);
        self.cells[physical].get_mut(col)
    }

    pub fn set(&mut self, row: usize, col: usize, cell: Cell) {
        if row >= self.rows || col >= self.cols {
            return;
        }
        let physical = self.phys(row);
        self.cells[physical][col] = cell;
        self.touch_owner(physical);
        if cell.is_wide_spacer || cell.is_wide_spacer_head {
            self.row_may_have_wide[physical] = true;
        }
        self.mark_dirty(row);
    }

    /// Write a double-width `cell` at `(row, col)` together with its
    /// spacer at `(row, col + 1)`.
    ///
    /// Returns `false` without writing anything if the pair would not fit
    /// on `row` — the caller is responsible for wrapping to the next line
    /// first, since a wide cell must never occupy the last column.
    pub fn set_wide(&mut self, row: usize, col: usize, cell: Cell) -> bool {
        self.mark_dirty(row);
        if row >= self.rows || col + 1 >= self.cols {
            return false;
        }
        let spacer = Cell {
            char: ' ',
            is_wide_spacer: true,
            grapheme: 0,
            ..cell
        };
        let physical = self.phys(row);
        self.cells[physical][col] = cell;
        self.cells[physical][col + 1] = spacer;
        self.row_may_have_wide[physical] = true;
        self.touch_owner(physical);
        true
    }

    /// Whether `row` may contain a wide spacer or spacer-head cell.
    /// A false result is exact; true is deliberately conservative.
    #[inline]
    pub fn row_may_have_wide(&self, row: usize) -> bool {
        row < self.rows && self.row_may_have_wide[self.phys(row)]
    }

    /// The codepoints of `cell`'s grapheme cluster after its `char`; empty
    /// when `char` is the whole cluster. `cell` must come from this grid or
    /// its scrollback.
    #[inline]
    pub fn grapheme(&self, cell: &Cell) -> &str {
        if cell.grapheme == 0 {
            return "";
        }
        self.graphemes.text(cell.grapheme)
    }

    /// Appends the text `cell` shows: its character, NUL as a space, then
    /// the rest of its grapheme cluster.
    #[inline]
    pub fn push_cell_text(&self, out: &mut String, cell: &Cell) {
        out.push(if cell.char == '\0' { ' ' } else { cell.char });
        if cell.grapheme != 0 {
            out.push_str(self.graphemes.text(cell.grapheme));
        }
    }

    /// Whether `cell` is the first half of a double-width pair by content:
    /// a double-width character, or a cluster written two columns wide.
    pub fn cell_is_wide(&self, cell: &Cell) -> bool {
        if cell.grapheme != 0
            && let Some(wide) = self.graphemes.is_wide(cell.grapheme)
        {
            return wide;
        }
        unicode_width::UnicodeWidthChar::width(cell.char).unwrap_or(1) >= 2
    }

    /// The id for a cluster whose codepoints after the base character are
    /// `extra`, written `wide` or not. 0 (the base character alone) when the
    /// table has no room left even after reclaiming unused entries.
    pub(crate) fn intern_grapheme(&mut self, extra: &str, wide: bool) -> u16 {
        if extra.is_empty() {
            return 0;
        }
        if let Some(id) = self.graphemes.find(extra, wide) {
            return id;
        }
        if self.graphemes.wants_collection() {
            self.collect_graphemes();
        }
        self.graphemes.insert(extra, wide).unwrap_or(0)
    }

    /// Reclaims every table entry no cell of the grid or its scrollback
    /// names.
    fn collect_graphemes(&mut self) {
        let mut live = GraphemeTable::live_set();
        let rows = self.cells.iter().map(Vec::as_slice);
        let history = self.scrollback.iter().map(|row| row.cells.as_slice());
        for cells in rows.chain(history) {
            for cell in cells {
                let id = cell.grapheme as usize;
                live[id / 64] |= 1 << (id % 64);
            }
        }
        self.graphemes.sweep(&live);
    }

    /// Overwrite a narrow ASCII run with one bounds check and one damage
    /// update. Returns false when the row may contain a wide pair, whose
    /// neighbour cleanup requires the terminal's general print path.
    pub(crate) fn write_narrow_ascii(
        &mut self,
        row: usize,
        start: usize,
        bytes: &[u8],
        template: Cell,
    ) -> bool {
        let cols = self.cols;
        if row >= self.rows || start >= cols || bytes.is_empty() {
            return false;
        }
        let physical = self.phys(row);
        if self.row_may_have_wide[physical] {
            return false;
        }
        let count = bytes.len().min(cols - start);
        let target = &mut self.cells[physical][start..start + count];
        for (dst, &byte) in target.iter_mut().zip(&bytes[..count]) {
            *dst = Cell {
                char: byte as char,
                ..template
            };
        }
        self.touch_owner(physical);
        self.mark_dirty(row);
        count == bytes.len()
    }
}
