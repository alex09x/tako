// The cell grid, its scrollback ring, and reflow on resize.

use std::collections::VecDeque;

use bitflags::bitflags;

mod grapheme;

use grapheme::GraphemeTable;
pub(crate) use grapheme::{
    MAX_EXTRA_BYTES, always_breaks, continues_cluster, unicode_cluster_is_wide,
};

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
            // Never-touched/erased cells hold NUL, like upstream; renderers
            // and plain_string() present it as a space.
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
}

/// The visible terminal grid plus a bounded scrollback buffer.
///
/// Rows are addressed `[0, rows)` top-to-bottom; columns `[0, cols)`
/// left-to-right. That addressing is *logical*: the backing storage is a
/// row-circular buffer. `row_offset` chooses the first logical slot and
/// `row_slots` maps each slot to the physical row that owns its cells (see
/// [`Grid::phys`]). Scrolling therefore rotates row identities and only
/// rewrites the rows that are actually blanked, instead of memmoving every
/// remaining cell.
///
/// All per-row vectors (`cells`, `line_wrapped`,
/// `row_semantic`, `dirty`, `row_may_have_wide`) are indexed *physically* and
/// are always exactly `rows` entries long; only [`Grid::phys`] translates
/// between the two spaces. `Clone` is derived: `row_offset` travels with the
/// copy, which is harmless because nothing outside this module can observe it.
#[derive(Clone)]
pub struct Grid {
    cols: usize,
    rows: usize,
    cells: Vec<Vec<Cell>>,
    /// Per-row flag: true if this row is a soft-wrapped continuation of the
    /// row above it (set by the `Terminal`/`print` layer when it wraps at
    /// end-of-line), false if it's a hard line (created by an explicit
    /// newline or freshly cleared).
    line_wrapped: Vec<bool>,
    /// Per-row OSC 133 semantic-prompt marks, parallel to `line_wrapped`.
    row_semantic: Vec<SemanticPrompt>,
    /// Per-row damage flags: set on any mutation, cleared by the host
    /// after it redraws (see `Terminal::take_damage`).
    dirty: Vec<bool>,
    /// Conservative per-row hint used to skip wide-pair repair on ordinary
    /// ASCII rows. False guarantees that no cell in the row is a wide
    /// spacer/head; true may be a stale false positive after partial erases.
    row_may_have_wide: Vec<bool>,
    /// Physical row index that logical row 0 currently maps to.
    /// Always in `[0, rows)`.
    row_offset: usize,
    /// Maps circular logical slots to physical cell/metadata rows. Keeping
    /// this indirection separate from `row_offset` lets a bounded vertical
    /// scroll region rotate row identities without moving cell contents.
    row_slots: Vec<usize>,
    /// Scrollback ring buffer. Index 0 is the oldest retained line, the back
    /// is the most-recently-scrolled-off line (i.e. the one nearest the top
    /// of the visible grid).
    scrollback: VecDeque<ScrollbackRow>,
    scrollback_capacity: usize,
    history_evicted: usize,
    /// Grapheme clusters named by `Cell::grapheme` in the grid and its
    /// scrollback.
    graphemes: GraphemeTable,
}

impl std::fmt::Debug for Grid {
    /// Presents rows in logical top-to-bottom order so the physical
    /// rotation is never visible in debug output (and two grids with the
    /// same content format identically regardless of scroll history).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let cells: Vec<&[Cell]> = (0..self.rows).map(|r| self.row_slice(r)).collect();
        let line_wrapped: Vec<bool> = (0..self.rows).map(|r| self.is_line_wrapped(r)).collect();
        let row_semantic: Vec<SemanticPrompt> =
            (0..self.rows).map(|r| self.row_semantic_prompt(r)).collect();
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
    fn slot(&self, row: usize) -> usize {
        debug_assert!(row < self.rows, "slot() called with out-of-range logical row");
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
    fn phys(&self, row: usize) -> usize {
        self.row_slots[self.slot(row)]
    }

    /// Rotate the backing storage so that logical row 0 sits at physical
    /// row 0 again. Used by the paths that rebuild or splice the row
    /// vectors wholesale (resize), where a rotation is free relative to the
    /// work they already do.
    fn normalize(&mut self) {
        if self.row_offset == 0
            && self.row_slots.iter().copied().eq(0..self.rows)
        {
            return;
        }
        debug_assert_eq!(self.cells.len(), self.rows);
        debug_assert!(self.cells.iter().all(|row| row.len() == self.cols));
        debug_assert_eq!(self.line_wrapped.len(), self.rows);
        debug_assert_eq!(self.row_semantic.len(), self.rows);
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
        let mut dirty = vec![false; self.rows];
        let mut row_may_have_wide = vec![false; self.rows];
        for logical in 0..self.rows {
            let physical = self.phys(logical);
            line_wrapped[logical] = self.line_wrapped[physical];
            row_semantic[logical] = self.row_semantic[physical];
            dirty[logical] = self.dirty[physical];
            row_may_have_wide[logical] = self.row_may_have_wide[physical];
        }

        self.cells = cells;
        self.line_wrapped = line_wrapped;
        self.row_semantic = row_semantic;
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
        self.cells[physical].get_mut(col)
    }

    pub fn set(&mut self, row: usize, col: usize, cell: Cell) {
        if row >= self.rows || col >= self.cols {
            return;
        }
        let physical = self.phys(row);
        self.cells[physical][col] = cell;
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
        // The spacer carries the wide cell's styling so that erasing or
        // selecting either half behaves identically.
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
        let Some(end) = start.checked_add(bytes.len()) else {
            return false;
        };
        if row >= self.rows || end > self.cols || self.row_may_have_wide(row) {
            return false;
        }

        let physical = self.phys(row);
        for (cell, &byte) in self.cells[physical][start..end].iter_mut().zip(bytes) {
            let mut next = template;
            next.char = byte as char;
            *cell = next;
        }
        self.mark_dirty(row);
        true
    }

    /// Mark `row` as needing a redraw.
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
    /// A pure observer, for callers that need to know a redraw is pending
    /// but must leave the flags intact for the next `clear_dirty` (see
    /// `Terminal::has_damage`).
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

    /// Set the OSC 133 semantic-prompt mark for `row`.
    pub fn set_row_semantic_prompt(&mut self, row: usize, mark: SemanticPrompt) {
        if row >= self.rows {
            return;
        }
        let p = self.phys(row);
        self.row_semantic[p] = mark;
    }

    /// Whether `row` is a soft-wrapped continuation of the row above it.
    pub fn is_line_wrapped(&self, row: usize) -> bool {
        if row >= self.rows {
            return false;
        }
        self.line_wrapped[self.phys(row)]
    }

    /// Mark whether `row` is a soft-wrapped continuation of the row above
    /// it. The `Terminal`/`print` layer should call this when it wraps
    /// output at the end of a line.
    pub fn set_line_wrapped(&mut self, row: usize, wrapped: bool) {
        if row >= self.rows {
            return;
        }
        let p = self.phys(row);
        self.line_wrapped[p] = wrapped;
    }

    fn row_slice(&self, row: usize) -> &[Cell] {
        &self.cells[self.phys(row)]
    }

    fn row_slice_mut(&mut self, row: usize) -> &mut [Cell] {
        let physical = self.phys(row);
        &mut self.cells[physical]
    }

    /// Clear the entire visible grid to blank cells (does not touch
    /// scrollback).
    pub fn clear_all(&mut self) {
        for row in self.cells.iter_mut() {
            row.fill(Cell::default());
        }
        for w in self.line_wrapped.iter_mut() {
            *w = false;
        }
        self.row_may_have_wide.fill(false);
    }

    /// Blank `[start, end)` on `row`, widening the range so that a
    /// double-width pair is never half-cleared: clearing a spacer also
    /// clears the wide cell before it, and clearing a wide cell also
    /// clears the spacer after it.
    fn clear_range(&mut self, row: usize, start: usize, end: usize) {
        self.fill_cells(row, start, end, Cell::default());
    }

    /// Fill `[start, end)` on `row` with `blank`, widening the range so a
    /// double-width pair is never half-overwritten (same rules as clearing).
    /// Public so the terminal can implement bg-preserving erases (ECH/BCE)
    /// without duplicating the pair-widening logic.
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
        for c in start..end {
            if respect_protected && row_cells[c].protected {
                continue;
            }
            row_cells[c] = blank;
        }
        if blank.is_wide_spacer || blank.is_wide_spacer_head {
            let physical = self.phys(row);
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
        self.set_line_wrapped(row, false);
    }

    /// Scroll the visible grid up by `n` lines: the top `n` rows are pushed
    /// into scrollback (oldest-first push order preserved), remaining rows
    /// shift up, and `n` new blank rows appear at the bottom.
    pub fn scroll_up(&mut self, n: usize) {
        self.scroll_up_with_blank(n, Cell::default());
    }

    /// [`Self::scroll_up`] with a caller-supplied template for the rows
    /// scrolled in at the bottom -- BCE: scrolled-in cells keep the active
    /// background color.
    ///
    /// Cells that stay on screen are never moved: the `n` archived rows are
    /// blanked in place and become the new bottom rows once `row_offset`
    /// advances past them, so the cost is `O(n * cols)` rather than
    /// `O(rows * cols)`.
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
            self.row_may_have_wide[p] = blank.is_wide_spacer || blank.is_wide_spacer_head;
        }

        // Rotate the logical origin. When `n == self.rows` every row was
        // just blanked, so the offset legitimately stays put.
        self.row_offset = self.slot(n % self.rows);
    }

    /// Scroll a full-width visible row region `[top, bottom]` upward.
    ///
    /// Unlike [`Self::scroll_up_with_blank`], this does not create
    /// scrollback: callers that need it must first call
    /// [`Self::stash_top_rows`]. Only row identities are rotated; cells in
    /// rows that remain visible are never copied. This mirrors upstream's
    /// hot DECSTBM path and costs `O(n * (region_rows + cols))`.
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

        // Rotate one row identity at a time. DECSTBM's overwhelmingly hot
        // path is n=1, so this avoids allocating a temporary map for every
        // line while remaining bounded for larger CSI scroll counts.
        for _ in 0..n {
            let recycled = self.phys(top);
            self.cells[recycled].fill(blank);
            self.line_wrapped[recycled] = false;
            self.row_semantic[recycled] = SemanticPrompt::Unset;
            self.row_may_have_wide[recycled] =
                blank.is_wide_spacer || blank.is_wide_spacer_head;

            for row in top..bottom {
                let destination = self.slot(row);
                let source = self.slot(row + 1);
                self.row_slots[destination] = self.row_slots[source];
            }
            let bottom_slot = self.slot(bottom);
            self.row_slots[bottom_slot] = recycled;
        }
    }

    /// Copy rows `0..n` into scrollback without shifting anything -- used
    /// when a partial-height scroll region anchored at row 0 scrolls (those
    /// lines leave the screen exactly like a full-screen scroll).
    pub fn stash_top_rows(&mut self, n: usize) {
        for row in 0..n.min(self.rows) {
            let wrapped = self.is_line_wrapped(row);
            self.push_scrollback_row(row, wrapped);
        }
    }

    /// Copy one visible row into scrollback, reusing the evicted row's cell
    /// allocation once the ring is full. Steady-state terminal output then
    /// performs no per-line allocation even though each history row remains
    /// independently owned.
    fn push_scrollback_row(&mut self, row: usize, wrapped: bool) {
        if self.scrollback_capacity == 0 {
            return;
        }

        let mut entry = if self.scrollback.len() >= self.scrollback_capacity {
            self.history_evicted += 1;
            self.scrollback.pop_front().unwrap()
        } else {
            ScrollbackRow {
                cells: Vec::with_capacity(self.cols),
                wrapped,
            }
        };

        let physical = self.phys(row);
        entry.cells.clear();
        entry.cells.extend_from_slice(&self.cells[physical]);
        entry.wrapped = wrapped;
        self.scrollback.push_back(entry);
    }

    /// Move a row into scrollback and install a recycled, blank row buffer in
    /// its place. Unlike [`Self::push_scrollback_row`], this is only for rows
    /// that are leaving the visible grid and therefore need not remain intact.
    fn archive_scrolled_row(&mut self, row: usize, wrapped: bool, blank: Cell) {
        let physical = self.phys(row);
        if self.scrollback_capacity == 0 {
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
        });
    }

    fn push_scrollback(&mut self, line: Vec<Cell>, wrapped: bool) {
        if self.scrollback_capacity == 0 {
            return;
        }
        if self.scrollback.len() >= self.scrollback_capacity {
            self.scrollback.pop_front();
            self.history_evicted += 1;
        }
        self.scrollback.push_back(ScrollbackRow { cells: line, wrapped });
    }

    /// Total number of scrollback lines that have been evicted (dropped)
    /// over the lifetime of this grid.
    #[inline]
    pub fn history_evicted(&self) -> usize {
        self.history_evicted
    }

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
        let kept: Vec<(Vec<Cell>, bool, SemanticPrompt)> = (0..min_rows)
            .map(|r| {
                (
                    self.row_slice(r).to_vec(),
                    self.is_line_wrapped(r),
                    self.row_semantic_prompt(r),
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
        self.dirty = vec![true; new_rows];
        self.row_may_have_wide = vec![false; new_rows];

        for (r, (old_row, wrapped, semantic)) in kept.into_iter().enumerate() {
            self.line_wrapped[r] = wrapped;
            self.row_semantic[r] = semantic;

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

    /// Number of lines currently retained in scrollback.
    pub fn scrollback_len(&self) -> usize {
        self.scrollback.len()
    }

    /// Fetch a scrollback line by distance from the bottom of scrollback
    /// (i.e. the line nearest the visible grid). `0` is the most-recently
    /// scrolled-off line, immediately above row 0 of the visible grid.
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
        self.scrollback.get(idx).map(|row| row.wrapped).unwrap_or(false)
    }

    /// Iterate scrollback lines oldest-first.
    pub fn scrollback_iter(&self) -> impl DoubleEndedIterator<Item = &[Cell]> {
        self.scrollback.iter().map(|row| row.cells.as_slice())
    }

    pub fn scrollback_capacity(&self) -> usize {
        self.scrollback_capacity
    }

    /// Changes how many lines of history the scrollback keeps. Shrinking it
    /// drops the oldest lines, counted as evicted like any other.
    pub fn set_scrollback_capacity(&mut self, capacity: usize) {
        while self.scrollback.len() > capacity {
            self.scrollback.pop_front();
            self.history_evicted += 1;
        }
        self.scrollback_capacity = capacity;
    }

    /// The grid's rows, borrowed in display order.
    ///
    /// [`Self::raw_parts`] answers the same question by deep-copying the whole
    /// grid, which is the right shape for a caller that needs owned data and
    /// exactly the wrong one for a caller that only walks it once. A
    /// serializer -- or a serializer that is only counting bytes -- is the
    /// second kind.
    pub fn row_cells(&self, row: usize) -> &[Cell] {
        self.row_slice(row)
    }

    /// The scrollback, borrowed oldest-first, with each row's wrap flag intact.
    pub fn scrollback_rows(&self) -> impl ExactSizeIterator<Item = &ScrollbackRow> {
        self.scrollback.iter()
    }

    /// Every cell that holds a grapheme cluster, as `(line, col, extra,
    /// wide)`: `line` counts the scrollback oldest-first and then the visible
    /// rows, `extra` is the cluster after the cell's `char`. What a
    /// checkpoint needs to rebuild the clusters; the table ids themselves
    /// mean nothing outside this grid.
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
    pub(crate) fn restore_cluster(&mut self, line: usize, col: usize, extra: &str, wide: bool) -> bool {
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
    ///
    /// Every `Vec` here keeps its allocation across a clear or a shrink, so a
    /// grid that was once 500 columns wide still owns those cells after a
    /// resize down to 80. Anything reasoning about resident memory -- as
    /// opposed to how many bytes a checkpoint of this grid would decode to --
    /// has to count what is held, not what is used.
    pub fn retained_capacity_bytes(&self) -> u64 {
        let cell = std::mem::size_of::<Cell>() as u64;
        let mut total: u64 = 0;
        // The row spine, then each row's own cell allocation.
        total = total.saturating_add(
            (self.cells.capacity() as u64).saturating_mul(std::mem::size_of::<Vec<Cell>>() as u64),
        );
        for row in &self.cells {
            total = total.saturating_add((row.capacity() as u64).saturating_mul(cell));
        }
        // Per-row metadata, parallel to `cells`.
        total = total.saturating_add(self.line_wrapped.capacity() as u64);
        total = total.saturating_add(
            (self.row_semantic.capacity() as u64)
                .saturating_mul(std::mem::size_of::<SemanticPrompt>() as u64),
        );
        total = total.saturating_add(self.dirty.capacity() as u64);
        total = total.saturating_add(self.row_may_have_wide.capacity() as u64);
        total = total.saturating_add(
            (self.row_slots.capacity() as u64).saturating_mul(std::mem::size_of::<usize>() as u64),
        );
        // Scrollback ring: its own spine, then each retained row.
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

    /// Resize the grid to `new_cols` x `new_rows`.
    ///
    /// If only the row count changes, rows are appended or removed without
    /// reflow. A shrink trims trailing blank rows before turning top rows into
    /// scrollback, matching Terminal.app: raising a software
    /// keyboard must not scroll a login banner away merely because the old
    /// screen had blank space below it.
    ///
    /// If the column count changes, all visible content (plus, best-effort,
    /// nothing from scrollback) is logically unwrapped along
    /// `line_wrapped` boundaries into logical lines, then rewrapped at the
    /// new width. This does not attempt to perfectly mirror upstream's
    /// page-based reflow algorithm — it favors simplicity and never losing
    /// data over exact fidelity.
    pub fn resize(&mut self, new_cols: usize, new_rows: usize) {
        self.resize_with_cursor(new_cols, new_rows, None);
    }

    /// Resize while keeping the active cursor row meaningful. A blank row at
    /// or above the cursor is never discarded as trailing padding. Returns
    /// Resize while keeping the active cursor row and column meaningful across
    /// row adjustments and width reflow.
    pub(crate) fn resize_with_cursor(
        &mut self,
        new_cols: usize,
        new_rows: usize,
        cursor: Option<(usize, usize)>,
    ) -> Option<(usize, usize)> {
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
            return active_cursor;
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

        struct LogicalLine {
            cells: Vec<Cell>,
            semantic: SemanticPrompt,
            cursor_offset: Option<usize>,
        }

        let mut logical_lines: Vec<LogicalLine> = Vec::new();
        for row in 0..self.rows {
            let wrapped = self.is_line_wrapped(row);
            let row_cells = self.row_slice(row);
            let semantic = self.row_semantic_prompt(row);
            let is_cursor_row = target_cursor_row == Some(row);

            if wrapped && !logical_lines.is_empty() {
                let last = logical_lines.last_mut().unwrap();
                let start_offset = last.cells.len();
                last.cells.extend_from_slice(row_cells);
                if is_cursor_row {
                    last.cursor_offset = Some(start_offset + target_cursor_col.unwrap_or(0));
                }
            } else {
                let cursor_offset = if is_cursor_row {
                    Some(target_cursor_col.unwrap_or(0))
                } else {
                    None
                };
                logical_lines.push(LogicalLine {
                    cells: row_cells.to_vec(),
                    semantic,
                    cursor_offset,
                });
            }
        }
        if logical_lines.is_empty() {
            logical_lines.push(LogicalLine {
                cells: Vec::new(),
                semantic: SemanticPrompt::Unset,
                cursor_offset: if target_cursor_row.is_some() {
                    Some(0)
                } else {
                    None
                },
            });
        }

        // Trailing blank content must not consume rows after the rewrap
        // (it would push real content into scrollback): drop trailing
        // all-blank logical lines, and trailing blanks inside each line.
        // spacer_head cells are reflow debris and are trimmed the same way.
        let is_blank =
            |cell: &Cell| (cell.char == '\0' || cell.is_wide_spacer_head) && !cell.is_wide_spacer;
        for line in logical_lines.iter_mut() {
            while line.cells.last().is_some_and(&is_blank) {
                line.cells.pop();
            }
        }
        while logical_lines.len() > 1
            && logical_lines
                .last()
                .is_some_and(|l| l.cells.is_empty() && l.cursor_offset.is_none())
        {
            logical_lines.pop();
        }

        struct NewRow {
            cells: Vec<Cell>,
            wrapped: bool,
            semantic: SemanticPrompt,
        }

        let mut new_rows_data: Vec<NewRow> = Vec::new();
        let mut final_cursor: Option<(usize, usize)> = None;

        for line in logical_lines {
            let (mut wrapped_rows, line_cursor) =
                Self::rewrap_line_with_cursor(&line.cells, new_cols, line.cursor_offset);
            if let Some((sub_r, sub_c)) = line_cursor {
                while wrapped_rows.len() <= sub_r {
                    wrapped_rows.push(vec![Cell::default(); new_cols]);
                }
                let global_row = new_rows_data.len() + sub_r;
                final_cursor = Some((global_row, sub_c));
            }
            for (i, row) in wrapped_rows.into_iter().enumerate() {
                let wrapped = i > 0;
                let semantic = if i == 0 {
                    line.semantic
                } else if line.semantic == SemanticPrompt::Prompt {
                    SemanticPrompt::PromptContinuation
                } else {
                    SemanticPrompt::Unset
                };
                new_rows_data.push(NewRow {
                    cells: row,
                    wrapped,
                    semantic,
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
        // Storage is rebuilt from scratch, so logical row 0 is physical
        // row 0 again.
        self.row_offset = 0;
        self.row_slots = (0..new_rows).collect();
        self.cells = vec![vec![Cell::default(); new_cols]; new_rows];
        self.line_wrapped = vec![false; new_rows];
        self.row_semantic = vec![SemanticPrompt::Unset; new_rows];
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
            self.row_may_have_wide[r] = self.cells[r]
                .iter()
                .any(|cell| cell.is_wide_spacer || cell.is_wide_spacer_head);
        }

        for row_data in scrollback_extra {
            self.push_scrollback(row_data.cells, row_data.wrapped);
        }

        final_cursor
    }

    fn resize_rows_only(
        &mut self,
        new_rows: usize,
        cursor: Option<(usize, usize)>,
    ) -> (usize, Option<(usize, usize)>) {
        use std::cmp::Ordering;
        if new_rows == self.rows {
            return (0, cursor);
        }
        // Splicing rows on/off the ends only makes sense on a non-rotated
        // buffer, and a resize already pays for a full pass anyway.
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
                    let old_dirty = std::mem::take(&mut self.dirty);
                    let old_wide = std::mem::take(&mut self.row_may_have_wide);

                    self.cells = Vec::with_capacity(new_rows);
                    self.line_wrapped = Vec::with_capacity(new_rows);
                    self.row_semantic = Vec::with_capacity(new_rows);
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
                        self.row_semantic.push(SemanticPrompt::Unset);
                        self.dirty.push(true);
                        self.row_may_have_wide.push(may_have_wide);
                    }

                    self.cells.extend(old_cells);
                    self.line_wrapped.extend(old_wrapped);
                    self.row_semantic.extend(old_semantic);
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
                self.dirty
                    .extend(std::iter::repeat_n(true, blank_rows));
                self.row_may_have_wide
                    .extend(std::iter::repeat_n(false, blank_rows));
                self.rows = new_rows;
                self.row_slots = (0..new_rows).collect();
                if restored_count > 0 {
                    self.mark_all_dirty();
                }
                let new_cursor = cursor.map(|(r, c)| {
                    (
                        r.saturating_add(restored_count).min(new_rows.saturating_sub(1)),
                        c.min(self.cols.saturating_sub(1)),
                    )
                });
                (restored_count, new_cursor)
            }
            Ordering::Less => {
                let removed = self.rows - new_rows;

                // Prefer deleting unused padding at the bottom. This is the
                // resize behaviour upstream deliberately shares with
                // Terminal.app. Without it, 41 rows followed by the software
                // keyboard's 24 rows pushes a banner at row zero into history
                // even though the bottom 17 rows are empty.
                let cursor_row = cursor.map(|(row, _)| row.min(self.rows.saturating_sub(1)));
                let mut trim_bottom = 0;
                while trim_bottom < removed {
                    let row = self.rows - trim_bottom - 1;
                    if cursor_row.is_some_and(|cursor| row <= cursor) {
                        break;
                    }
                    let has_text = self.row_slice(row).iter().any(|cell| cell.char != '\0');
                    let has_semantic_mark =
                        self.row_semantic_prompt(row) != SemanticPrompt::Unset;
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
                    self.dirty.truncate(kept);
                    self.row_may_have_wide.truncate(kept);
                    self.rows = kept;
                    self.row_slots = (0..kept).collect();
                }

                let remove_top = removed - trim_bottom;
                // Any remainder really does leave through the top, so retain
                // it in scrollback in top-to-bottom order, like scroll_up.
                for row in 0..remove_top {
                    let line: Vec<Cell> = self.row_slice(row).to_vec();
                    let wrapped = self.is_line_wrapped(row);
                    self.push_scrollback(line, wrapped);
                }
                self.cells.drain(0..remove_top);
                self.line_wrapped.drain(0..remove_top);
                // The per-row metadata vectors must stay exactly `rows`
                // long and aligned with the rows they describe.
                self.row_semantic.drain(0..remove_top);
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

    /// Split one logical line into `new_cols`-wide rows while carrying an
    /// optional logical cursor offset through the reflow.
    fn rewrap_line_with_cursor(
        logical: &[Cell],
        new_cols: usize,
        cursor_offset: Option<usize>,
    ) -> (Vec<Vec<Cell>>, Option<(usize, usize)>) {
        if logical.is_empty() {
            let cursor_pos = cursor_offset.map(|offset| {
                let r = offset / new_cols;
                let c = offset % new_cols;
                (r, c)
            });
            return (vec![vec![Cell::default(); new_cols]], cursor_pos);
        }
        let mut out: Vec<Vec<Cell>> = Vec::new();
        let mut row: Vec<Cell> = Vec::with_capacity(new_cols);
        let mut cursor_pos: Option<(usize, usize)> = None;
        let mut i = 0;
        while i < logical.len() {
            // A wide cell and its spacer are one glyph, so they advance
            // together and can never straddle a reflow boundary.
            let paired = !logical[i].is_wide_spacer
                && matches!(logical.get(i + 1), Some(next) if next.is_wide_spacer);
            let width = if paired { 2 } else { 1 };

            if width > new_cols {
                // Too narrow to hold the pair at all: keep the wide half
                // and drop the spacer rather than emit an orphan spacer.
                if !row.is_empty() {
                    row.resize(new_cols, Cell::default());
                    out.push(std::mem::take(&mut row));
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
            && cursor_pos.is_none() {
                let extra = target_offset.saturating_sub(logical.len());
                let current_sub_row = out.len();
                let current_sub_col = row.len();
                let total_col = current_sub_col + extra;
                let sub_row = current_sub_row + total_col / new_cols;
                let sub_col = total_col % new_cols;
                cursor_pos = Some((sub_row, sub_col));
            }

        if !row.is_empty() {
            row.resize(new_cols, Cell::default());
            out.push(row);
        }
        (out, cursor_pos)
    }
}

#[cfg(test)]
mod tests;
