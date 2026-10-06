/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use bitflags::bitflags;
use std::collections::VecDeque;

use super::grapheme::GraphemeTable;

/// Default cap on how many scrollback lines are retained before the oldest
/// lines are dropped.
pub const DEFAULT_SCROLLBACK_CAPACITY: usize = 10_000;

/// Per-row OSC 133 semantic-prompt mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SemanticPrompt {
    #[default]
    Unset,
    Prompt,
    PromptContinuation,
}

/// Which command's output a row holds, as far as OSC 133 marks can tell.
///
/// A row is claimed by a command only while it is clean or already that
/// command's: anything written into a row that holds something else -- a
/// prompt, another command's output, text written outside any command --
/// makes it [`RowOwner::Mixed`], which never groups. Erasing the whole row
/// makes it clean again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RowOwner {
    /// Nothing has been written since the row was last blank.
    #[default]
    Empty,
    /// Written outside any command (a prompt, a program without marks, or
    /// content restored from a source that carried no owners).
    Unowned,
    /// Holds writes from more than one source.
    Mixed,
    /// Written only while command `id` was producing output.
    Command(u64),
}

impl RowOwner {
    /// The owner after something is written into a row owned by `self`
    /// while `pen` is the command producing output (if any).
    #[inline]
    pub fn after_write(self, pen: Option<u64>) -> RowOwner {
        match (self, pen) {
            (RowOwner::Empty, Some(id)) => RowOwner::Command(id),
            (RowOwner::Empty, None) => RowOwner::Unowned,
            (RowOwner::Command(a), Some(b)) if a == b => self,
            (RowOwner::Unowned, None) => RowOwner::Unowned,
            _ => RowOwner::Mixed,
        }
    }

    /// The owner of one row made by joining rows owned by `self` and
    /// `other` (reflow joins the rows of a soft-wrapped line).
    #[inline]
    pub fn joined(self, other: RowOwner) -> RowOwner {
        match (self, other) {
            (RowOwner::Empty, o) | (o, RowOwner::Empty) => o,
            (a, b) if a == b => a,
            _ => RowOwner::Mixed,
        }
    }

    /// The owner a row of `cells` gets when nothing better is known: clean
    /// when it shows nothing, otherwise of unknown origin.
    pub fn of_cells(cells: &[Cell]) -> RowOwner {
        if cells
            .iter()
            .all(|c| (c.char == '\0' || c.char == ' ') && c.grapheme == 0)
        {
            RowOwner::Empty
        } else {
            RowOwner::Unowned
        }
    }
}

/// A cell's foreground/background color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Color {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

bitflags! {
    /// Text attribute flags for a single cell.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub struct CellAttrs: u16 {
        const BOLD          = 1 << 0;
        const DIM           = 1 << 1;
        const ITALIC        = 1 << 2;
        const UNDERLINE     = 1 << 3;
        const BLINK         = 1 << 4;
        const REVERSE       = 1 << 5;
        const HIDDEN        = 1 << 6;
        const STRIKETHROUGH = 1 << 7;
        const OVERLINE      = 1 << 8;
    }
}

/// A single terminal grid cell: a displayed character plus its styling.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cell {
    pub char: char,
    pub fg: Color,
    pub bg: Color,
    pub attrs: CellAttrs,
    /// Id into the owning [`crate::terminal::Terminal`]'s hyperlink table
    /// (see `Terminal::hyperlink_uri`), or `None` if this cell isn't part
    /// of an OSC 8 hyperlink span.
    pub hyperlink: Option<u32>,
    /// Set on the second column of a double-width glyph. Such a cell is
    /// always immediately preceded (in the same row) by the wide cell it
    /// belongs to; the two are written, cleared and reflowed as one unit.
    pub is_wide_spacer: bool,
    /// DECSCA / SPA protection flag: selective erases (and, for ISO
    /// protection, plain erases too) leave this cell untouched.
    pub protected: bool,
    /// Set on the cell left behind in the last screen column when a wide
    /// glyph could not fit there and wrapped to the next row (upstream's
    /// `spacer_head`). Rendered blank; cleared by any overwrite.
    pub is_wide_spacer_head: bool,
    /// SGR 4:x underline style: 0 none (single via legacy UNDERLINE attr),
    /// 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    pub underline_style: u8,
    /// SGR 58/59 underline color; `Color::Default` means "same as fg".
    pub underline_color: Color,
    /// The rest of this cell's grapheme cluster after `char` -- combining
    /// marks, joiners, variation selectors, skin tones, a flag's second
    /// regional indicator -- as an id into the owning [`Grid`]'s table (see
    /// [`Grid::grapheme`]). 0 when `char` is the whole cluster.
    pub grapheme: u16,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            char: '\0',
            fg: Color::Default,
            bg: Color::Default,
            attrs: CellAttrs::empty(),
            hyperlink: None,
            is_wide_spacer: false,
            protected: false,
            is_wide_spacer_head: false,
            underline_style: 0,
            underline_color: Color::Default,
            grapheme: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ScrollbackRow {
    pub cells: Vec<Cell>,
    pub wrapped: bool,
    pub owner: RowOwner,
    pub semantic: SemanticPrompt,
}

/// The visible terminal grid plus a bounded scrollback buffer.
#[derive(Clone)]
pub struct Grid {
    pub(crate) cols: usize,
    pub(crate) rows: usize,
    pub(crate) cells: Vec<Vec<Cell>>,
    pub(crate) line_wrapped: Vec<bool>,
    pub(crate) row_semantic: Vec<SemanticPrompt>,
    pub(crate) row_owner: Vec<RowOwner>,
    pub(crate) pen_owner: Option<u64>,
    pub(crate) dirty: Vec<bool>,
    pub(crate) row_may_have_wide: Vec<bool>,
    pub(crate) row_offset: usize,
    pub(crate) row_slots: Vec<usize>,
    pub(crate) scrollback: VecDeque<ScrollbackRow>,
    pub(crate) scrollback_capacity: usize,
    pub(crate) history_evicted: usize,
    pub(crate) graphemes: GraphemeTable,
}

impl std::fmt::Debug for Grid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let cells: Vec<&[Cell]> = (0..self.rows).map(|r| self.row_slice(r)).collect();
        let line_wrapped: Vec<bool> = (0..self.rows).map(|r| self.is_line_wrapped(r)).collect();
        let row_semantic: Vec<SemanticPrompt> = (0..self.rows)
            .map(|r| self.row_semantic_prompt(r))
            .collect();
        let dirty: Vec<bool> = (0..self.rows).map(|r| self.is_dirty(r)).collect();
        f.debug_struct("Grid")
            .field("cols", &self.cols)
            .field("rows", &self.rows)
            .field("cells", &cells)
            .field("line_wrapped", &line_wrapped)
            .field("row_semantic", &row_semantic)
            .field("dirty", &dirty)
            .field("scrollback", &self.scrollback)
            .field("scrollback_capacity", &self.scrollback_capacity)
            .field("history_evicted", &self.history_evicted)
            .finish()
    }
}
