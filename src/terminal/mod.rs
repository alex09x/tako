// The terminal state machine: modes, cursor, selection, the alternate screen.

use std::collections::HashMap;

use crate::charset::{self, Charset};
use crate::cursor_style::CursorStyle;
use crate::graphics::{GraphicsResponse, GraphicsState};
use crate::grid::{Cell, CellAttrs, Color, Grid};
use crate::kitty_keyboard::{KittyFlags, KittyKeyboardState};
use crate::modes::TerminalModes;
use crate::palette::{self, Palette};
use crate::parser::{Parser, Perform};
use crate::response::{self, ResponseQueue};
use crate::tabstops::TabStops;
use crate::title_stack::TitleStack;

pub mod checksum;
pub mod checkpoint;
mod dsr;
mod dump;
mod select;

#[cfg(test)]
mod tests;

/// Which screen buffer is currently active.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenBuffer {
    Primary,
    Alternate,
}

/// A cursor position + pending SGR state snapshot, as saved by DECSC (`ESC
/// 7`) / `CSI s` and restored by DECRC (`ESC 8`) / `CSI u`.
#[derive(Debug, Clone, Copy)]
pub struct SavedCursor {
    pub row: usize,
    pub col: usize,
    pub fg: Color,
    pub bg: Color,
    pub attrs: CellAttrs,
    pub g0: Charset,
    pub g1: Charset,
    pub shift_out: bool,
    pub origin_mode: bool,
    pub pending_wrap: bool,
    pub protected_mode: ProtectedMode,
    pub gr_slot: u8,
}

/// Cursor position plus the SGR state that gets applied to newly-printed
/// cells.
#[derive(Debug, Clone)]
pub struct Cursor {
    pub row: usize,
    pub col: usize,
    pub fg: Color,
    pub bg: Color,
    pub attrs: CellAttrs,
    pub underline_style: u8,
    pub underline_color: Color,
    pub saved: Option<SavedCursor>,
}

/// How a selection's anchor/active points determine which cells are
/// included when extracting text.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SelectionMode {
    /// Normal click-drag: selects from the anchor to the active point
    /// following text flow, wrapping across rows.
    Linear,
    /// Block/column selection: selects the rectangle bounded by the
    /// anchor's and active point's row/col extents -- the same column
    /// range on every row, regardless of content.
    Rectangular,
}

/// An in-progress or completed text selection.
///
/// `anchor` is where the selection began (mouse-down); `active` is where
/// it currently ends (mouse-drag position). Which one comes first in
/// reading order doesn't matter -- [`Terminal::selection_range`] and
/// [`Terminal::selected_text`] normalize the pair before use, so dragging
/// backward (bottom-to-top or right-to-left) still extracts the same text
/// as dragging forward over the same span.
///
/// Coordinates are lifetime document positions, so a selection remains
/// meaningful while the viewport scrolls and older scrollback is evicted.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Selection {
    pub anchor: (usize, usize),
    pub active: (usize, usize),
    pub mode: SelectionMode,
}

impl Default for Cursor {
    fn default() -> Self {
        Self {
            row: 0,
            col: 0,
            fg: Color::Default,
            bg: Color::Default,
            attrs: CellAttrs::empty(),
            underline_style: 0,
            underline_color: Color::Default,
            saved: None,
        }
    }
}

/// Which DCS command is currently being accumulated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DcsKind {
    /// DECRQSS: `DCS $ q <setting> ST` -- report a setting's value.
    Decrqss,
    /// XTGETTCAP: `DCS + q <hex names> ST` -- terminfo capability query.
    XtGetTcap,
}

/// The cursor's OSC 133 semantic mode: what kind of content prints next.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SemanticContent {
    #[default]
    None,
    Prompt,
    Input,
    Output,
}

/// Host-visible side effects the byte stream produced: things the embedding
/// application must react to (ring the bell, sync the clipboard, ...).
/// Drained via [`Terminal::take_events`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalEvent {
    Bell,
    TitleChanged(String),
    /// OSC 52 set: decoded clipboard text the host should store.
    ClipboardSet(String),
    /// OSC 52 query: the host should reply with its clipboard contents.
    ClipboardQuery,
    /// OSC 9 / OSC 777;notify desktop notification.
    Notification { title: String, body: String },
    /// OSC 7: working-directory URL report.
    PwdChanged(String),
    /// ConEmu OSC 9;4 progress report (state 0=remove,1=set,2=error,
    /// 3=indeterminate,4=pause); `value` is absent when not sent.
    Progress { state: u8, value: Option<u8> },
    /// OSC 133;C -- the shell handed control to a command. A host can start
    /// timing here.
    CommandStart,
    /// OSC 133;D -- the command finished. `exit_code` is present when the
    /// shell reported one (`OSC 133;D;<code>`).
    CommandEnd { exit_code: Option<i32> },
}

/// Which flavor of character protection the pen is currently applying
/// (DECSCA sets DEC-style, SPA/EPA set ISO-style). The most recent setter
/// wins; plain erases respect only ISO protection, selective erases
/// (DECSED/DECSEL) respect both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtectedMode {
    Off,
    Iso,
    Dec,
}

/// How many columns a grapheme cluster takes (upstream's
/// `grapheme-width-method`): the default for mode 2027, which a program can
/// still set or reset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum GraphemeWidthMethod {
    /// A cluster takes its presentation width: an emoji sequence (VS16, ZWJ,
    /// skin tone, flag) is two columns, VS15 text presentation one. Mode
    /// 2027 on.
    #[default]
    Unicode,
    /// Each codepoint takes its own wcwidth; zero-width codepoints still join
    /// the cluster before them. Mode 2027 off.
    Legacy,
}

/// A Kitty Graphics Protocol placement, positioned at the cursor location
/// it was displayed at. `graphics::Placement` is deliberately grid-agnostic
/// (see its docs), so screen position is tracked here instead.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GraphicsPlacement {
    pub image_id: u32,
    pub placement_id: u32,
    pub row: usize,
    pub col: usize,
}

/// Terminal state machine: owns a primary and alternate [`Grid`], a
/// [`Cursor`], a scroll region, and drives a [`Parser`] over incoming bytes.
///
/// `feed` is the only entry point FFI callers need for input; the rest of
/// the public API is read-only accessors for rendering plus `resize`.
pub struct Terminal {
    pub(crate) primary: Grid,
    pub(crate) alternate: Grid,
    pub(crate) active: ScreenBuffer,
    pub(crate) cursor: Cursor,
    pub(crate) scroll_top: usize,
    pub(crate) scroll_bottom: usize,
    /// Left/right scroll margins (DECSLRM), 0-based inclusive. Full width
    /// unless narrowed while DECLRMM (mode 69) is enabled.
    pub(crate) scroll_left: usize,
    pub(crate) scroll_right: usize,
    pub(crate) title: String,
    pub(crate) cursor_visible: bool,
    pub(crate) parser: Parser,
    /// Hyperlink table: numeric id (as stamped onto `Cell::hyperlink`) to
    /// URI. The id is just the index into this `Vec`.
    pub(crate) hyperlinks: Vec<String>,
    /// Maps an OSC 8 explicit `id=...` param to the numeric hyperlink id it
    /// was first assigned, so re-opening the same explicit id (with a run
    /// of plain text in between) resolves to the same numeric id instead of
    /// growing the table unboundedly.
    pub(crate) hyperlink_ids: HashMap<String, u32>,
    /// The hyperlink id currently open via OSC 8, if any. Stamped onto
    /// every cell `print()`s while set, mirroring how `cursor.fg`/`bg`/
    /// `attrs` are stamped onto printed cells.
    pub(crate) current_hyperlink: Option<u32>,
    /// The current text selection, if any. Coordinates are into the
    /// active grid's visible viewport; see [`Selection`].
    pub(crate) selection: Option<Selection>,
    /// G0 character set, selected via SI (Ctrl-O) or by default.
    pub(crate) g0: Charset,
    /// G1 character set, selected via SO (Ctrl-N).
    pub(crate) g1: Charset,
    pub(crate) g2: Charset,
    pub(crate) g3: Charset,
    /// `true` once SO has shifted printing to `g1`; SI shifts back.
    pub(crate) shift_out: bool,
    /// GR slot selected via LS1R/LS2R/LS3R, tracked for parity.
    pub(crate) gr_slot: u8,
    /// One-shot single-shift charset (SS2/SS3) for the next glyph only.
    pub(crate) single_shift: Option<Charset>,
    pub(crate) tabstops: TabStops,
    pub(crate) kitty_keyboard: KittyKeyboardState,
    /// Bytes queued by DA/DSR/XTVERSION/Kitty-keyboard-query replies, drained
    /// by the FFI layer and written back to the PTY.
    pub(crate) response: ResponseQueue,
    /// XTCHECKSUM (`CSI Ps # y`) extension bits applied to DECRQCRA. Zero is
    /// DEC behaviour; see [`checksum::ext`].
    pub(crate) checksum_ext: u16,
    pub(crate) modes: TerminalModes,
    pub(crate) graphics: GraphicsState,
    /// Where each live Kitty Graphics placement was displayed.
    pub(crate) graphics_placements: Vec<GraphicsPlacement>,
    pub(crate) cursor_style: CursorStyle,
    /// The host's cursor style (its config's cursor-style), which DECSCUSR 0
    /// and a reset return to.
    pub(crate) default_cursor_style: CursorStyle,
    /// Whether a program chose the cursor style with DECSCUSR since the last
    /// reset; while it has not, a new host default applies at once.
    pub(crate) cursor_style_overridden: bool,
    pub(crate) palette: Palette,
    pub(crate) title_stack: TitleStack,
    /// The last character `print()` wrote, for REP (`CSI Ps b`).
    pub(crate) last_printed_char: Option<char>,
    /// Current pen protection mode (DECSCA / SPA / EPA).
    pub(crate) protected_mode: ProtectedMode,
    /// Host-visible side effects queued for [`Self::take_events`].
    pub(crate) events: Vec<TerminalEvent>,
    /// ENQ (0x05) answerback string; empty by default.
    pub(crate) answerback: String,
    /// XTVERSION reply name; host-overridable.
    pub(crate) xtversion: String,
    /// Text-area pixel dimensions from the host, for XTWINOPS reports.
    pub(crate) width_px: u32,
    pub(crate) height_px: u32,
    /// Host-reported color scheme for `CSI ? 996 n` queries; `None`
    /// (unconfigured) stays silent, like upstream's absent callback.
    pub(crate) dark_scheme: Option<bool>,
    /// OSC 133 semantic mode of subsequently printed content.
    pub(crate) semantic_content: SemanticContent,
    /// Viewport offset into scrollback: 0 = bottom (live screen), N = N
    /// lines up. Any print/scroll snaps it back to the bottom.
    pub(crate) viewport_offset: usize,
    /// Active DCS command (from `hook`), and its accumulated payload.
    pub(crate) dcs: Option<DcsKind>,
    pub(crate) dcs_buf: Vec<u8>,
    /// Live default fg/bg/cursor colors: the host base (tracked on
    /// `palette`, alongside its indexed-color base) until a program
    /// overrides them via OSC 10/11/12.
    pub(crate) default_fg: Option<(u8, u8, u8)>,
    pub(crate) default_bg: Option<(u8, u8, u8)>,
    pub(crate) cursor_color: Option<(u8, u8, u8)>,
    /// xterm's deferred-wrap state: printing in the last column parks the
    /// cursor there and only the NEXT printable character triggers the
    /// wrap. Reset by anything that moves the cursor.
    pub(crate) pending_wrap: bool,
    /// The host's grapheme-width-method: mode 2027's power-on value.
    pub(crate) grapheme_width_method: GraphemeWidthMethod,
}

impl Terminal {
    pub fn new(cols: usize, rows: usize) -> Self {
        Self::with_scrollback(cols, rows, crate::grid::DEFAULT_SCROLLBACK_CAPACITY)
    }

    /// Export the complete terminal state as a native versioned binary checkpoint.
    ///
    /// Fails rather than emitting a checkpoint this build could not read back:
    /// the invariant callers depend on is that a successful export is
    /// importable under the same version and limits. A failed export has not
    /// touched the terminal -- nothing truncated, cleared or reset.
    pub fn export_checkpoint(&self) -> Result<Vec<u8>, checkpoint::CheckpointError> {
        checkpoint::export(self)
    }

    /// [`Self::export_checkpoint`] with a caller-supplied byte cap. The
    /// effective limit is `min(max_bytes, checkpoint::MAX_CONTAINER_LEN)`, or the
    /// ceiling alone when `max_bytes` is 0, and it bounds the whole container
    /// including its header.
    pub fn export_checkpoint_limited(
        &self,
        max_bytes: u64,
    ) -> Result<Vec<u8>, checkpoint::CheckpointError> {
        checkpoint::export_limited(self, max_bytes)
    }

    /// [`Self::export_checkpoint_limited`] in a chosen container version (0 for
    /// the current one), for a peer that reads no newer. See
    /// [`checkpoint::export_version`].
    pub fn export_checkpoint_version(
        &self,
        version: u32,
        max_bytes: u64,
    ) -> Result<Vec<u8>, checkpoint::CheckpointError> {
        checkpoint::export_version(self, version, max_bytes)
    }

    /// How many bytes [`Self::export_checkpoint_version`] would produce.
    pub fn measure_checkpoint_version(
        &self,
        version: u32,
        max_bytes: u64,
    ) -> Result<u64, checkpoint::CheckpointError> {
        checkpoint::measure_version(self, version, max_bytes)
    }

    /// How many bytes [`Self::export_checkpoint`] would produce, without
    /// producing them.
    pub fn measure_checkpoint(&self) -> Result<u64, checkpoint::CheckpointError> {
        checkpoint::measure(self)
    }

    /// [`Self::measure_checkpoint`] bounded by a caller-supplied byte cap,
    /// mirroring [`Self::export_checkpoint_limited`].
    pub fn measure_checkpoint_limited(
        &self,
        max_bytes: u64,
    ) -> Result<u64, checkpoint::CheckpointError> {
        checkpoint::measure_limited(self, max_bytes)
    }

    /// The checkpoint container version this build writes.
    pub fn checkpoint_version() -> u32 {
        checkpoint::version()
    }

    /// Whether this build can import that container version.
    pub fn checkpoint_supports(version: u32) -> bool {
        checkpoint::supports(version)
    }

    /// Header and geometry of a checkpoint, without decoding it.
    pub fn inspect_checkpoint(
        data: &[u8],
    ) -> Result<checkpoint::CheckpointInfo, checkpoint::CheckpointError> {
        checkpoint::inspect(data)
    }

    /// Restore the terminal state from a native checkpoint.
    ///
    /// Validates magic, format version, CRC32 checksum, dimensions, and payload integrity.
    /// Restoration is atomic: if validation or decoding fails, `self` is
    /// unmodified.
    ///
    /// The replacement is built *beside* the terminal it replaces -- `self` is
    /// not freed until the assignment -- so both are live at the peak, and the
    /// allocation budget is charged for both. A checkpoint that a fresh
    /// `Terminal` would accept can therefore be refused here, with `self`
    /// intact, rather than admitted into a process that is already holding the
    /// destination.
    pub fn import_checkpoint(&mut self, data: &[u8]) -> Result<(), checkpoint::CheckpointError> {
        // The destination stays live across the import, and so does the
        // container the caller handed us. What the destination costs is what it
        // has *reserved*, not what a checkpoint of it would decode to: a
        // cleared 8 MiB OSC buffer still occupies 8 MiB while reporting a
        // length of zero, and that memory is live for the whole import.
        let reserved = checkpoint::retained_cost(self).saturating_add(data.len() as u64);
        let mut restored = checkpoint::import_reserving(data, reserved)?;
        restored.set_grapheme_width_method(self.grapheme_width_method);
        *self = restored;
        Ok(())
    }

    /// Verify the integrity and version of a native checkpoint without mutating state.
    pub fn verify_checkpoint(data: &[u8]) -> bool {
        checkpoint::verify(data)
    }

    /// Like [`Self::new`] with an explicit scrollback line limit.
    pub fn with_scrollback(cols: usize, rows: usize, scrollback: usize) -> Self {
        let cols = cols.max(1);
        let rows = rows.max(1);
        Self {
            primary: Grid::with_scrollback_capacity(cols, rows, scrollback),
            // The alternate screen never accumulates scrollback (upstream).
            alternate: Grid::with_scrollback_capacity(cols, rows, 0),
            active: ScreenBuffer::Primary,
            cursor: Cursor::default(),
            scroll_top: 0,
            scroll_bottom: rows.saturating_sub(1),
            scroll_left: 0,
            scroll_right: cols.saturating_sub(1),
            title: String::new(),
            cursor_visible: true,
            parser: Parser::new(),
            hyperlinks: Vec::new(),
            hyperlink_ids: HashMap::new(),
            current_hyperlink: None,
            selection: None,
            g0: Charset::Ascii,
            g1: Charset::Ascii,
            g2: Charset::Ascii,
            g3: Charset::Ascii,
            shift_out: false,
            gr_slot: 0,
            single_shift: None,
            tabstops: TabStops::new(cols),
            kitty_keyboard: KittyKeyboardState::new(),
            response: ResponseQueue::new(),
            checksum_ext: 0,
            modes: TerminalModes::new(),
            graphics: GraphicsState::new(),
            graphics_placements: Vec::new(),
            cursor_style: CursorStyle::new(),
            default_cursor_style: CursorStyle::new(),
            cursor_style_overridden: false,
            palette: Palette::new(),
            title_stack: TitleStack::new(),
            last_printed_char: None,
            protected_mode: ProtectedMode::Off,
            events: Vec::new(),
            answerback: String::new(),
            xtversion: "tako".to_string(),
            width_px: 0,
            height_px: 0,
            dark_scheme: None,
            semantic_content: SemanticContent::None,
            viewport_offset: 0,
            dcs: None,
            dcs_buf: Vec::new(),
            default_fg: None,
            default_bg: None,
            cursor_color: None,
            pending_wrap: false,
            grapheme_width_method: GraphemeWidthMethod::Unicode,
        }
    }

    /// Feed raw bytes (as read from a PTY) through the ANSI parser, driving
    /// terminal state changes.
    pub fn feed(&mut self, bytes: &[u8]) {
        // Pull the parser out of `self` so we can pass `self` as the
        // `Perform` implementor without an overlapping borrow.
        let mut parser = std::mem::take(&mut self.parser);
        parser.advance_bytes(self, bytes);
        self.parser = parser;
    }

    /// Resize both the primary and alternate grids, clamp the cursor into
    /// bounds, and reset the scroll region to the full new screen.
    pub fn resize(&mut self, cols: usize, rows: usize) {
        // A zero dimension is rejected outright (upstream errors here);
        // clamping it to 1 would silently destroy the grid's contents.
        if cols == 0 || rows == 0 {
            return;
        }
        // Upstream rebuilds tabstops from scratch (Tabstops.init, which
        // resets to the default every-8 interval) whenever the column
        // count changes, rather than resizing the old bitset in place.
        // `TabStops::resize` alone just grows/shrinks the Vec, preserving
        // old positions and leaving newly exposed columns with NO stop at
        // all -- so shrinking to a handful of columns and growing back
        // (exactly what happens once, briefly, during a fresh window's
        // AppKit layout pass) permanently loses every default tabstop.
        // `\t` then has nowhere to land short of the last column, which is
        // instantly visible on anything that leans on tabs for alignment
        // (a real TUI app's redraw, say) -- found live via exactly that.
        let cols_changed = cols != self.active_grid().cols();
        let cursor_pos = (self.cursor.row, self.cursor.col);
        let new_cursor = if self.modes.autowrap {
            match self.active {
                ScreenBuffer::Primary => {
                    let pos = self.primary.resize_with_cursor(cols, rows, Some(cursor_pos));
                    self.alternate.resize_with_cursor(cols, rows, None);
                    pos
                }
                ScreenBuffer::Alternate => {
                    self.primary.resize_with_cursor(cols, rows, None);
                    self.alternate.resize_with_cursor(cols, rows, Some(cursor_pos))
                }
            }
        } else {
            // With wraparound off, rows never soft-wrap: truncate/pad
            // instead of reflowing (upstream behavior).
            self.primary.resize_no_reflow(cols, rows);
            self.alternate.resize_no_reflow(cols, rows);
            Some((
                self.cursor.row.min(rows.saturating_sub(1)),
                self.cursor.col.min(cols.saturating_sub(1)),
            ))
        };
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
        // A selection referencing now-out-of-bounds coordinates would be a
        // bug once the grid shrinks; clamp both endpoints back into the
        // new bounds rather than dropping the selection outright.
        if let Some(sel) = self.selection.as_mut() {
            let clamp = |(r, c): (usize, usize)| (r, c.min(cols.saturating_sub(1)));
            sel.anchor = clamp(sel.anchor);
            sel.active = clamp(sel.active);
        }
        self.viewport_offset = self.viewport_offset.min(self.active_grid().scrollback_len());
    }

    /// Convert a viewport row/col coordinate to a lifetime document coordinate.
    fn viewport_to_lifetime_coord(&self, viewport_row: usize, col: usize) -> (usize, usize) {
        let grid = self.active_grid();
        let rows = grid.rows();
        let cols = grid.cols();
        let scrollback_len = grid.scrollback_len();
        let total_rows = scrollback_len + rows;

        let c = col.min(cols.saturating_sub(1));

        let vp_top_abs = scrollback_len.saturating_sub(self.viewport_offset);
        // Normal pointer input is within the viewport.  Keeping an endpoint
        // just beyond it is also intentional: a host can extend a drag while
        // it autoscrolls, and clamping it to the viewport's final row silently
        // truncates a selection that spans retained scrollback.  Bound it by
        // the retained document instead, so malformed/out-of-view host input
        // remains safe without losing the selected tail.
        let abs_row = vp_top_abs
            .saturating_add(viewport_row)
            .min(total_rows.saturating_sub(1));
        let lifetime_row = grid.history_evicted() + abs_row;
        (lifetime_row, c)
    }

    /// Begin a new selection at viewport `(row, col)`, setting both `anchor` and `active`
    /// to its lifetime document position.
    pub fn start_selection(&mut self, row: usize, col: usize, mode: SelectionMode) {
        let pos = self.viewport_to_lifetime_coord(row, col);
        self.selection = Some(Selection {
            anchor: pos,
            active: pos,
            mode,
        });
    }

    /// Update the active (drag) endpoint of the current selection from viewport `(row, col)`.
    /// No-op if no selection has been started.
    pub fn extend_selection(&mut self, row: usize, col: usize) {
        let pos = self.viewport_to_lifetime_coord(row, col);
        if let Some(sel) = self.selection.as_mut() {
            sel.active = pos;
        }
    }

    /// Discard the current selection.
    pub fn clear_selection(&mut self) {
        self.selection = None;
    }

    /// Selection mode of the current selection, or [`SelectionMode::Linear`].
    pub fn selection_mode(&self) -> SelectionMode {
        self.selection.map(|s| s.mode).unwrap_or(SelectionMode::Linear)
    }

    /// Whether a selection is currently active and overlaps retained history/screen.
    pub fn has_selection(&self) -> bool {
        self.current_selection_retained_bounds().is_some()
    }

    /// Returns current selection bounds `(mode, (start_abs_row, start_col), (end_abs_row, end_col))`
    /// in retained document coordinates (where `abs_row = 0` is the oldest retained line),
    /// after clamping/dropping evicted lines.
    fn current_selection_retained_bounds(
        &self,
    ) -> Option<(SelectionMode, (usize, usize), (usize, usize))> {
        let sel = self.selection?;
        let grid = self.active_grid();
        let rows = grid.rows();
        let cols = grid.cols();
        let scrollback_len = grid.scrollback_len();
        let total_rows = scrollback_len + rows;
        if total_rows == 0 || cols == 0 {
            return None;
        }

        let evicted = grid.history_evicted();
        let min_retained_lt = evicted;
        let max_retained_lt = evicted + total_rows - 1;

        match sel.mode {
            SelectionMode::Linear => {
                let (start_lt, end_lt) = if sel.anchor <= sel.active {
                    (sel.anchor, sel.active)
                } else {
                    (sel.active, sel.anchor)
                };

                if end_lt.0 < min_retained_lt || start_lt.0 > max_retained_lt {
                    return None;
                }

                let (start_abs_row, start_col) = if start_lt.0 < min_retained_lt {
                    (0, 0)
                } else {
                    (start_lt.0 - evicted, start_lt.1.min(cols - 1))
                };

                let (end_abs_row, end_col) = if end_lt.0 > max_retained_lt {
                    (total_rows - 1, cols - 1)
                } else {
                    (end_lt.0 - evicted, end_lt.1.min(cols - 1))
                };

                Some((SelectionMode::Linear, (start_abs_row, start_col), (end_abs_row, end_col)))
            }
            SelectionMode::Rectangular => {
                let min_lt_row = sel.anchor.0.min(sel.active.0);
                let max_lt_row = sel.anchor.0.max(sel.active.0);
                let min_col = sel.anchor.1.min(sel.active.1).min(cols - 1);
                let max_col = sel.anchor.1.max(sel.active.1).min(cols - 1);

                if max_lt_row < min_retained_lt || min_lt_row > max_retained_lt {
                    return None;
                }

                let start_abs_row = if min_lt_row < min_retained_lt {
                    0
                } else {
                    min_lt_row - evicted
                };
                let end_abs_row = (max_lt_row.saturating_sub(evicted)).min(total_rows - 1);

                Some((SelectionMode::Rectangular, (start_abs_row, min_col), (end_abs_row, max_col)))
            }
        }
    }

    /// The viewport-relative `(start, end)` bounds of the current selection for rendering highlight,
    /// or `None` if no selection exists or if the selection does not overlap the visible viewport.
    pub fn selection_range(&self) -> Option<((usize, usize), (usize, usize))> {
        let (mode, (start_abs_row, start_col), (end_abs_row, end_col)) =
            self.current_selection_retained_bounds()?;
        let grid = self.active_grid();
        let rows = grid.rows();
        let scrollback_len = grid.scrollback_len();

        let vp_top_abs = scrollback_len.saturating_sub(self.viewport_offset);
        let vp_bottom_abs = vp_top_abs + rows.saturating_sub(1);

        match mode {
            SelectionMode::Linear => {
                if end_abs_row < vp_top_abs || start_abs_row > vp_bottom_abs {
                    return None;
                }

                let eff_start_abs = if start_abs_row < vp_top_abs {
                    (vp_top_abs, 0)
                } else {
                    (start_abs_row, start_col)
                };

                let eff_end_abs = if end_abs_row > vp_bottom_abs {
                    (vp_bottom_abs, grid.cols().saturating_sub(1))
                } else {
                    (end_abs_row, end_col)
                };

                let v_start_row = eff_start_abs.0 - vp_top_abs;
                let v_start_col = eff_start_abs.1;
                let v_end_row = eff_end_abs.0 - vp_top_abs;
                let v_end_col = eff_end_abs.1;

                Some(((v_start_row, v_start_col), (v_end_row, v_end_col)))
            }
            SelectionMode::Rectangular => {
                if end_abs_row < vp_top_abs || start_abs_row > vp_bottom_abs {
                    return None;
                }

                let eff_min_row = start_abs_row.max(vp_top_abs);
                let eff_max_row = end_abs_row.min(vp_bottom_abs);

                let v_start_row = eff_min_row - vp_top_abs;
                let v_end_row = eff_max_row - vp_top_abs;

                Some(((v_start_row, start_col), (v_end_row, end_col)))
            }
        }
    }

    /// Check if absolute row `abs_row` soft-wraps into `abs_row + 1`.
    pub fn is_line_wrapped_abs(&self, abs_row: usize) -> bool {
        let grid = self.active_grid();
        let scrollback_len = grid.scrollback_len();
        let rows = grid.rows();
        let total_rows = scrollback_len + rows;
        if abs_row >= total_rows {
            return false;
        }
        if abs_row < scrollback_len {
            let idx = (scrollback_len - 1) - abs_row;
            grid.scrollback_line_wrapped(idx)
        } else {
            let live_row = abs_row - scrollback_len;
            grid.is_line_wrapped(live_row)
        }
    }

    /// Extract the text covered by the current selection in document coordinates, or `None` if
    /// there is no selection.
    pub fn selected_text(&self) -> Option<String> {
        let (mode, (start_abs_row, start_col), (end_abs_row, end_col)) =
            self.current_selection_retained_bounds()?;
        let grid = self.active_grid();
        let cols = grid.cols();
        let scrollback_len = grid.scrollback_len();

        let abs_row_text = |abs_row: usize, from: usize, to: usize| -> String {
            let mut line = String::new();
            for col in from..=to {
                let cell = if abs_row < scrollback_len {
                    let idx = (scrollback_len - 1) - abs_row;
                    grid.scrollback_line(idx)
                        .and_then(|l| l.get(col).copied())
                        .unwrap_or_default()
                } else {
                    let live_row = abs_row - scrollback_len;
                    grid.get(live_row, col).copied().unwrap_or_default()
                };
                // A wide glyph occupies two cells and the second carries no
                // character of its own; the stub left behind when one could
                // not fit before a wrap carries none either. Emitting a
                // space for them put one between every pair of CJK
                // characters that was copied out of the terminal.
                if cell.is_wide_spacer || cell.is_wide_spacer_head {
                    continue;
                }
                grid.push_cell_text(&mut line, &cell);
            }
            line
        };

        match mode {
            SelectionMode::Linear => {
                let mut out = String::new();
                for abs_row in start_abs_row..=end_abs_row {
                    let from = if abs_row == start_abs_row { start_col } else { 0 };
                    let to = if abs_row == end_abs_row { end_col } else { cols.saturating_sub(1) };
                    let mut line = abs_row_text(abs_row, from, to);

                    let wraps_to_next = self.is_line_wrapped_abs(abs_row + 1);
                    if !wraps_to_next {
                        let trimmed_len = line.trim_end().len();
                        line.truncate(trimmed_len);
                    }

                    out.push_str(&line);
                    if abs_row != end_abs_row && !wraps_to_next {
                        out.push('\n');
                    }
                }
                Some(out)
            }
            SelectionMode::Rectangular => {
                let mut lines: Vec<String> = Vec::new();
                for abs_row in start_abs_row..=end_abs_row {
                    let mut line = abs_row_text(abs_row, start_col, end_col);
                    let trimmed_len = line.trim_end().len();
                    line.truncate(trimmed_len);
                    lines.push(line);
                }
                Some(lines.join("\n"))
            }
        }
    }

    /// The grid currently shown on screen (primary or alternate).
    pub fn active_grid(&self) -> &Grid {
        match self.active {
            ScreenBuffer::Primary => &self.primary,
            ScreenBuffer::Alternate => &self.alternate,
        }
    }

    fn active_grid_mut(&mut self) -> &mut Grid {
        match self.active {
            ScreenBuffer::Primary => &mut self.primary,
            ScreenBuffer::Alternate => &mut self.alternate,
        }
    }

    /// Which screen buffer is active.
    pub fn active_screen(&self) -> ScreenBuffer {
        self.active
    }

    /// Current cursor position as `(row, col)`, both 0-indexed.
    pub fn cursor(&self) -> (usize, usize) {
        (self.cursor.row, self.cursor.col)
    }

    pub fn cursor_visible(&self) -> bool {
        self.cursor_visible
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    /// Resolve a hyperlink id (as found on `Cell::hyperlink`) to its URI.
    /// Returns `None` if `id` is out of range, which shouldn't happen for
    /// ids that actually came from this `Terminal`'s cells.
    /// Drains and returns any queued device-reply bytes (DA/DSR/XTVERSION/
    /// Kitty-keyboard-query responses) for the caller to write back to the
    /// PTY.
    pub fn take_output(&mut self) -> Vec<u8> {
        self.response.take()
    }

    /// Host configuration: ENQ answerback string.
    pub fn set_answerback(&mut self, s: &str) {
        self.answerback = s.to_string();
    }

    /// Host configuration: the XTVERSION reply name.
    pub fn set_xtversion(&mut self, s: &str) {
        self.xtversion = s.to_string();
    }

    /// Host configuration: light/dark scheme for `CSI ? 996 n` reports.
    pub fn set_dark_scheme(&mut self, dark: bool) {
        self.dark_scheme = Some(dark);
    }

    /// Resize with the text area's pixel dimensions (enables XTWINOPS
    /// 14/16 size reports). Zero pixel values keep the previous ones.
    pub fn resize_with_pixels(&mut self, cols: usize, rows: usize, width_px: u32, height_px: u32) {
        if width_px > 0 {
            self.width_px = width_px;
        }
        if height_px > 0 {
            self.height_px = height_px;
        }
        self.resize(cols, rows);
    }

    /// Resize given a cell's pixel size: text-area pixels are derived by
    /// saturating multiplication, like upstream.
    pub fn resize_with_cell_size(&mut self, cols: usize, rows: usize, cell_w: u32, cell_h: u32) {
        self.width_px = (cols as u32).saturating_mul(cell_w);
        self.height_px = (rows as u32).saturating_mul(cell_h);
        self.resize(cols, rows);
    }

    /// Current text-area pixel dimensions (0 until the host reports them).
    pub fn pixel_size(&self) -> (u32, u32) {
        (self.width_px, self.height_px)
    }

    /// The GR charset slot selected via LS1R/LS2R/LS3R (0 = none).
    pub fn gr_slot(&self) -> u8 {
        self.gr_slot
    }

    /// Scroll the viewport up (into scrollback) by `n` lines, clamped to
    /// the amount of scrollback available.
    pub fn scroll_viewport_up(&mut self, n: usize) {
        let max = self.active_grid().scrollback_len();
        self.viewport_offset = (self.viewport_offset + n).min(max);
        self.active_grid_mut().mark_all_dirty();
    }

    /// Scroll the viewport back down toward the live screen.
    pub fn scroll_viewport_down(&mut self, n: usize) {
        self.viewport_offset = self.viewport_offset.saturating_sub(n);
        self.active_grid_mut().mark_all_dirty();
    }

    /// Snap the viewport back to the live screen bottom.
    /// No-op (and no mark_all_dirty penalty) when already at offset 0.
    pub fn scroll_viewport_bottom(&mut self) {
        if self.viewport_offset == 0 {
            return;
        }
        self.viewport_offset = 0;
        self.active_grid_mut().mark_all_dirty();
    }

    /// Changes how many lines of history the primary screen keeps (the
    /// alternate screen keeps none). Shrinking it drops the oldest lines and
    /// pulls a viewport that was further back than that to the oldest line
    /// left.
    pub fn set_scrollback_capacity(&mut self, lines: usize) {
        self.primary.set_scrollback_capacity(lines);
        let retained = self.active_grid().scrollback_len();
        if self.viewport_offset > retained {
            self.viewport_offset = retained;
        }
        self.active_grid_mut().mark_all_dirty();
    }

    /// Current viewport offset in lines above the live screen.
    pub fn viewport_offset(&self) -> usize {
        self.viewport_offset
    }

    /// Where the viewport sits as a fraction: 0 is the oldest retained line,
    /// 1 is the live screen.
    ///
    /// Hosts persist and restore a scroll position across view teardown, and
    /// a line count is the wrong thing to persist -- scrollback is evicted,
    /// so yesterday's line 4000 is not today's. A fraction survives that,
    /// and is the shape UIKit and SwiftUI both want anyway.
    ///
    /// With no scrollback there is nowhere to be but the bottom, so the
    /// answer is 1 rather than a division by zero.
    pub fn scroll_position(&self) -> f64 {
        let max = self.active_grid().scrollback_len();
        if max == 0 {
            return 1.0;
        }
        1.0 - (self.viewport_offset as f64 / max as f64)
    }

    /// Moves the viewport to a fraction returned by [`Self::scroll_position`].
    /// Values outside 0...1 are clamped rather than rejected, because the
    /// caller is usually restoring a number it stored some time ago.
    pub fn set_scroll_position(&mut self, position: f64) {
        let max = self.active_grid().scrollback_len();
        if max == 0 {
            self.scroll_viewport_bottom();
            return;
        }
        let clamped = position.clamp(0.0, 1.0);
        let offset = ((1.0 - clamped) * max as f64).round() as usize;
        let offset = offset.min(max);
        if offset == self.viewport_offset {
            return;
        }
        self.viewport_offset = offset;
        self.active_grid_mut().mark_all_dirty();
    }

    /// The cells of a viewport row, accounting for the scrollback offset:
    /// rows above the live screen come from scrollback.
    pub fn viewport_row(&self, row: usize) -> Vec<Cell> {
        let grid = self.active_grid();
        let cols = grid.cols();
        if self.viewport_offset == 0 {
            return (0..cols)
                .map(|c| grid.get(row, c).copied().unwrap_or_default())
                .collect();
        }
        if row < self.viewport_offset {
            // Scrollback line: index 0 is the line just above the screen.
            let idx = self.viewport_offset - 1 - row;
            if let Some(line) = grid.scrollback_line(idx) {
                let mut out: Vec<Cell> = line.to_vec();
                out.resize(cols, Cell::default());
                return out;
            }
            return vec![Cell::default(); cols];
        }
        let screen_row = row - self.viewport_offset;
        (0..cols)
            .map(|c| grid.get(screen_row, c).copied().unwrap_or_default())
            .collect()
    }

    /// Whether a viewport row is a soft-wrapped continuation of the row
    /// above it. This mirrors [`Self::viewport_row`]: history rows carry the
    /// wrap bit archived with them, while rows at the bottom come from the
    /// live grid. Text accessibility must use the same mapping as rendering
    /// or VoiceOver describes a different screen after the user scrolls.
    pub fn viewport_line_wrapped(&self, row: usize) -> bool {
        let grid = self.active_grid();
        if self.viewport_offset == 0 {
            return grid.is_line_wrapped(row);
        }
        if row < self.viewport_offset {
            let idx = self.viewport_offset - 1 - row;
            return grid.scrollback_line_wrapped(idx);
        }
        grid.is_line_wrapped(row - self.viewport_offset)
    }

    /// Rows that changed since the last call, as a bitmap of viewport row
    /// indices; clears the flags so the host redraws only what moved.
    /// A scroll or resize reports every row.
    pub fn take_damage(&mut self) -> Vec<u32> {
        // Mode 2026 (Synchronized Output): a redrawing app wraps its whole
        // frame in `CSI ?2026h ... CSI ?2026l` specifically so a host never
        // repaints midway through. Reporting no damage (without clearing
        // the underlying dirty flags -- see `Grid::mark_dirty`) while it's
        // set means the eventual post-`?2026l` call reports everything that
        // changed during the whole bracket at once, as one clean redraw,
        // instead of the host catching it dirty mid-sequence. Found via a
        // real TUI app (agy) whose dropdown-menu redraw showed exactly that:
        // stale/overlapping text from a state that was never meant to be
        // visible on its own.
        if self.modes.synchronized_output {
            return Vec::new();
        }
        let rows = self.active_grid().rows();
        let mut out = Vec::new();
        for row in 0..rows {
            if self.active_grid().is_dirty(row) {
                out.push(row as u32);
            }
        }
        self.active_grid_mut().clear_dirty();
        out
    }

    /// Whether `take_damage` would currently report at least one row,
    /// WITHOUT draining the damage flags. Mirrors `take_damage`'s
    /// Synchronized Output rule: mid-frame (mode 2026 open) there is
    /// nothing the host may paint yet, so this reports `false` even though
    /// rows are dirty underneath.
    pub fn has_damage(&self) -> bool {
        if self.modes.synchronized_output {
            return false;
        }
        self.active_grid().has_dirty()
    }

    /// Force a full redraw on the next `take_damage` (host raised a new
    /// window, changed fonts, ...).
    pub fn mark_all_damaged(&mut self) {
        self.active_grid_mut().mark_all_dirty();
    }

    /// The cursor's current OSC 133 semantic mode.
    pub fn semantic_content(&self) -> SemanticContent {
        self.semantic_content
    }

    /// Whether the cursor sits on a prompt row (OSC 133). Never true on
    /// the alternate screen.
    pub fn cursor_is_at_prompt(&self) -> bool {
        if self.active == ScreenBuffer::Alternate {
            return false;
        }
        matches!(
            self.active_grid().row_semantic_prompt(self.cursor.row),
            crate::grid::SemanticPrompt::Prompt | crate::grid::SemanticPrompt::PromptContinuation
        )
    }

    /// Drains queued host-visible events (bell, clipboard, notifications).
    pub fn take_events(&mut self) -> Vec<TerminalEvent> {
        std::mem::take(&mut self.events)
    }

    /// Live default fg / bg / cursor colors: the host base (if any) until a
    /// program overrides them via OSC 10/11/12.
    pub fn default_colors(&self) -> (Option<(u8, u8, u8)>, Option<(u8, u8, u8)>, Option<(u8, u8, u8)>) {
        (self.default_fg, self.default_bg, self.cursor_color)
    }

    /// Host-configured base fg / bg / cursor colors, set through
    /// `set_base_colors`. `None` per-slot means the host hasn't configured
    /// one for that slot.
    pub fn base_colors(&self) -> (Option<(u8, u8, u8)>, Option<(u8, u8, u8)>, Option<(u8, u8, u8)>) {
        (self.palette.base_fg(), self.palette.base_bg(), self.palette.base_cursor())
    }

    /// Sets the host's base fg / bg / cursor colors and base palette
    /// entries. Base colors are what OSC 104 / 110 / 111 / 112 and RIS
    /// restore to, and what OSC 4 / 10 / 11 / 12 queries report until a
    /// program overrides them.
    ///
    /// A slot passed as `None` reverts that base to unconfigured (the
    /// built-in default for the palette, or silence for fg/bg/cursor
    /// queries -- matching the engine's behavior before a host ever calls
    /// this). Updating a base immediately updates the live value too,
    /// unless a program already overrode it since the last reset -- so a
    /// theme change applies right away without clobbering a program's
    /// explicit colors.
    pub fn set_base_colors(
        &mut self,
        fg: Option<(u8, u8, u8)>,
        bg: Option<(u8, u8, u8)>,
        cursor: Option<(u8, u8, u8)>,
        palette: &[(u8, (u8, u8, u8))],
    ) {
        self.palette.set_base_fg(fg);
        if !self.palette.fg_overridden() {
            self.default_fg = fg;
        }
        self.palette.set_base_bg(bg);
        if !self.palette.bg_overridden() {
            self.default_bg = bg;
        }
        self.palette.set_base_cursor(cursor);
        if !self.palette.cursor_overridden() {
            self.cursor_color = cursor;
        }
        for &(index, rgb) in palette {
            self.palette.set_base(index, rgb);
        }
    }

    /// A power-on terminal of the same size that keeps what the host
    /// configured -- its base colors, default cursor style and scrollback
    /// limit -- the way a program's RIS keeps them.
    /// For a host-side "reset terminal", which must not drop the theme.
    pub fn fresh_keeping_host_config(&self) -> Terminal {
        let grid = self.active_grid();
        let mut fresh = Terminal::new(grid.cols(), grid.rows());
        let (fg, bg, cursor) = self.base_colors();
        let palette: Vec<(u8, (u8, u8, u8))> =
            (0..=255u8).map(|index| (index, self.palette.base(index))).collect();
        fresh.set_base_colors(fg, bg, cursor, &palette);
        fresh.set_default_cursor_style(self.default_cursor_style);
        fresh.set_scrollback_capacity(self.primary.scrollback_capacity());
        fresh.set_grapheme_width_method(self.grapheme_width_method);
        fresh
    }

    /// Sets the host's grapheme-width-method: mode 2027 takes its value now,
    /// and again on every reset.
    pub fn set_grapheme_width_method(&mut self, method: GraphemeWidthMethod) {
        self.grapheme_width_method = method;
        self.modes.grapheme_cluster = method == GraphemeWidthMethod::Unicode;
    }

    /// The host's grapheme-width-method.
    pub fn grapheme_width_method(&self) -> GraphemeWidthMethod {
        self.grapheme_width_method
    }

    /// A codepoint that continues the grapheme cluster before the cursor
    /// joins that cluster's cell instead of taking a column of its own.
    /// Reports whether `c` was taken care of: joined to the cluster, or --
    /// a zero-width codepoint with no cluster to join, like a zero-width
    /// space -- dropped.
    ///
    /// A mark with a precomposed form (e + U+0301 is é, the way macOS spells
    /// file names) folds into the character (NFC). Under mode 2027 any
    /// codepoint that continues the cluster joins it -- a ZWJ sequence's
    /// next emoji, a skin tone, a flag's second regional indicator -- and the
    /// cell widens or narrows to the cluster's presentation width; without
    /// it only zero-width codepoints join and the width stays the first
    /// codepoint's (upstream's legacy method).
    fn join_previous_cluster(&mut self, c: char) -> bool {
        // Ordinary text -- CJK, box drawing, most emoji -- is never zero width
        // and skips the width lookup.
        let plain = crate::grid::always_breaks(c);
        let zero_width = !plain && unicode_width::UnicodeWidthChar::width(c) == Some(0);
        let unicode = self.modes.grapheme_cluster;
        if !zero_width && !unicode {
            return false;
        }
        let row = self.cursor.row;
        // With a deferred wrap pending the cursor still sits on the cell it
        // just wrote; otherwise that cell is the one to its left.
        let previous = if self.pending_wrap {
            Some(self.cursor.col)
        } else {
            self.cursor.col.checked_sub(1)
        };
        let grid = self.active_grid();
        let target = previous.and_then(|mut col| {
            if col > 0 && grid.get(row, col).is_some_and(|cell| cell.is_wide_spacer) {
                col -= 1;
            }
            let cell = *grid.get(row, col)?;
            let has_text = cell.char != '\0' && !cell.is_wide_spacer && !cell.is_wide_spacer_head;
            has_text.then_some((col, cell))
        });
        let Some((col, mut cell)) = target else {
            return zero_width;
        };
        let extra = grid.grapheme(&cell);
        if !crate::grid::continues_cluster(cell.char, extra, c) {
            return zero_width;
        }
        if extra.is_empty()
            && let Some(composed) = unicode_normalization::char::compose(cell.char, c)
        {
            cell.char = composed;
            self.active_grid_mut().set(row, col, cell);
            return true;
        }
        if extra.len() + c.len_utf8() > crate::grid::MAX_EXTRA_BYTES {
            return true;
        }
        let mut joined = String::with_capacity(extra.len() + c.len_utf8());
        joined.push_str(extra);
        joined.push(c);
        let was_wide = grid.cell_is_wide(&cell);
        let wide = if unicode {
            crate::grid::unicode_cluster_is_wide(cell.char, &joined)
        } else {
            was_wide
        };
        let id = self.active_grid_mut().intern_grapheme(&joined, wide);
        if id == 0 {
            // The table is full of live clusters: the cell keeps what it had.
            return true;
        }
        cell.grapheme = id;
        match (was_wide, wide) {
            (false, true) => self.widen_cluster(row, col, cell),
            (true, false) => self.narrow_cluster(row, col, cell),
            _ => self.active_grid_mut().set(row, col, cell),
        }
        true
    }

    /// Rewrites the narrow cell at `(row, col)` as the two-column `cell`,
    /// wrapping it to the next line first when its spacer would not fit
    /// (upstream's VS16 handling).
    fn widen_cluster(&mut self, row: usize, col: usize, cell: Cell) {
        let cols = self.active_grid().cols();
        let (left, right) = self.h_margins();
        let right_bound = if col <= right { right } else { cols - 1 };
        let (mut row, mut col) = (row, col);
        if col >= right_bound {
            if !self.modes.autowrap || right_bound < left + 1 {
                return;
            }
            let leftover = if right_bound + 1 == cols {
                Cell {
                    char: ' ',
                    is_wide_spacer_head: true,
                    bg: cell.bg,
                    hyperlink: cell.hyperlink,
                    protected: cell.protected,
                    ..Cell::default()
                }
            } else {
                self.bce_blank()
            };
            self.active_grid_mut().set(row, col, leftover);
            self.cursor.col = left;
            self.line_feed();
            row = self.cursor.row;
            col = left;
            if right_bound + 1 == cols {
                self.active_grid_mut().set_line_wrapped(row, true);
            }
        }
        self.dissolve_wide_pair_at(row, col);
        self.dissolve_wide_pair_at(row, col + 1);
        self.active_grid_mut().set_wide(row, col, cell);
        if col + 1 >= right_bound {
            self.cursor.col = right_bound;
            self.pending_wrap = self.modes.autowrap;
        } else {
            self.cursor.col = col + 2;
            self.pending_wrap = false;
        }
    }

    /// Rewrites the two-column cell at `(row, col)` as the one-column `cell`
    /// and gives back the column its spacer held (upstream's VS15 handling).
    fn narrow_cluster(&mut self, row: usize, col: usize, cell: Cell) {
        let spacer = self.active_grid().get(row, col + 1).copied();
        self.active_grid_mut().set(row, col, cell);
        if let Some(spacer) = spacer.filter(|spacer| spacer.is_wide_spacer) {
            let freed = Cell {
                char: '\0',
                is_wide_spacer: false,
                ..spacer
            };
            self.active_grid_mut().set(row, col + 1, freed);
        }
        if self.pending_wrap {
            self.pending_wrap = false;
        } else {
            self.cursor.col = self.cursor.col.saturating_sub(1);
        }
    }

    /// Sets the host's cursor style: what DECSCUSR 0 and a reset return to.
    /// It applies at once unless a program has chosen a style since the last
    /// reset.
    pub fn set_default_cursor_style(&mut self, style: CursorStyle) {
        self.default_cursor_style = style;
        if !self.cursor_style_overridden {
            self.cursor_style = style;
        }
    }

    /// Currently live Kitty Graphics placements, in display order.
    pub fn graphics_placements(&self) -> &[GraphicsPlacement] {
        &self.graphics_placements
    }

    /// Current DEC private-mode state (autowrap, origin mode, mouse
    /// tracking, bracketed paste, focus events, ...).
    pub fn modes(&self) -> &TerminalModes {
        &self.modes
    }

    /// Whether an app-initiated Synchronized Output frame (mode 2026) is
    /// currently open. `take_damage` already refuses to report anything
    /// mid-frame, but a host's OWN periodic redraw triggers unrelated to
    /// PTY activity -- a cursor blink timer, for instance -- don't go
    /// through `take_damage` at all, so they need this to know not to
    /// paint a real, unfinished frame either.
    pub fn is_synchronized_output(&self) -> bool {
        self.modes.synchronized_output
    }

    /// Whether a deferred wrap is armed (xterm pending-wrap state): the
    /// last print parked the cursor on the final column. Exposed for tests
    /// ported from upstream, which assert this directly.
    pub fn pending_wrap(&self) -> bool {
        self.pending_wrap
    }

    /// The Kitty keyboard protocol's currently active progressive-
    /// enhancement flags, as a raw bitmask (see `kitty_keyboard::KittyFlags`).
    pub fn kitty_keyboard_flags(&self) -> u8 {
        self.kitty_keyboard.current().bits()
    }

    /// The stored image for `id`, if any.
    pub fn graphics_image(&self, id: u32) -> Option<&crate::graphics::StoredImage> {
        self.graphics.image(id)
    }

    /// The active 256-color indexed palette (customizable via OSC 4/104).
    pub fn palette(&self) -> &Palette {
        &self.palette
    }

    /// Plain-text dump of the active screen, mirroring upstream's
    /// `plainString` test helper: soft-wrapped rows are joined into one
    /// logical line, trailing blanks are trimmed per line, trailing empty
    /// lines are dropped, and wide-char spacer cells are skipped. Exists so
    /// tests ported 1:1 from upstream can assert the same expected strings.
    pub fn plain_string(&self) -> String {
        let grid = self.active_grid();
        let mut rows: Vec<String> = Vec::new();
        for row in 0..grid.rows() {
            let viewport = self.viewport_row(row);
            let mut line = String::new();
            for cell in viewport.iter() {
                if cell.is_wide_spacer {
                    continue;
                }
                grid.push_cell_text(&mut line, cell);
            }
            while line.ends_with(' ') {
                line.pop();
            }
            rows.push(line);
        }
        while rows.last().is_some_and(|l| l.is_empty()) {
            rows.pop();
        }
        rows.join("\n")
    }

    /// Like [`Self::plain_string`], but soft-wrapped rows are joined into
    /// one logical line (upstream's `plainStringUnwrapped`).
    pub fn plain_string_unwrapped(&self) -> String {
        let grid = self.active_grid();
        let mut logical: Vec<String> = Vec::new();
        let mut current = String::new();
        for row in 0..grid.rows() {
            for col in 0..grid.cols() {
                let Some(cell) = grid.get(row, col) else { continue };
                // Wide tails collapse into their head; a spacer head is
                // reflow padding, not text, so it collapses too.
                if cell.is_wide_spacer || cell.is_wide_spacer_head {
                    continue;
                }
                grid.push_cell_text(&mut current, cell);
            }
            if row + 1 == grid.rows() || !grid.is_line_wrapped(row + 1) {
                logical.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            logical.push(current);
        }
        for line in logical.iter_mut() {
            while line.ends_with(' ') {
                line.pop();
            }
        }
        while logical.last().is_some_and(|l| l.is_empty()) {
            logical.pop();
        }
        logical.join("\n")
    }

    /// The current cursor shape/blink style (DECSCUSR).
    pub fn cursor_style(&self) -> CursorStyle {
        self.cursor_style
    }

    pub fn hyperlink_uri(&self, id: u32) -> Option<&str> {
        // Ids are 1-based (id 0 is never handed out), matching upstream.
        self.hyperlinks
            .get((id as usize).checked_sub(1)?)
            .map(String::as_str)
    }

    /// Move the cursor down one row, scrolling the scroll region up (via
    /// [`Grid::scroll_up`] when the region spans the whole screen, or via a
    /// manual row shift for a partial region) if the cursor is at the
    /// bottom of the scroll region. Does not touch `cursor.col`. Shared by
    /// `execute('\n')` and `print`'s end-of-line wrap.
    /// Current horizontal margins, clamped to the grid width.
    fn h_margins(&self) -> (usize, usize) {
        let cols = self.active_grid().cols();
        (
            self.scroll_left.min(cols.saturating_sub(1)),
            self.scroll_right.min(cols.saturating_sub(1)),
        )
    }

    /// Whether the horizontal margins span the full grid width.
    fn h_margins_full(&self) -> bool {
        let (left, right) = self.h_margins();
        left == 0 && right + 1 == self.active_grid().cols()
    }

    /// The blank cell used by erases and scroll-ins: keeps the active
    /// background color (BCE), everything else default.
    fn bce_blank(&self) -> Cell {
        Cell {
            bg: self.cursor.bg,
            ..Cell::default()
        }
    }

    /// Overwriting either half of a wide+spacer pair dissolves the whole
    /// pair, so the surviving half never lingers as a corrupt orphan.
    #[inline]
    fn dissolve_wide_pair_at(&mut self, row: usize, col: usize) {
        if !self.active_grid().row_may_have_wide(row) {
            return;
        }
        let (is_spacer, next_is_spacer) = {
            let grid = self.active_grid();
            (
                grid.get(row, col).map(|c| c.is_wide_spacer).unwrap_or(false),
                grid.get(row, col + 1).map(|c| c.is_wide_spacer).unwrap_or(false),
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

    fn line_feed(&mut self) {
        self.pending_wrap = false;
        let rows = self.active_grid().rows();
        let bottom = self.scroll_bottom.min(rows.saturating_sub(1));
        let mark_continuation = matches!(
            self.semantic_content,
            SemanticContent::Prompt | SemanticContent::Input
        );
        if self.cursor.row == bottom {
            // At the bottom margin: scroll only when inside the horizontal
            // margins, mirroring reverse_index.
            let (hl, hr) = self.h_margins();
            if self.cursor.col >= hl && self.cursor.col <= hr {
                self.scroll_region_up(1);
            }
        } else if self.cursor.row + 1 < rows {
            self.cursor.row += 1;
        }
        if mark_continuation {
            // Fish-shell workaround: continuation lines carry no marker of
            // their own, so a newline inside a prompt marks the new row.
            let row = self.cursor.row;
            self.active_grid_mut()
                .set_row_semantic_prompt(row, crate::grid::SemanticPrompt::PromptContinuation);
        }
    }

    /// Move the cursor up one row (RI / reverse index), scrolling the
    /// scroll region down if the cursor is at the top of the region.
    fn reverse_index(&mut self) {
        self.pending_wrap = false;
        let top = self.scroll_top;
        if self.cursor.row == top {
            // At the top margin: scroll only when the cursor is inside the
            // horizontal margins; outside them RI does nothing (upstream).
            let (hl, hr) = self.h_margins();
            if self.cursor.col >= hl && self.cursor.col <= hr {
                self.scroll_region_down(1);
            }
        } else if self.cursor.row > 0 {
            self.cursor.row -= 1;
        }
    }

    /// Scroll the scroll region `[scroll_top, scroll_bottom]` up by `n`
    /// lines. When the region is the whole screen this pushes lines into
    /// scrollback via `Grid::scroll_up`; a partial region just discards the
    /// lines scrolled off the top of the region (nothing above row 0 of the
    /// visible screen ever enters scrollback).
    fn scroll_region_up(&mut self, n: usize) {
        let scrollback_before = self.active_grid().scrollback_len();
        self.scroll_region_up_inner(n);
        self.keep_viewport_anchored(scrollback_before);
    }

    /// Switches the active screen buffer, returning the viewport to the live
    /// screen.
    ///
    /// A scrollback offset belongs to the buffer it was taken on. The
    /// alternate screen has no scrollback at all, so carrying one across
    /// leaves a full-screen app -- vim, codex, an editor -- drawing into a
    /// window scrolled off its own screen. Coming back the other way, the
    /// user expects to land where the shell is, not where they had scrolled
    /// to some minutes earlier.
    ///
    /// This was previously masked: output used to reset the offset on every
    /// printed character, so the first thing an app drew cleared it as a side
    /// effect.
    fn switch_screen(&mut self, to: ScreenBuffer) {
        self.active = to;
        self.viewport_offset = 0;
    }

    /// Keeps a scrolled-back viewport on the text it was showing as lines
    /// enter scrollback.
    ///
    /// The offset is measured from the live screen, so each line pushed into
    /// scrollback moves that anchor one line further from what the user was
    /// reading -- leaving the offset alone makes the content slide upward
    /// under a stationary window, which is indistinguishable from following
    /// the tail. Growing the offset by the same amount cancels it out.
    ///
    /// A viewport already at the bottom is left alone: it is meant to follow.
    /// Once scrollback is full the correction runs out, because the lines
    /// being read are the ones being evicted; the clamp keeps that safe
    /// rather than pretending otherwise.
    fn keep_viewport_anchored(&mut self, scrollback_before: usize) {
        if self.viewport_offset == 0 {
            return;
        }
        let now = self.active_grid().scrollback_len();
        let grown = now.saturating_sub(scrollback_before);
        if grown == 0 {
            return;
        }
        self.viewport_offset = (self.viewport_offset + grown).min(now);
        // The rows the viewport reads from have rotated even though the text
        // they show has not, so the renderer is told to replan. This costs a
        // full repaint per scrolled line, which only happens while the user
        // is scrolled back and therefore not otherwise driving frames.
        self.active_grid_mut().mark_all_dirty();
    }

    fn scroll_region_up_inner(&mut self, n: usize) {
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

        let full_width = self.h_margins_full();
        // A partial-height region anchored at the top of the screen still
        // feeds scrollback -- its lines leave the screen the same way a
        // full-screen scroll's do (upstream behavior).
        if top == 0 && full_width {
            self.active_grid_mut().stash_top_rows(n);
        }
        // Full-width vertical regions can rotate row identities just like
        // upstream's hot DECSTBM path. Content outside the region
        // stays mapped to the same physical rows and no visible cells move.
        if full_width {
            let blank = self.bce_blank();
            self.active_grid_mut()
                .scroll_region_up_with_blank(top, bottom, n, blank);
            return;
        }
        if n < region_height {
            for row in top..=(bottom - n) {
                for col in left..=right {
                    let cell = self.active_grid().get(row + n, col).copied().unwrap_or_default();
                    self.active_grid_mut().set(row, col, cell);
                }
            }
        }
        let blank = self.bce_blank();
        for row in (bottom + 1 - n)..=bottom {
            self.active_grid_mut().fill_cells(row, left, right + 1, blank);
        }
        for row in top..=bottom {
            self.fix_wide_orphans(row);
        }
        self.fix_spacer_heads();
    }

    /// Scroll the scroll region `[scroll_top, scroll_bottom]` down by `n`
    /// lines (used by reverse index). Lines pushed off the bottom of the
    /// region are simply discarded.
    fn scroll_region_down(&mut self, n: usize) {
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

        if n < region_height {
            for row in (top + n..=bottom).rev() {
                for col in left..=right {
                    let cell = self.active_grid().get(row - n, col).copied().unwrap_or_default();
                    self.active_grid_mut().set(row, col, cell);
                }
                if full_width {
                    let wrapped = self.active_grid().is_line_wrapped(row - n);
                    self.active_grid_mut().set_line_wrapped(row, wrapped);
                }
            }
        }
        let blank = self.bce_blank();
        for row in top..(top + n) {
            self.active_grid_mut().fill_cells(row, left, right + 1, blank);
            if full_width {
                self.active_grid_mut().set_line_wrapped(row, false);
            }
        }
        if !full_width {
            for row in top..=bottom {
                self.fix_wide_orphans(row);
            }
        }
        self.fix_spacer_heads();
    }

    fn erase_in_display(&mut self, mode: u16) {
        // Plain ED honors only ISO (SPA) protection; DEC (DECSCA) protection
        // is honored solely by DECSED.
        let respect = self.protected_mode == ProtectedMode::Iso;
        self.erase_in_display_protected(mode, respect);
    }

    fn erase_in_display_protected(&mut self, mode: u16, respect: bool) {
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        let blank = self.bce_blank();
        match mode {
            0 => {
                let row = self.cursor.row;
                let col = self.cursor.col;
                self.active_grid_mut().fill_cells_respecting(row, col, cols, blank, respect);
                for r in (row + 1)..rows {
                    self.active_grid_mut().fill_cells_respecting(r, 0, cols, blank, respect);
                    self.active_grid_mut().set_line_wrapped(r, false);
                }
            }
            1 => {
                let row = self.cursor.row;
                let col = self.cursor.col;
                for r in 0..row {
                    self.active_grid_mut().fill_cells_respecting(r, 0, cols, blank, respect);
                    self.active_grid_mut().set_line_wrapped(r, false);
                }
                self.active_grid_mut()
                    .fill_cells_respecting(row, 0, col.saturating_add(1), blank, respect);
            }
            2 | 3 => {
                for r in 0..rows {
                    self.active_grid_mut().fill_cells_respecting(r, 0, cols, blank, respect);
                    self.active_grid_mut().set_line_wrapped(r, false);
                }
            }
            _ => {}
        }
    }

    fn erase_in_line(&mut self, mode: u16) {
        let respect = self.protected_mode == ProtectedMode::Iso;
        self.erase_in_line_protected(mode, respect);
    }

    fn erase_in_line_protected(&mut self, mode: u16, respect: bool) {
        let row = self.cursor.row;
        let col = self.cursor.col;
        let cols = self.active_grid().cols();
        let blank = self.bce_blank();
        match mode {
            0 => self
                .active_grid_mut()
                .fill_cells_respecting(row, col, cols, blank, respect),
            1 => self
                .active_grid_mut()
                .fill_cells_respecting(row, 0, col.saturating_add(1), blank, respect),
            2 => self
                .active_grid_mut()
                .fill_cells_respecting(row, 0, cols, blank, respect),
            _ => {}
        }
    }

    fn insert_lines(&mut self, n: usize) {
        if n == 0 || self.cursor.row < self.scroll_top || self.cursor.row > self.scroll_bottom {
            return;
        }
        // IL is a no-op when the cursor is outside the horizontal margins.
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        // IL homes the cursor to the left margin (xterm behavior).
        self.cursor.col = hl;
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
                    let cell = self.active_grid().get(row, col).copied().unwrap_or_default();
                    self.active_grid_mut().set(row + n, col, cell);
                }
                if full_width {
                    let wrapped = self.active_grid().is_line_wrapped(row);
                    self.active_grid_mut().set_line_wrapped(row + n, wrapped);
                }
            }
        }
        let blank = self.bce_blank();
        for row in top..(top + n) {
            self.active_grid_mut().fill_cells(row, hl, hr + 1, blank);
            if full_width {
                self.active_grid_mut().set_line_wrapped(row, false);
            }
        }
        if full_width {
            // The row now at the region bottom lost its continuation.
            self.active_grid_mut().set_line_wrapped(bottom, false);
        } else {
            for row in top..=bottom {
                self.fix_wide_orphans(row);
            }
        }
    }

    fn delete_lines(&mut self, n: usize) {
        if n == 0 || self.cursor.row < self.scroll_top || self.cursor.row > self.scroll_bottom {
            return;
        }
        // DL is a no-op when the cursor is outside the horizontal margins.
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        // DL homes the cursor to the left margin (xterm behavior).
        self.cursor.col = hl;
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
                    let cell = self.active_grid().get(row + n, col).copied().unwrap_or_default();
                    self.active_grid_mut().set(row, col, cell);
                }
                if full_width {
                    let wrapped = self.active_grid().is_line_wrapped(row + n);
                    self.active_grid_mut().set_line_wrapped(row, wrapped);
                }
            }
        }
        let blank = self.bce_blank();
        for row in (bottom + 1 - n)..=bottom {
            self.active_grid_mut().fill_cells(row, hl, hr + 1, blank);
            if full_width {
                self.active_grid_mut().set_line_wrapped(row, false);
            }
        }
        if !full_width {
            for row in top..=bottom {
                self.fix_wide_orphans(row);
            }
        }
        self.fix_spacer_heads();
    }

    /// DECIC: insert `n` blank columns at the cursor, shifting columns
    /// right within the margin box. No-op when the cursor is outside it.
    fn insert_columns(&mut self, n: usize) {
        let (hl, hr) = self.h_margins();
        let (top, bottom) = (self.scroll_top, self.scroll_bottom.min(self.active_grid().rows().saturating_sub(1)));
        if self.cursor.col < hl || self.cursor.col > hr || self.cursor.row < top || self.cursor.row > bottom {
            return;
        }
        self.pending_wrap = false;
        let start = self.cursor.col;
        let n = n.min(hr + 1 - start);
        let blank = self.bce_blank();
        for row in top..=bottom {
            for col in (start..=hr.saturating_sub(n)).rev() {
                let cell = self.active_grid().get(row, col).copied().unwrap_or_default();
                self.active_grid_mut().set(row, col + n, cell);
            }
            for col in start..(start + n).min(hr + 1) {
                self.active_grid_mut().set(row, col, blank);
            }
            self.fix_wide_orphans(row);
        }
    }

    /// DECDC: delete `n` columns at the cursor, shifting columns left
    /// within the margin box. No-op when the cursor is outside it.
    fn delete_columns(&mut self, n: usize) {
        let (hl, hr) = self.h_margins();
        let (top, bottom) = (self.scroll_top, self.scroll_bottom.min(self.active_grid().rows().saturating_sub(1)));
        if self.cursor.col < hl || self.cursor.col > hr || self.cursor.row < top || self.cursor.row > bottom {
            return;
        }
        self.pending_wrap = false;
        let start = self.cursor.col;
        let n = n.min(hr + 1 - start);
        let blank = self.bce_blank();
        for row in top..=bottom {
            for col in start..=hr {
                let cell = if col + n <= hr {
                    self.active_grid().get(row, col + n).copied().unwrap_or_default()
                } else {
                    blank
                };
                self.active_grid_mut().set(row, col, cell);
            }
            self.fix_wide_orphans(row);
        }
    }

    /// DECBI: back-index -- cursor left, or scroll the box right by one
    /// column when already on the left margin.
    fn back_index(&mut self) {
        self.pending_wrap = false;
        let (hl, _) = self.h_margins();
        if self.cursor.col == hl {
            let saved = self.cursor.col;
            self.cursor.col = hl;
            self.insert_columns(1);
            self.cursor.col = saved;
        } else {
            self.cursor.col = self.cursor.col.saturating_sub(1);
        }
    }

    /// DECFI: forward-index -- cursor right, or scroll the box left by one
    /// column when already on the right margin.
    fn forward_index(&mut self) {
        self.pending_wrap = false;
        let (hl, hr) = self.h_margins();
        if self.cursor.col == hr {
            let saved = self.cursor.col;
            self.cursor.col = hl;
            self.delete_columns(1);
            self.cursor.col = saved;
        } else {
            self.cursor.col = (self.cursor.col + 1).min(self.active_grid().cols().saturating_sub(1));
        }
    }

    /// A spacer head is only meaningful while the row below still starts
    /// with the wide glyph it made room for; otherwise it degrades into an
    /// ordinary blank cell (upstream converts it the same way).
    fn fix_spacer_heads(&mut self) {
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        if cols == 0 {
            return;
        }
        for row in 0..rows {
            let has_head = self
                .active_grid()
                .get(row, cols - 1)
                .map(|c| c.is_wide_spacer_head)
                .unwrap_or(false);
            if !has_head {
                continue;
            }
            let grid = self.active_grid();
            let next_starts_wide = row + 1 < rows
                && grid
                    .get(row + 1, 0)
                    .is_some_and(|c| !c.is_wide_spacer && grid.cell_is_wide(c));
            if !next_starts_wide
                && let Some(cell) = self.active_grid_mut().get_mut(row, cols - 1) {
                    cell.is_wide_spacer_head = false;
                }
        }
    }

    /// Repair wide-pair invariants on `row` after a horizontal shift: a
    /// wide head (width >= 2 char) must be followed by its spacer, and a
    /// spacer must follow a wide head -- any orphaned half becomes a blank.
    fn fix_wide_orphans(&mut self, row: usize) {
        let cols = self.active_grid().cols();
        for col in 0..cols {
            let (is_wide, is_spacer) = {
                let grid = self.active_grid();
                let Some(cell) = grid.get(row, col) else { continue };
                (grid.cell_is_wide(cell), cell.is_wide_spacer)
            };
            if is_spacer {
                let grid = self.active_grid();
                let prev_is_head = col > 0
                    && grid
                        .get(row, col - 1)
                        .is_some_and(|p| !p.is_wide_spacer && grid.cell_is_wide(p));
                if !prev_is_head {
                    self.active_grid_mut().set(row, col, Cell::default());
                }
            } else if is_wide {
                let next_is_spacer = col + 1 < cols
                    && self
                        .active_grid()
                        .get(row, col + 1)
                        .is_some_and(|nx| nx.is_wide_spacer);
                if !next_is_spacer {
                    self.active_grid_mut().set(row, col, Cell::default());
                }
            }
        }
    }

    fn insert_chars(&mut self, n: usize) {
        let cols = self.active_grid().cols();
        if cols == 0 || n == 0 {
            return;
        }
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        let row = self.cursor.row;
        let start = self.cursor.col.min(cols - 1);
        // Cutting at a pair's spacer must dissolve the whole pair first.
        self.dissolve_wide_pair_at(row, start);
        let end = hr + 1; // exclusive shift boundary: the right margin
        let n = n.min(end - start);
        if n == 0 {
            return;
        }
        let shift_count = end - start - n;
        if shift_count > 0 {
            for col in (start..start + shift_count).rev() {
                let cell = self.active_grid().get(row, col).copied().unwrap_or_default();
                self.active_grid_mut().set(row, col + n, cell);
            }
        }
        let blank = self.bce_blank();
        for col in start..start + n {
            self.active_grid_mut().set(row, col, blank);
        }
        self.fix_wide_orphans(row);
    }

    fn delete_chars(&mut self, n: usize) {
        let cols = self.active_grid().cols();
        if cols == 0 || n == 0 {
            return;
        }
        let (hl, hr) = self.h_margins();
        if self.cursor.col < hl || self.cursor.col > hr {
            return;
        }
        let row = self.cursor.row;
        let start = self.cursor.col.min(cols - 1);
        // Cutting at a pair's spacer must dissolve the whole pair first.
        self.dissolve_wide_pair_at(row, start);
        let end = hr + 1;
        let n = n.min(end - start);
        if n == 0 {
            return;
        }
        let shift_count = end - start - n;
        for i in 0..shift_count {
            let col = start + i;
            let cell = self.active_grid().get(row, col + n).copied().unwrap_or_default();
            self.active_grid_mut().set(row, col, cell);
        }
        let blank = self.bce_blank();
        for col in (start + shift_count)..end {
            self.active_grid_mut().set(row, col, blank);
        }
        self.fix_wide_orphans(row);
    }

    fn sgr_reset(&mut self) {
        self.cursor.fg = Color::Default;
        self.cursor.bg = Color::Default;
        self.cursor.attrs = CellAttrs::empty();
        self.cursor.underline_style = 0;
        self.cursor.underline_color = Color::Default;
    }

    fn sgr(&mut self, params: &[u16], params_sep: u32) {
        if params.is_empty() {
            self.sgr_reset();
            return;
        }
        // Split into colon-linked groups: bit k of `params_sep` set means a
        // ':' separated params[k] and params[k+1].
        let mut groups: Vec<&[u16]> = Vec::new();
        let mut start = 0;
        for k in 0..params.len() {
            let colon_next = k < 15 && (params_sep >> k) & 1 == 1;
            if !colon_next || k + 1 == params.len() {
                groups.push(&params[start..=k]);
                start = k + 1;
            }
        }

        let mut gi = 0;
        while gi < groups.len() {
            let g = groups[gi];
            match g[0] {
                0 => self.sgr_reset(),
                1 => self.cursor.attrs.insert(CellAttrs::BOLD),
                2 => self.cursor.attrs.insert(CellAttrs::DIM),
                3 => self.cursor.attrs.insert(CellAttrs::ITALIC),
                4 => {
                    // 4 / 4:x underline styles.
                    let style = g.get(1).copied().unwrap_or(1);
                    match style {
                        0 => {
                            self.cursor.attrs.remove(CellAttrs::UNDERLINE);
                            self.cursor.underline_style = 0;
                        }
                        s @ 1..=5 => {
                            self.cursor.attrs.insert(CellAttrs::UNDERLINE);
                            self.cursor.underline_style = s as u8;
                        }
                        _ => {}
                    }
                }
                5 | 6 => self.cursor.attrs.insert(CellAttrs::BLINK),
                7 => self.cursor.attrs.insert(CellAttrs::REVERSE),
                8 => self.cursor.attrs.insert(CellAttrs::HIDDEN),
                9 => self.cursor.attrs.insert(CellAttrs::STRIKETHROUGH),
                21 => {
                    // Double underline.
                    self.cursor.attrs.insert(CellAttrs::UNDERLINE);
                    self.cursor.underline_style = 2;
                }
                22 => self.cursor.attrs.remove(CellAttrs::BOLD | CellAttrs::DIM),
                23 => self.cursor.attrs.remove(CellAttrs::ITALIC),
                24 => {
                    self.cursor.attrs.remove(CellAttrs::UNDERLINE);
                    self.cursor.underline_style = 0;
                }
                25 => self.cursor.attrs.remove(CellAttrs::BLINK),
                27 => self.cursor.attrs.remove(CellAttrs::REVERSE),
                28 => self.cursor.attrs.remove(CellAttrs::HIDDEN),
                29 => self.cursor.attrs.remove(CellAttrs::STRIKETHROUGH),
                53 => self.cursor.attrs.insert(CellAttrs::OVERLINE),
                55 => self.cursor.attrs.remove(CellAttrs::OVERLINE),
                code @ 30..=37 => self.cursor.fg = Color::Indexed((code - 30) as u8),
                code @ 40..=47 => self.cursor.bg = Color::Indexed((code - 40) as u8),
                code @ 90..=97 => self.cursor.fg = Color::Indexed((code - 90 + 8) as u8),
                code @ 100..=107 => self.cursor.bg = Color::Indexed((code - 100 + 8) as u8),
                39 => self.cursor.fg = Color::Default,
                49 => self.cursor.bg = Color::Default,
                59 => self.cursor.underline_color = Color::Default,
                code @ (38 | 48 | 58) => {
                    // Extended color; the arguments live either in this
                    // colon group or in the following semicolon params.
                    let (color, consumed_groups) = if g.len() >= 2 {
                        (Self::parse_extended_color_group(g), 0)
                    } else {
                        // Legacy semicolon form: 38;5;n or 38;2;r;g;b.
                        let rest: Vec<u16> = groups[gi + 1..]
                            .iter()
                            .take(4)
                            .flat_map(|gr| gr.iter().copied())
                            .collect();
                        match rest.first() {
                            Some(5) if rest.len() >= 2 => {
                                (Some(Color::Indexed(rest[1] as u8)), 2)
                            }
                            Some(2) if rest.len() >= 4 => (
                                Some(Color::Rgb(rest[1] as u8, rest[2] as u8, rest[3] as u8)),
                                4,
                            ),
                            _ => (None, 0),
                        }
                    };
                    if let Some(color) = color {
                        match code {
                            38 => self.cursor.fg = color,
                            48 => self.cursor.bg = color,
                            _ => self.cursor.underline_color = color,
                        }
                    }
                    gi += consumed_groups;
                }
                _ => {}
            }
            gi += 1;
        }
    }

    /// A colon-linked extended-color group: `38:5:n`, `38:2:r:g:b`, or
    /// `38:2::r:g:b` (with an empty colorspace slot).
    fn parse_extended_color_group(g: &[u16]) -> Option<Color> {
        match g.get(1)? {
            5 => Some(Color::Indexed(*g.get(2)? as u8)),
            2 => {
                let (r, gg, b) = if g.len() >= 6 {
                    (g[3], g[4], g[5])
                } else if g.len() >= 5 {
                    (g[2], g[3], g[4])
                } else {
                    return None;
                };
                Some(Color::Rgb(r as u8, gg as u8, b as u8))
            }
            _ => None,
        }
    }


    /// Puts the cursor at the origin of the coordinate system currently in
    /// force: the scroll region's top-left under DECOM, the screen's
    /// otherwise. This is `CUP` with no parameters.
    fn cursor_to_home(&mut self) {
        if self.modes.origin_mode {
            self.cursor.row = self.scroll_top.min(self.scroll_bottom);
            self.cursor.col = self.h_margins().0;
        } else {
            self.cursor.row = 0;
            self.cursor.col = 0;
        }
        self.pending_wrap = false;
    }

    /// Restore DECSC/CSI-s state without ever reintroducing coordinates from
    /// an older, larger geometry. Applications commonly save a cursor,
    /// receive SIGWINCH, then restore it; both axes must be clamped at the
    /// point of use just like upstream clamps a saved column after reflow.
    fn restore_saved_cursor(&mut self) {
        let Some(saved) = self.cursor.saved else { return };
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        self.cursor.row = saved.row.min(rows.saturating_sub(1));
        self.cursor.col = saved.col.min(cols.saturating_sub(1));
        self.cursor.fg = saved.fg;
        self.cursor.bg = saved.bg;
        self.cursor.attrs = saved.attrs;
        self.g0 = saved.g0;
        self.g1 = saved.g1;
        self.shift_out = saved.shift_out;
        self.modes.origin_mode = saved.origin_mode;
        self.pending_wrap = saved.pending_wrap;
        self.protected_mode = saved.protected_mode;
        self.gr_slot = saved.gr_slot;
    }

    fn csi_private_mode(&mut self, params: &[u16], action: char) {
        let set = action == 'h';
        for &p in params {
            self.modes.apply_private_mode(p, set);
            if p == 69 && !set {
                // Disabling DECLRMM resets the horizontal margins.
                self.scroll_left = 0;
                self.scroll_right = self.active_grid().cols().saturating_sub(1);
            }
            match p {
                25 => self.cursor_visible = set,
                // DECOM. Changing it moves the cursor to home in whichever
                // coordinate system now applies -- the region's top-left with
                // origin mode on, the screen's with it off. Without this the
                // cursor keeps an address that no longer means what it did,
                // and can end up outside the region it is supposedly
                // relative to. xterm does the same (srm_DECOM ->
                // CursorSet(screen, 0, 0, flags)).
                6 => self.cursor_to_home(),
                // 47: plain switch, nothing cleared, cursor carries over.
                47 => {
                    if set {
                        self.switch_screen(ScreenBuffer::Alternate);
                    } else {
                        self.switch_screen(ScreenBuffer::Primary);
                    }
                }
                // 1047: switch; leaving clears the alternate screen.
                1047 => {
                    if set {
                        if self.active == ScreenBuffer::Primary {
                            self.switch_screen(ScreenBuffer::Alternate);
                        }
                    } else if self.active == ScreenBuffer::Alternate {
                        self.alternate.clear_all();
                        self.switch_screen(ScreenBuffer::Primary);
                    }
                }
                // 1049: save cursor + switch + clear on enter; switch back +
                // restore cursor on leave.
                1049 => {
                    if set {
                        if self.active == ScreenBuffer::Primary {
                            self.cursor.saved = Some(SavedCursor {
                                row: self.cursor.row,
                                col: self.cursor.col,
                                fg: self.cursor.fg,
                                bg: self.cursor.bg,
                                attrs: self.cursor.attrs,
                                g0: self.g0,
                                g1: self.g1,
                                shift_out: self.shift_out,
                                origin_mode: self.modes.origin_mode,
                                pending_wrap: self.pending_wrap,
                                protected_mode: self.protected_mode,
                                gr_slot: self.gr_slot,
                            });
                            self.switch_screen(ScreenBuffer::Alternate);
                            self.alternate.clear_all();
                        }
                    } else if self.active == ScreenBuffer::Alternate {
                        self.switch_screen(ScreenBuffer::Primary);
                        self.restore_saved_cursor();
                    }
                }
                _ => {}
            }
        }
    }

    /// Handle OSC 8 (`ESC ] 8 ; params ; uri ST`): open or close a
    /// hyperlink span.
    ///
    /// `params[1]` is an OSC-8-specific `key=value:key=value` string; we
    /// only look at the `id` key and ignore the rest. `params[2]` is the
    /// URI. A missing or empty URI closes the currently open hyperlink
    /// (`current_hyperlink = None`); a non-empty URI opens one.
    ///
    /// Re-opening the same explicit `id` (even with a run of unlinked text
    /// in between) reuses the same internal numeric id, so the two spans
    /// resolve to one hyperlink -- this matches xterm's
    /// explicit-id behavior. Without an explicit id, every open gets a
    /// fresh numeric id (xterm's implicit-id behavior), so two `OSC 8 ;; uri
    /// ST` opens of the same URI are treated as distinct links.
    fn osc8_hyperlink(&mut self, params: &[&[u8]]) {
        let uri = params.get(2).copied().unwrap_or(b"");
        if uri.is_empty() {
            self.current_hyperlink = None;
            return;
        }
        let uri = String::from_utf8_lossy(uri).into_owned();

        let explicit_id = params.get(1).and_then(|param_str| {
            let param_str = String::from_utf8_lossy(param_str);
            param_str
                .split(':')
                .find_map(|kv| kv.strip_prefix("id="))
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
        });

        let id = match explicit_id {
            Some(explicit_id) => {
                *self.hyperlink_ids.entry(explicit_id).or_insert_with(|| {
                    let new_id = self.hyperlinks.len() as u32 + 1;
                    self.hyperlinks.push(uri.clone());
                    new_id
                })
            }
            None => {
                let new_id = self.hyperlinks.len() as u32 + 1;
                self.hyperlinks.push(uri);
                new_id
            }
        };

        self.current_hyperlink = Some(id);
    }
}

/// `params[idx]`, defaulting to `default` when absent. Used where an
/// explicit `0` is meaningful (e.g. erase-in-display/-line).
fn param_or_default(params: &[u16], idx: usize, default: u16) -> u16 {
    params.get(idx).copied().unwrap_or(default)
}

/// `params[idx]`, defaulting to `default` when absent *or* explicitly `0`
/// (xterm treats an explicit 0 the same as "not given" for these).
fn param_nonzero_or(params: &[u16], idx: usize, default: u16) -> u16 {
    match params.get(idx).copied() {
        Some(0) | None => default,
        Some(v) => v,
    }
}

impl Perform for Terminal {
    fn print(&mut self, c: char) {
        // Output deliberately does NOT snap the view back to the live
        // screen. Scrolling back to read something and being yanked to the
        // bottom by the next line makes scrollback useless next to anything
        // that keeps writing -- `tail -f`, a build, a test run. Keystrokes
        // bring the view back instead; the host calls
        // `scroll_viewport_bottom` on every key it sends.
        //
        // Staying put takes work: see `keep_viewport_anchored`, which grows
        // the offset as lines enter scrollback so the same text stays under
        // the same rows.
        let cols = self.active_grid().cols();
        if cols == 0 {
            return;
        }
        if self.cursor.col >= cols {
            self.cursor.col = cols - 1;
        }

        // Before the deferred wrap: a mark after the last column's character
        // still belongs to that character, not to the next line.
        if c >= '\u{A0}' && self.join_previous_cluster(c) {
            return;
        }

        // xterm's deferred wrap: a previous print parked the cursor on the
        // last column; this character is what actually triggers the wrap.
        if self.pending_wrap && self.modes.autowrap {
            let (hl, _hr) = self.h_margins();
            self.cursor.col = hl;
            self.line_feed();
            let dest_row = self.cursor.row;
            if self.h_margins_full() {
                self.active_grid_mut().set_line_wrapped(dest_row, true);
            }
        }
        self.pending_wrap = false;

        let charset = if let Some(ss) = self.single_shift.take() {
            ss
        } else if self.shift_out {
            self.g1
        } else {
            self.g0
        };
        let c = charset::translate(charset, c);
        // A 7-bit national/graphics charset can't represent non-ASCII:
        // upstream prints a blank in its place.
        let c = if charset != Charset::Ascii && (c as u32) > 0x7F && charset::translate(charset, c) == c
        {
            match charset {
                Charset::DecSpecialGraphics | Charset::British => {
                    if (c as u32) > 0x7F && !('\u{2500}'..='\u{25C7}').contains(&c)
                        && !"\u{00A3}\u{00B0}\u{00B1}\u{00B7}\u{03C0}\u{2260}\u{2264}\u{2265}\u{23BA}\u{23BB}\u{23BC}\u{23BD}\u{2409}\u{240A}\u{240B}\u{240C}\u{240D}\u{2424}\u{2518}\u{2510}\u{250C}\u{2514}\u{253C}\u{251C}\u{2524}\u{2534}\u{252C}\u{2502}".contains(c)
                    {
                        ' '
                    } else {
                        c
                    }
                }
                Charset::Ascii => c,
            }
        } else {
            c
        };
        let wide = unicode_width::UnicodeWidthChar::width(c).unwrap_or(1) >= 2;

        let cell = Cell {
            char: c,
            fg: self.cursor.fg,
            bg: self.cursor.bg,
            attrs: self.cursor.attrs,
            underline_style: self.cursor.underline_style,
            underline_color: self.cursor.underline_color,
            hyperlink: self.current_hyperlink,
            protected: self.protected_mode != ProtectedMode::Off,
            ..Cell::default()
        };

        // IRM: shift the rest of the line right to make room instead of
        // overwriting, unless the glyph lands in the final column anyway.
        if self.modes.insert && self.cursor.col + if wide { 2 } else { 1 } < cols {
            self.insert_chars(if wide { 2 } else { 1 });
        }

        // A wide glyph that doesn't fit in the remaining columns wraps (if
        // autowrap is on) before being placed, so it's never split across
        // rows.
        let (hl, hr) = self.h_margins();
        // The wrap boundary is the right margin while the cursor is inside
        // the horizontal margins, the screen edge otherwise.
        let right_bound = if self.cursor.col <= hr { hr } else { cols - 1 };
        let left_home = hl;
        if wide && self.cursor.col + 1 > right_bound {
            // A row that can never hold a wide glyph (single-column
            // terminal / margin box): write a blank in its place and park
            // the deferred wrap, exactly like upstream.
            if right_bound + 1 - left_home < 2 {
                // Too narrow to ever hold the glyph: leave the cell
                // untouched and just park the deferred wrap (upstream).
                if self.modes.autowrap {
                    self.pending_wrap = true;
                }
                return;
            }
            if self.modes.autowrap {
                let row = self.cursor.row;
                let col = self.cursor.col;
                if right_bound + 1 == cols {
                    // Wrapping off the SCREEN edge leaves a spacer_head in
                    // the abandoned cell; wrapping at an inner right margin
                    // leaves it untouched (upstream distinction).
                    let head = Cell {
                        char: ' ',
                        is_wide_spacer_head: true,
                        bg: self.cursor.bg,
                        hyperlink: self.current_hyperlink,
                        protected: self.protected_mode != ProtectedMode::Off,
                        ..Cell::default()
                    };
                    self.active_grid_mut().set(row, col, head);
                }
                self.cursor.col = left_home;
                self.line_feed();
                let dest_row = self.cursor.row;
                if right_bound + 1 == cols {
                    self.active_grid_mut().set_line_wrapped(dest_row, true);
                }
            } else {
                // No room and no wrapping allowed: the glyph is dropped
                // whole -- never squeezed in without its spacer (upstream
                // behavior).
                return;
            }
        }

        let row = self.cursor.row;
        let col = self.cursor.col;
        self.dissolve_wide_pair_at(row, col);
        if wide {
            self.dissolve_wide_pair_at(row, col + 1);
            self.active_grid_mut().set_wide(row, col, cell);
            self.cursor.col += 2;
        } else {
            self.active_grid_mut().set(row, col, cell);
            self.cursor.col += 1;
        }

        if self.cursor.col > right_bound {
            // Park on the boundary column; the wrap is deferred until the
            // next printable character arrives (or cancelled by movement).
            self.cursor.col = right_bound;
            if self.modes.autowrap {
                self.pending_wrap = true;
            }
        }

        self.last_printed_char = Some(c);
    }

    fn print_slice(&mut self, bytes: &[u8]) {
        // The parser only calls this for ground-state ASCII. Hoist the
        // invariant terminal checks and write simple rows directly; unusual
        // modes and rows containing wide pairs retain the full print path.
        if self.modes.insert
            || !self.modes.autowrap
            || !self.h_margins_full()
            || self.single_shift.is_some()
            || self.shift_out
            || self.g0 != Charset::Ascii
            || self.current_hyperlink.is_some()
        {
            for &byte in bytes {
                self.print(byte as char);
            }
            return;
        }

        // As in `print`: output leaves the viewport where the user put it.
        let cols = self.active_grid().cols();
        if cols == 0 {
            return;
        }
        self.cursor.col = self.cursor.col.min(cols - 1);

        let template = Cell {
            char: '\0',
            fg: self.cursor.fg,
            bg: self.cursor.bg,
            attrs: self.cursor.attrs,
            underline_style: self.cursor.underline_style,
            underline_color: self.cursor.underline_color,
            protected: self.protected_mode != ProtectedMode::Off,
            ..Cell::default()
        };

        let mut offset = 0;
        while offset < bytes.len() {
            if self.pending_wrap {
                self.cursor.col = 0;
                self.line_feed();
                let row = self.cursor.row;
                self.active_grid_mut().set_line_wrapped(row, true);
            }

            let row = self.cursor.row;
            let col = self.cursor.col;
            let count = (cols - col).min(bytes.len() - offset);
            let run = &bytes[offset..offset + count];

            if !self
                .active_grid_mut()
                .write_narrow_ascii(row, col, run, template)
            {
                self.print(bytes[offset] as char);
                offset += 1;
                continue;
            }

            offset += count;
            self.last_printed_char = run.last().map(|&byte| byte as char);
            if col + count == cols {
                self.cursor.col = cols - 1;
                self.pending_wrap = true;
            } else {
                self.cursor.col = col + count;
            }
        }
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x0A => {
                // LF; in LNM (mode 20) it also performs a carriage return.
                if self.modes.linefeed_mode {
                    self.cursor.col = 0;
                }
                self.line_feed();
            }
            0x0D => {
                // CR: to the left margin when at/right of it (or always in
                // origin mode); to column 0 when left of it.
                let (hl, _) = self.h_margins();
                self.cursor.col = if self.modes.origin_mode || self.cursor.col >= hl {
                    hl
                } else {
                    0
                };
                self.pending_wrap = false;
            }
            0x08 => {
                // BS
                self.cursor.col = self.cursor.col.saturating_sub(1);
                self.pending_wrap = false;
            }
            0x09 => {
                // HT: advance to the next tab stop, clamped to the right
                // margin while inside the margins (screen edge otherwise).
                let cols = self.active_grid().cols();
                let (_, hr) = self.h_margins();
                let limit = if self.cursor.col <= hr {
                    hr
                } else {
                    cols.saturating_sub(1)
                };
                let next = self.tabstops.next_stop(self.cursor.col);
                self.cursor.col = next.min(limit);
                self.pending_wrap = false;
            }
            0x0E => self.shift_out = true,  // SO: shift to G1
            0x0F => self.shift_out = false, // SI: shift to G0
            0x05 => {
                // ENQ: reply with the host-configured answerback string.
                let s = self.answerback.clone();
                self.response.push_str(&s);
            }
            0x07 => self.events.push(TerminalEvent::Bell), // BEL
            _ => {}
        }
    }

    fn hook(&mut self, _params: &[u16], _params_sep: u32, intermediates: &[u8], _ignore: bool, action: char) {
        self.dcs_buf.clear();
        self.dcs = match (intermediates, action) {
            ([b'$'], 'q') => Some(DcsKind::Decrqss),
            ([b'+'], 'q') => Some(DcsKind::XtGetTcap),
            _ => None,
        };
    }

    fn put(&mut self, byte: u8) {
        if self.dcs.is_some() {
            // Bound the buffer; oversized requests are dropped wholesale
            // (upstream ignores them and keeps parsing).
            if self.dcs_buf.len() < 256 {
                self.dcs_buf.push(byte);
            } else {
                self.dcs = None;
                self.dcs_buf.clear();
            }
        }
    }

    fn unhook(&mut self) {
        let Some(kind) = self.dcs.take() else {
            self.dcs_buf.clear();
            return;
        };
        let payload = std::mem::take(&mut self.dcs_buf);
        match kind {
            DcsKind::Decrqss => self.decrqss(&payload),
            DcsKind::XtGetTcap => self.xtgettcap(&payload),
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        if params.is_empty() {
            return;
        }
        if params.len() >= 2 && (params[0] == b"0" || params[0] == b"2") {
            self.title = String::from_utf8_lossy(params[1]).into_owned();
            self.events.push(TerminalEvent::TitleChanged(self.title.clone()));
            return;
        }
        if params[0] == b"8" {
            self.osc8_hyperlink(params);
            return;
        }
        if params[0] == b"4" {
            // OSC 4 ; index ; spec [ ; index ; spec ... ]
            let mut i = 1;
            while i + 1 < params.len() {
                if let Ok(index) = String::from_utf8_lossy(params[i]).parse::<u8>() {
                    let spec = String::from_utf8_lossy(params[i + 1]);
                    if spec.as_ref() == "?" {
                        let reply = self.palette.query_response(index);
                        self.response.push_str(&reply);
                    } else if let Some(rgb) = palette::parse_color_spec(&spec) {
                        self.palette.set(index, rgb);
                    }
                }
                i += 2;
            }
            return;
        }
        if params[0] == b"104" {
            if params.len() <= 1 {
                self.palette.reset_all();
            } else {
                for raw in &params[1..] {
                    if let Ok(index) = String::from_utf8_lossy(raw).parse::<u8>() {
                        self.palette.reset(index);
                    }
                }
            }
            return;
        }
        if params[0] == b"52" {
            // OSC 52 ; <targets> ; <base64 | ?>
            if let Some(payload) = params.get(2) {
                if payload == b"?" {
                    self.events.push(TerminalEvent::ClipboardQuery);
                } else {
                    use base64::Engine as _;
                    if let Ok(bytes) =
                        base64::engine::general_purpose::STANDARD.decode(payload)
                    {
                        let text = String::from_utf8_lossy(&bytes).into_owned();
                        self.events.push(TerminalEvent::ClipboardSet(text));
                    }
                }
            }
            return;
        }
        if params[0] == b"7" {
            if let Some(url) = params.get(1) {
                self.events.push(TerminalEvent::PwdChanged(
                    String::from_utf8_lossy(url).into_owned(),
                ));
            }
            return;
        }
        if params[0] == b"9" && params.get(1).map(|p| p.as_ref()) == Some(b"4".as_ref()) {
            // ConEmu progress: OSC 9;4;state;value
            let state = params
                .get(2)
                .and_then(|p| String::from_utf8_lossy(p).parse::<u8>().ok())
                .unwrap_or(0);
            let value = params
                .get(3)
                .and_then(|p| String::from_utf8_lossy(p).parse::<u8>().ok());
            self.events.push(TerminalEvent::Progress { state, value });
            return;
        }
        if params[0] == b"9" {
            if let Some(body) = params.get(1) {
                self.events.push(TerminalEvent::Notification {
                    title: String::new(),
                    body: String::from_utf8_lossy(body).into_owned(),
                });
            }
            return;
        }
        if params[0] == b"777" {
            if params.get(1).map(|p| p.as_ref()) == Some(b"notify".as_ref()) {
                self.events.push(TerminalEvent::Notification {
                    title: params
                        .get(2)
                        .map(|p| String::from_utf8_lossy(p).into_owned())
                        .unwrap_or_default(),
                    body: params
                        .get(3)
                        .map(|p| String::from_utf8_lossy(p).into_owned())
                        .unwrap_or_default(),
                });
            }
            return;
        }
        if matches!(params[0], b"10" | b"11" | b"12") {
            // xterm semantics: extra arguments advance the color slot
            // (OSC 10;?;? queries fg then bg), and the reply terminator
            // mirrors the request's (BEL vs ST).
            let base: u16 = match params[0] {
                b"10" => 10,
                b"11" => 11,
                _ => 12,
            };
            let terminator = if bell_terminated { "\x07" } else { "\x1b\\" };
            for (k, arg) in params[1..].iter().enumerate() {
                let slot = base + k as u16;
                if slot > 12 {
                    break;
                }
                let arg_str = String::from_utf8_lossy(arg);
                if arg_str.as_ref() == "?" {
                    // Unset slots reply only when a fallback exists: the
                    // cursor color falls back to the foreground; fg/bg
                    // defaults live in host config and stay silent.
                    let color = match slot {
                        10 => self.default_fg,
                        11 => self.default_bg,
                        _ => self.cursor_color.or(self.default_fg),
                    };
                    if let Some((r, g, b)) = color {
                        let reply = format!(
                            "\x1b]{};rgb:{:02x}{:02x}/{:02x}{:02x}/{:02x}{:02x}{}",
                            slot, r, r, g, g, b, b, terminator
                        );
                        self.response.push_str(&reply);
                    }
                } else if let Some(rgb) = palette::parse_color_spec(&arg_str) {
                    match slot {
                        10 => {
                            self.default_fg = Some(rgb);
                            self.palette.set_fg_overridden(true);
                        }
                        11 => {
                            self.default_bg = Some(rgb);
                            self.palette.set_bg_overridden(true);
                        }
                        _ => {
                            self.cursor_color = Some(rgb);
                            self.palette.set_cursor_overridden(true);
                        }
                    }
                }
            }
            return;
        }
        if params[0] == b"110" {
            self.default_fg = self.palette.base_fg();
            self.palette.set_fg_overridden(false);
            return;
        }
        if params[0] == b"111" {
            self.default_bg = self.palette.base_bg();
            self.palette.set_bg_overridden(false);
            return;
        }
        if params[0] == b"112" {
            self.cursor_color = self.palette.base_cursor();
            self.palette.set_cursor_overridden(false);
            return;
        }
        if params[0] == b"133" {
            let arg = params.get(1).copied().unwrap_or(b"");
            let action = arg.first().copied().unwrap_or(0);
            let continuation = params.iter().skip(1).any(|p| p.windows(3).any(|w| w == b"k=c"));
            match action {
                b'A' | b'L' => {
                    // Fresh line: move to column 0 of a new line if the
                    // cursor isn't already at the start of one.
                    if self.cursor.col > 0 {
                        self.cursor.col = self.h_margins().0;
                        self.line_feed();
                    }
                    if action == b'A' {
                        self.semantic_content = SemanticContent::Prompt;
                        let row = self.cursor.row;
                        let mark = if continuation {
                            crate::grid::SemanticPrompt::PromptContinuation
                        } else {
                            crate::grid::SemanticPrompt::Prompt
                        };
                        self.active_grid_mut().set_row_semantic_prompt(row, mark);
                    }
                }
                b'P' => {
                    // prompt_start without the fresh-line behavior.
                    self.semantic_content = SemanticContent::Prompt;
                    let row = self.cursor.row;
                    let mark = if continuation {
                        crate::grid::SemanticPrompt::PromptContinuation
                    } else {
                        crate::grid::SemanticPrompt::Prompt
                    };
                    self.active_grid_mut().set_row_semantic_prompt(row, mark);
                }
                b'B' => self.semantic_content = SemanticContent::Input,
                b'C' => {
                    self.semantic_content = SemanticContent::Output;
                    self.events.push(TerminalEvent::CommandStart);
                    // Fish heuristic: OSC 133;C at column 0 clears the
                    // continuation mark the preceding newline just set.
                    if self.cursor.col == 0 {
                        let row = self.cursor.row;
                        if matches!(
                            self.active_grid().row_semantic_prompt(row),
                            crate::grid::SemanticPrompt::Prompt
                                | crate::grid::SemanticPrompt::PromptContinuation
                        ) {
                            self.active_grid_mut()
                                .set_row_semantic_prompt(row, crate::grid::SemanticPrompt::Unset);
                        }
                    }
                }
                b'D' => {
                    self.semantic_content = SemanticContent::None;
                    // `OSC 133;D;<code>` carries the exit status; plain
                    // `OSC 133;D` does not.
                    let exit_code = params
                        .get(2)
                        .and_then(|p| std::str::from_utf8(p).ok())
                        .and_then(|s| s.trim().parse::<i32>().ok());
                    self.events.push(TerminalEvent::CommandEnd { exit_code });
                }
                _ => {}
            }
            return;
        }
        if params[0] == b"1337" {
            // iTerm2 extensions; only Copy=:<base64> is supported.
            if let Some(rest) = params.get(1) {
                let rest = String::from_utf8_lossy(rest);
                if let Some(b64) = rest.strip_prefix("Copy=:") {
                    use base64::Engine as _;
                    if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64) {
                        self.events.push(TerminalEvent::ClipboardSet(
                            String::from_utf8_lossy(&bytes).into_owned(),
                        ));
                    }
                }
            }
        }
    }

    fn csi_dispatch(&mut self, params: &[u16], _params_sep: u32, intermediates: &[u8], _ignore: bool, action: char) {
        // DECRQCRA. The only way an out-of-process harness can read the
        // screen back, which is what esctest and vttest rely on.
        if intermediates == *b"*" && action == 'y' {
            self.report_checksum(params);
            return;
        }
        // XTCHECKSUM: pick which parts of DEC's checksum behaviour to keep.
        if intermediates == *b"#" && action == 'y' {
            self.checksum_ext = params.first().copied().unwrap_or(0);
            return;
        }
        if intermediates == *b"?$" {
            if action == 'p' {
                let ps = param_or_default(params, 0, 0);
                let set = |b: bool| if b { 1 } else { 2 };
                let v = match ps {
                    1 => set(self.modes.cursor_key_app_mode),
                    6 => set(self.modes.origin_mode),
                    7 => set(self.modes.autowrap),
                    25 => set(self.cursor_visible),
                    45 => set(self.modes.reverse_wrap),
                    69 => set(self.modes.left_right_margin_mode),
                    47 | 1047 | 1049 => set(self.active == ScreenBuffer::Alternate),
                    1000 => set(self.modes.mouse_tracking == crate::modes::MouseTracking::Normal),
                    1002 => set(self.modes.mouse_tracking == crate::modes::MouseTracking::ButtonEvent),
                    1003 => set(self.modes.mouse_tracking == crate::modes::MouseTracking::AnyEvent),
                    1004 => set(self.modes.focus_events),
                    1005 => set(self.modes.mouse_utf8),
                    1006 => set(self.modes.mouse_sgr),
                    1007 => set(self.modes.alternate_scroll),
                    1045 => set(self.modes.reverse_wrap_extended),
                    2004 => set(self.modes.bracketed_paste),
                    2026 => set(self.modes.synchronized_output),
                    2027 => set(self.modes.grapheme_cluster),
                    _ => 0,
                };
                self.response.push_str(&format!("\x1b[?{};{}$y", ps, v));
            }
            return;
        }
        if intermediates == *b"?" {
            match action {
                'h' | 'l' => self.csi_private_mode(params, action),
                'u' => {
                    let reply = self.kitty_keyboard.query_response();
                    self.response.push_str(&reply);
                }
                'n' => {
                    // DECDSR. Answering every code we recognise matters more
                    // than the values: an unanswered status request leaves
                    // the asking program blocked on a read, not falling back.
                    self.report_private_dsr(params);
                }
                // DECSED/DECSEL: selective erase always respects protection.
                'J' => {
                    self.pending_wrap = false;
                    self.erase_in_display_protected(param_or_default(params, 0, 0), true);
                }
                'K' => {
                    self.pending_wrap = false;
                    self.erase_in_line_protected(param_or_default(params, 0, 0), true);
                }
                _ => {}
            }
            return;
        }
        if intermediates == *b">" {
            match action {
                'u' => {
                    let flags = KittyFlags::from_bits_truncate(param_or_default(params, 0, 0) as u8);
                    self.kitty_keyboard.push(flags);
                }
                'c' => self.response.push_str(&response::da2_response()),
                // XTSHIFTESCAPE.
                's' => self.modes.shift_capture = Some(param_or_default(params, 0, 0) == 1),
                'q' => {
                    let name = if self.xtversion.is_empty() {
                        "tako".to_string()
                    } else {
                        self.xtversion.clone()
                    };
                    self.response.push_str(&response::xtversion_response(&name));
                }
                _ => {}
            }
            return;
        }
        if intermediates == *b"<" {
            if action == 'u' {
                let n = param_nonzero_or(params, 0, 1) as usize;
                self.kitty_keyboard.pop(n);
            }
            return;
        }
        if intermediates == *b"=" {
            match action {
                'u' => {
                    let flags =
                        KittyFlags::from_bits_truncate(param_or_default(params, 0, 0) as u8);
                    self.kitty_keyboard.set(flags);
                }
                // DA3: tertiary device attributes (site/unit id).
                'c' => self.response.push_str("\x1bP!|00000000\x1b\\"),
                _ => {}
            }
            return;
        }
        if intermediates == *b" " {
            if action == 'q' {
                let param = param_or_default(params, 0, 0);
                if param == 0 {
                    // 0 is "the default": the host's, not a fixed shape.
                    self.cursor_style = self.default_cursor_style;
                    self.cursor_style_overridden = false;
                } else if let Some(style) = CursorStyle::from_decscusr_param(param) {
                    self.cursor_style = style;
                    self.cursor_style_overridden = true;
                }
            }
            return;
        }
        if intermediates == *b"!" {
            if action == 'p' {
                self.soft_reset();
            }
            return;
        }
        if intermediates == *b"$" {
            if action == 'p' {
                // ANSI DECRQM: report IRM (4) / LNM (20) state.
                let ps = param_or_default(params, 0, 0);
                let v = match ps {
                    4 => {
                        if self.modes.insert {
                            1
                        } else {
                            2
                        }
                    }
                    20 => {
                        if self.modes.linefeed_mode {
                            1
                        } else {
                            2
                        }
                    }
                    _ => 0,
                };
                self.response.push_str(&format!("\x1b[{};{}$y", ps, v));
            }
            return;
        }
        if intermediates == *b"'" {
            match action {
                '}' => self.insert_columns(param_nonzero_or(params, 0, 1) as usize),
                '~' => self.delete_columns(param_nonzero_or(params, 0, 1) as usize),
                _ => {}
            }
            return;
        }
        if intermediates == *b"\"" {
            if action == 'q' {
                // DECSCA: 1 = protect, 0/2 = unprotect (DEC flavor).
                self.protected_mode = match param_or_default(params, 0, 0) {
                    1 => ProtectedMode::Dec,
                    _ => ProtectedMode::Off,
                };
            }
            return;
        }
        if !intermediates.is_empty() {
            return;
        }

        // Anything that moves the cursor or erases cancels a deferred wrap.
        // 'D' is absent: the CUB arm manages the deferred wrap itself, since
        // reverse wrap treats a pending wrap as one column of movement.
        if matches!(
            action,
            'A' | 'B' | 'C' | 'E' | 'F' | 'G' | 'H' | 'd' | 'f' | 'J' | 'K' | 'X' | 'r'
                | '@' | 'P' | 'L' | 'M'
        ) {
            self.pending_wrap = false;
        }

        match action {
            'A' => {
                let n = param_nonzero_or(params, 0, 1) as usize;
                let floor = if self.cursor.row >= self.scroll_top && self.cursor.row <= self.scroll_bottom {
                    self.scroll_top
                } else {
                    0
                };
                self.cursor.row = self.cursor.row.saturating_sub(n).max(floor);
            }
            'B' => {
                let n = param_nonzero_or(params, 0, 1) as usize;
                let ceiling = if self.cursor.row >= self.scroll_top && self.cursor.row <= self.scroll_bottom {
                    self.scroll_bottom
                } else {
                    self.active_grid().rows().saturating_sub(1)
                };
                self.cursor.row = (self.cursor.row + n).min(ceiling);
            }
            'C' => {
                let n = param_nonzero_or(params, 0, 1) as usize;
                let (_, hr) = self.h_margins();
                let max = if self.cursor.col <= hr {
                    hr
                } else {
                    self.active_grid().cols().saturating_sub(1)
                };
                self.cursor.col = (self.cursor.col + n).min(max);
            }
            'D' => {
                // Upstream-exact cursorLeft (upstream `Terminal`): plain mode moves
                // toward column 0 ignoring margins; reverse-wrap modes use
                // the margin/region rules below.
                let mut n = param_nonzero_or(params, 0, 1) as usize;
                let rw_ext = self.modes.reverse_wrap_extended && self.modes.autowrap;
                let rw_basic = self.modes.reverse_wrap && self.modes.autowrap;
                if !(rw_basic || rw_ext) {
                    self.cursor.col -= n.min(self.cursor.col);
                    self.pending_wrap = false;
                } else {
                    if self.pending_wrap {
                        n = n.saturating_sub(1);
                        self.pending_wrap = false;
                    }
                    let cols = self.active_grid().cols();
                    let top = self.scroll_top;
                    let bottom = self.scroll_bottom;
                    let (hl, hr) = self.h_margins();
                    let right_margin = hr;
                    let left_margin = if self.cursor.col < hl { 0 } else { hl };

                    // Basic reverse wrap starting ON the left margin at or
                    // above the top margin jumps straight to the region's
                    // top-left (xterm quirk, unit-tested upstream).
                    if self.cursor.col == left_margin && !rw_ext && self.cursor.row <= top {
                        self.cursor.row = top;
                        self.cursor.col = left_margin;
                    } else {
                        loop {
                            let step = n.min(self.cursor.col - left_margin);
                            self.cursor.col -= step;
                            n -= step;
                            if n == 0 {
                                break;
                            }
                            if self.cursor.row == top {
                                if !rw_ext {
                                    break;
                                }
                                self.cursor.row = bottom;
                                self.cursor.col = right_margin.min(cols.saturating_sub(1));
                                n -= 1;
                                continue;
                            }
                            if self.cursor.row == 0 {
                                break;
                            }
                            // A wrap marker lives on the continuation row,
                            // so the current row records whether reverse-wrap
                            // may cross back into the row above it.
                            if !rw_ext && !self.active_grid().is_line_wrapped(self.cursor.row) {
                                break;
                            }
                            self.cursor.row -= 1;
                            self.cursor.col = right_margin.min(cols.saturating_sub(1));
                            n -= 1;
                        }
                    }
                }
            }
            'H' | 'f' => {
                let row = param_nonzero_or(params, 0, 1) as usize;
                let col = param_nonzero_or(params, 1, 1) as usize;
                let max_col = self.active_grid().cols().saturating_sub(1);
                if self.modes.origin_mode {
                    let target = self.scroll_top + row.saturating_sub(1);
                    self.cursor.row = target.min(self.scroll_bottom);
                    let (hl, hr) = self.h_margins();
                    self.cursor.col = (hl + col.saturating_sub(1)).min(hr);
                } else {
                    let max_row = self.active_grid().rows().saturating_sub(1);
                    self.cursor.row = row.saturating_sub(1).min(max_row);
                    self.cursor.col = col.saturating_sub(1).min(max_col);
                }
            }
            'h' | 'l' => {
                // ANSI SM/RM (no '?'): IRM (4) and LNM (20).
                for &p in params {
                    match p {
                        4 => self.modes.insert = action == 'h',
                        20 => self.modes.linefeed_mode = action == 'h',
                        _ => {}
                    }
                }
            }
            'J' => self.erase_in_display(param_or_default(params, 0, 0)),
            'K' => self.erase_in_line(param_or_default(params, 0, 0)),
            'm' => self.sgr(params, _params_sep),
            'r' => {
                let rows = self.active_grid().rows();
                let top = param_nonzero_or(params, 0, 1) as usize;
                let bottom = param_nonzero_or(params, 1, rows as u16) as usize;
                let top0 = top.saturating_sub(1).min(rows.saturating_sub(1));
                let bottom0 = bottom.saturating_sub(1).min(rows.saturating_sub(1));
                if top0 < bottom0 {
                    self.scroll_top = top0;
                    self.scroll_bottom = bottom0;
                } else {
                    self.scroll_top = 0;
                    self.scroll_bottom = rows.saturating_sub(1);
                }
                if self.modes.origin_mode {
                    self.cursor.row = self.scroll_top;
                    self.cursor.col = self.h_margins().0;
                } else {
                    self.cursor.row = 0;
                    self.cursor.col = 0;
                }
            }
            's' if self.modes.left_right_margin_mode => {
                // DECSLRM: set left/right margins, then home the cursor.
                let cols = self.active_grid().cols();
                let left = param_nonzero_or(params, 0, 1) as usize;
                let right = param_nonzero_or(params, 1, cols as u16) as usize;
                let left0 = left.saturating_sub(1).min(cols.saturating_sub(1));
                let right0 = right.saturating_sub(1).min(cols.saturating_sub(1));
                if left0 < right0 {
                    self.scroll_left = left0;
                    self.scroll_right = right0;
                } else {
                    self.scroll_left = 0;
                    self.scroll_right = cols.saturating_sub(1);
                }
                if self.modes.origin_mode {
                    self.cursor.row = self.scroll_top;
                    self.cursor.col = self.scroll_left;
                } else {
                    self.cursor.row = 0;
                    self.cursor.col = 0;
                }
                self.pending_wrap = false;
            }
            's' => {
                self.cursor.saved = Some(SavedCursor {
                    row: self.cursor.row,
                    col: self.cursor.col,
                    fg: self.cursor.fg,
                    bg: self.cursor.bg,
                    attrs: self.cursor.attrs,
                    g0: self.g0,
                    g1: self.g1,
                    shift_out: self.shift_out,
                    origin_mode: self.modes.origin_mode,
                    pending_wrap: self.pending_wrap,
                    protected_mode: self.protected_mode,
                    gr_slot: self.gr_slot,
                });
            }
            'u' => {
                self.restore_saved_cursor();
            }
            'L' => self.insert_lines(param_nonzero_or(params, 0, 1) as usize),
            'M' => self.delete_lines(param_nonzero_or(params, 0, 1) as usize),
            '@' => self.insert_chars(param_nonzero_or(params, 0, 1) as usize),
            'P' => self.delete_chars(param_nonzero_or(params, 0, 1) as usize),
            'c' => self.response.push_str(&response::da1_response()),
            'n' => match param_or_default(params, 0, 0) {
                5 => self.response.push_str(&response::device_status_ok()),
                6 => {
                    let (row, col) = self.reported_cursor();
                    let reply = response::cursor_position_report(row, col);
                    self.response.push_str(&reply);
                }
                _ => {}
            },
            'g' => match param_or_default(params, 0, 0) {
                3 => self.tabstops.clear_all(),
                _ => self.tabstops.clear(self.cursor.col),
            },
            'I' => {
                let n = param_nonzero_or(params, 0, 1) as usize;
                let (_, hr) = self.h_margins();
                let max = if self.cursor.col <= hr {
                    hr
                } else {
                    self.active_grid().cols().saturating_sub(1)
                };
                for _ in 0..n {
                    self.cursor.col = self.tabstops.next_stop(self.cursor.col).min(max);
                }
            }
            'Z' => {
                let n = param_nonzero_or(params, 0, 1) as usize;
                let (hl, _) = self.h_margins();
                let floor = if self.cursor.col >= hl { hl } else { 0 };
                for _ in 0..n {
                    self.cursor.col = self.tabstops.prev_stop(self.cursor.col).max(floor);
                }
            }
            'b' => {
                // REP: repeat the last printed character n times.
                if let Some(ch) = self.last_printed_char {
                    let n = param_nonzero_or(params, 0, 1) as usize;
                    for _ in 0..n {
                        self.print(ch);
                    }
                }
            }
            't' => {
                // XTWINOPS: only the title push/pop operations are implemented.
                match param_or_default(params, 0, 0) {
                    14 => {
                        if self.width_px > 0 && self.height_px > 0 {
                            let reply = format!("\x1b[4;{};{}t", self.height_px, self.width_px);
                            self.response.push_str(&reply);
                        }
                    }
                    16 => {
                        let rows = self.active_grid().rows() as u32;
                        let cols = self.active_grid().cols() as u32;
                        if self.width_px > 0 && self.height_px > 0 && rows > 0 && cols > 0 {
                            let reply = format!(
                                "\x1b[6;{};{}t",
                                self.height_px / rows,
                                self.width_px / cols
                            );
                            self.response.push_str(&reply);
                        }
                    }
                    18 => {
                        let reply = format!(
                            "\x1b[8;{};{}t",
                            self.active_grid().rows(),
                            self.active_grid().cols()
                        );
                        self.response.push_str(&reply);
                    }
                    21 => {
                        let reply = format!("\x1b]l{}\x1b\\", self.title);
                        self.response.push_str(&reply);
                    }
                    22 => self.title_stack.push(&self.title),
                    23 => {
                        if let Some(title) = self.title_stack.pop() {
                            self.title = title;
                        }
                    }
                    _ => {}
                }
            }
            'G' => {
                // CHA: absolute column.
                let n = param_nonzero_or(params, 0, 1) as usize;
                let max = self.active_grid().cols().saturating_sub(1);
                self.cursor.col = n.saturating_sub(1).min(max);
            }
            'd' => {
                // VPA: absolute row (region-relative in origin mode, like CUP).
                let n = param_nonzero_or(params, 0, 1) as usize;
                if self.modes.origin_mode {
                    let target = self.scroll_top + n.saturating_sub(1);
                    self.cursor.row = target.min(self.scroll_bottom);
                } else {
                    let max = self.active_grid().rows().saturating_sub(1);
                    self.cursor.row = n.saturating_sub(1).min(max);
                }
            }
            'E' => {
                // CNL: down n rows (clamped like CUD), column 0.
                let n = param_nonzero_or(params, 0, 1) as usize;
                let ceiling = if self.cursor.row >= self.scroll_top && self.cursor.row <= self.scroll_bottom {
                    self.scroll_bottom
                } else {
                    self.active_grid().rows().saturating_sub(1)
                };
                self.cursor.row = (self.cursor.row + n).min(ceiling);
                self.cursor.col = 0;
            }
            'F' => {
                // CPL: up n rows (clamped like CUU), column 0.
                let n = param_nonzero_or(params, 0, 1) as usize;
                let floor = if self.cursor.row >= self.scroll_top && self.cursor.row <= self.scroll_bottom {
                    self.scroll_top
                } else {
                    0
                };
                self.cursor.row = self.cursor.row.saturating_sub(n).max(floor);
                self.cursor.col = 0;
            }
            'S' => self.scroll_region_up(param_nonzero_or(params, 0, 1) as usize),
            'T' => self.scroll_region_down(param_nonzero_or(params, 0, 1) as usize),
            'X' => {
                // ECH: blank n cells at the cursor without shifting, keeping
                // the current background (BCE), never splitting a wide pair.
                let n = param_nonzero_or(params, 0, 1) as usize;
                let row = self.cursor.row;
                let start = self.cursor.col;
                let end = start.saturating_add(n).min(self.active_grid().cols());
                let blank = Cell {
                    bg: self.cursor.bg,
                    ..Cell::default()
                };
                let respect = self.protected_mode == ProtectedMode::Iso;
                self.active_grid_mut()
                    .fill_cells_respecting(row, start, end, blank, respect);
            }
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        if intermediates == *b"#" {
            if byte == b'8' {
                self.decaln();
            }
            return;
        }
        if intermediates == *b"(" {
            self.g0 = Self::charset_for_designator(byte);
            return;
        }
        if intermediates == *b")" {
            self.g1 = Self::charset_for_designator(byte);
            return;
        }
        if intermediates == *b"*" {
            self.g2 = Self::charset_for_designator(byte);
            return;
        }
        if intermediates == *b"+" {
            self.g3 = Self::charset_for_designator(byte);
            return;
        }
        if !intermediates.is_empty() {
            return;
        }
        match byte {
            b'H' => self.tabstops.set(self.cursor.col), // HTS
            b'7' => {
                self.cursor.saved = Some(SavedCursor {
                    row: self.cursor.row,
                    col: self.cursor.col,
                    fg: self.cursor.fg,
                    bg: self.cursor.bg,
                    attrs: self.cursor.attrs,
                    g0: self.g0,
                    g1: self.g1,
                    shift_out: self.shift_out,
                    origin_mode: self.modes.origin_mode,
                    pending_wrap: self.pending_wrap,
                    protected_mode: self.protected_mode,
                    gr_slot: self.gr_slot,
                });
            }
            b'8' => {
                self.restore_saved_cursor();
            }
            b'D' => self.line_feed(),      // IND
            b'M' => self.reverse_index(),  // RI
            b'E' => {
                // NEL: CR then LF.
                self.cursor.col = 0;
                self.line_feed();
            }
            b'N' => self.single_shift = Some(self.g2), // SS2
            b'O' => self.single_shift = Some(self.g3), // SS3
            b'~' => self.gr_slot = 1, // LS1R
            b'}' => self.gr_slot = 2, // LS2R
            b'|' => self.gr_slot = 3, // LS3R
            b'6' => self.back_index(),    // DECBI
            b'9' => self.forward_index(), // DECFI
            b'c' => self.hard_reset(), // RIS
            b'V' => self.protected_mode = ProtectedMode::Iso, // SPA
            b'W' => self.protected_mode = ProtectedMode::Off, // EPA
            _ => {}
        }
    }

    /// Kitty Graphics Protocol APC command (`ESC _ G <control-data> ;
    /// <payload> ESC \`). `data` is everything between the `_` introducer
    /// and the terminator, starting with the `G` that identifies this as a
    /// graphics command (other APC uses, which we don't support, start
    /// differently and are ignored here).
    fn apc_dispatch(&mut self, data: &[u8]) {
        if data.first() != Some(&b'G') {
            return;
        }
        let rest = &data[1..];
        let (control, payload) = match rest.iter().position(|&b| b == b';') {
            Some(i) => (&rest[..i], &rest[i + 1..]),
            None => (rest, &[][..]),
        };
        let control = String::from_utf8_lossy(control);
        match self.graphics.handle(&control, payload) {
            GraphicsResponse::Displayed {
                image_id,
                placement_id,
            } => {
                self.graphics_placements.push(GraphicsPlacement {
                    image_id,
                    placement_id,
                    row: self.cursor.row,
                    col: self.cursor.col,
                });
            }
            GraphicsResponse::Deleted { image_ids } => {
                self.graphics_placements
                    .retain(|p| !image_ids.contains(&p.image_id));
            }
            _ => {}
        }
    }
}

impl Terminal {
    /// Maps an SCS final byte to the charset it designates. Only ASCII and
    /// the DEC Special Graphics (line-drawing) set are distinguished; every
    /// other designator falls back to ASCII.
    fn charset_for_designator(byte: u8) -> Charset {
        match byte {
            b'0' => Charset::DecSpecialGraphics,
            b'A' => Charset::British,
            _ => Charset::Ascii,
        }
    }

    /// DECRQSS (`DCS $ q <setting> ST`): report the current value of a
    /// setting as `DCS 1 $ r <value> ST`, or `DCS 0 $ r ST` when the
    /// setting isn't recognized.
    fn decrqss(&mut self, req: &[u8]) {
        let reply = match req {
            b"m" => {
                // SGR: always leads with 0 (reset) then the active attrs.
                let mut out = String::from("0");
                let a = self.cursor.attrs;
                if a.contains(CellAttrs::BOLD) {
                    out.push_str(";1");
                }
                if a.contains(CellAttrs::DIM) {
                    out.push_str(";2");
                }
                if a.contains(CellAttrs::ITALIC) {
                    out.push_str(";3");
                }
                if a.contains(CellAttrs::UNDERLINE) {
                    out.push_str(";4");
                }
                if a.contains(CellAttrs::BLINK) {
                    out.push_str(";5");
                }
                if a.contains(CellAttrs::REVERSE) {
                    out.push_str(";7");
                }
                if a.contains(CellAttrs::HIDDEN) {
                    out.push_str(";8");
                }
                if a.contains(CellAttrs::STRIKETHROUGH) {
                    out.push_str(";9");
                }
                if a.contains(CellAttrs::OVERLINE) {
                    out.push_str(";53");
                }
                match self.cursor.fg {
                    Color::Default => {}
                    Color::Indexed(n) if n < 8 => out.push_str(&format!(";{}", 30 + n as u16)),
                    Color::Indexed(n) if n < 16 => {
                        out.push_str(&format!(";{}", 90 + n as u16 - 8))
                    }
                    Color::Indexed(n) => out.push_str(&format!(";38:5:{}", n)),
                    Color::Rgb(r, g, b) => out.push_str(&format!(";38:2::{}:{}:{}", r, g, b)),
                }
                match self.cursor.bg {
                    Color::Default => {}
                    Color::Indexed(n) if n < 8 => out.push_str(&format!(";{}", 40 + n as u16)),
                    Color::Indexed(n) if n < 16 => {
                        out.push_str(&format!(";{}", 100 + n as u16 - 8))
                    }
                    Color::Indexed(n) => out.push_str(&format!(";48:5:{}", n)),
                    Color::Rgb(r, g, b) => out.push_str(&format!(";48:2::{}:{}:{}", r, g, b)),
                }
                out.push('m');
                Some(out)
            }
            b"r" => Some(format!("{};{}r", self.scroll_top + 1, self.scroll_bottom + 1)),
            b"s" => {
                let (hl, hr) = self.h_margins();
                Some(format!("{};{}s", hl + 1, hr + 1))
            }
            b" q" => {
                use crate::cursor_style::CursorShape;
                let s = match (self.cursor_style.shape, self.cursor_style.blinking) {
                    (CursorShape::Block, true) => 1,
                    (CursorShape::Block, false) => 2,
                    (CursorShape::Underline, true) => 3,
                    (CursorShape::Underline, false) => 4,
                    (CursorShape::Bar, true) => 5,
                    (CursorShape::Bar, false) => 6,
                };
                Some(format!("{} q", s))
            }
            b"\"q" => Some(format!(
                "{}\"q",
                match self.protected_mode {
                    ProtectedMode::Off => 0,
                    _ => 1,
                }
            )),
            _ => None,
        };
        match reply {
            Some(body) => self.response.push_str(&format!("\x1bP1$r{}\x1b\\", body)),
            None => {
                // An unrecognized *short* request is answered negatively;
                // oversized ones were already dropped in `put`.
                if req.len() <= 2 {
                    self.response.push_str("\x1bP0$r\x1b\\");
                }
            }
        }
    }

    /// XTGETTCAP (`DCS + q <hex names> ST`): report terminfo capabilities.
    fn xtgettcap(&mut self, req: &[u8]) {
        fn from_hex(s: &[u8]) -> Option<String> {
            if !s.len().is_multiple_of(2) || s.is_empty() {
                return None;
            }
            let mut out = Vec::with_capacity(s.len() / 2);
            for pair in s.chunks(2) {
                let hi = (pair[0] as char).to_digit(16)? as u8;
                let lo = (pair[1] as char).to_digit(16)? as u8;
                out.push(hi << 4 | lo);
            }
            String::from_utf8(out).ok()
        }
        fn to_hex(s: &str) -> String {
            s.bytes().map(|b| format!("{:02X}", b)).collect()
        }

        for name_hex in req.split(|&b| b == b';') {
            let Some(name) = from_hex(name_hex) else {
                self.response.push_str(&format!(
                    "\x1bP0+r{}\x1b\\",
                    String::from_utf8_lossy(name_hex)
                ));
                continue;
            };
            let value = match name.as_str() {
                // The terminfo entry name. We set TERM=xterm-256color and ship
                // no terminfo entry of our own, so answer what TERM says: any
                // other name would point the asking program at a record it may
                // not have.
                "TN" | "name" => Some("xterm-256color".to_string()),
                "Co" | "colors" => Some("256".to_string()),
                "RGB" => Some("8/8/8".to_string()),
                "bce" => Some(String::new()),
                _ => None,
            };
            match value {
                Some(v) if v.is_empty() => {
                    // Boolean capability: present, no value.
                    self.response
                        .push_str(&format!("\x1bP1+r{}\x1b\\", to_hex(&name)));
                }
                Some(v) => {
                    self.response.push_str(&format!(
                        "\x1bP1+r{}={}\x1b\\",
                        to_hex(&name),
                        to_hex(&v)
                    ));
                }
                None => {
                    self.response
                        .push_str(&format!("\x1bP0+r{}\x1b\\", to_hex(&name)));
                }
            }
        }
    }

    /// DECSTR (`CSI ! p`): reset cursor attributes/charset/modes/scroll
    /// region to their defaults, but leave screen content, the title, and
    /// scrollback untouched.
    fn soft_reset(&mut self) {
        self.cursor.fg = Color::Default;
        self.cursor.bg = Color::Default;
        self.cursor.attrs = CellAttrs::empty();
        self.cursor.saved = None;
        self.cursor_visible = true;
        self.modes.origin_mode = false;
        self.modes.autowrap = true;
        self.modes.cursor_key_app_mode = false;
        self.modes.alternate_scroll = true;
        let rows = self.active_grid().rows();
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);
        self.scroll_left = 0;
        self.scroll_right = self.active_grid().cols().saturating_sub(1);
        self.g0 = Charset::Ascii;
        self.g1 = Charset::Ascii;
        self.shift_out = false;
        self.pending_wrap = false;
        self.protected_mode = ProtectedMode::Off;
    }

    /// RIS (`ESC c`): full terminal reset -- clears both screens and
    /// scrollback, homes the cursor, and restores every piece of state to
    /// its power-on default. What the host configured stays: base colors,
    /// default cursor style and how much scrollback to keep.
    fn hard_reset(&mut self) {
        let (cols, rows) = (self.active_grid().cols(), self.active_grid().rows());
        let scrollback = self.primary.scrollback_capacity();
        self.primary = Grid::with_scrollback_capacity(cols, rows, scrollback);
        self.alternate = Grid::with_scrollback_capacity(cols, rows, 0);
        self.switch_screen(ScreenBuffer::Primary);
        self.cursor = Cursor::default();
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);
        self.scroll_left = 0;
        self.scroll_right = cols.saturating_sub(1);
        self.title = String::new();
        self.cursor_visible = true;
        self.selection = None;
        self.g0 = Charset::Ascii;
        self.g1 = Charset::Ascii;
        self.shift_out = false;
        self.tabstops = TabStops::new(cols);
        self.kitty_keyboard = KittyKeyboardState::new();
        self.modes = TerminalModes::new();
        self.modes.grapheme_cluster = self.grapheme_width_method == GraphemeWidthMethod::Unicode;
        self.cursor_style = self.default_cursor_style;
        self.cursor_style_overridden = false;
        self.palette.reset_all();
        self.default_fg = self.palette.base_fg();
        self.default_bg = self.palette.base_bg();
        self.cursor_color = self.palette.base_cursor();
        self.palette.set_fg_overridden(false);
        self.palette.set_bg_overridden(false);
        self.palette.set_cursor_overridden(false);
        self.title_stack = TitleStack::new();
        self.last_printed_char = None;
        self.pending_wrap = false;
        self.protected_mode = ProtectedMode::Off;
    }

    /// DECALN (`ESC # 8`): fill the screen with 'E', reset the scroll
    /// region, and home the cursor -- the classic screen-alignment pattern.
    fn decaln(&mut self) {
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        for row in 0..rows {
            for col in 0..cols {
                self.active_grid_mut().set(
                    row,
                    col,
                    Cell {
                        char: 'E',
                        ..Cell::default()
                    },
                );
            }
            self.active_grid_mut().set_line_wrapped(row, false);
        }
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);
        self.scroll_left = 0;
        self.scroll_right = cols.saturating_sub(1);
        self.cursor.row = 0;
        self.cursor.col = 0;
        self.pending_wrap = false;
    }
}

#[cfg(test)]
mod scrollback_soft_wrap_tests {
    use super::*;

    #[test]
    fn test_scrollback_soft_wrap_selection_eviction_forward_reverse() {
        let mut term = Terminal::with_scrollback(5, 2, 2);

        term.feed(b"ABCDEFGHIJKLMNOPQRST");

        assert_eq!(term.active_grid().scrollback_len(), 2);
        assert!(!term.is_line_wrapped_abs(0));
        assert!(term.is_line_wrapped_abs(1));
        assert!(term.is_line_wrapped_abs(2));
        assert!(term.is_line_wrapped_abs(3));

        term.scroll_viewport_up(2);
        term.start_selection(0, 0, SelectionMode::Linear);
        term.extend_selection(3, 4);
        let forward_selected = term.selected_text().unwrap();
        assert_eq!(forward_selected, "ABCDEFGHIJKLMNOPQRST");

        term.start_selection(3, 4, SelectionMode::Linear);
        term.extend_selection(0, 0);
        let reverse_selected = term.selected_text().unwrap();
        assert_eq!(reverse_selected, "ABCDEFGHIJKLMNOPQRST");

        term.feed(b"\r\nUVWXYZ");
        assert_eq!(term.active_grid().scrollback_len(), 2);

        term.scroll_viewport_up(2);
        term.start_selection(0, 0, SelectionMode::Linear);
        term.extend_selection(3, 4);
        let evicted_selected = term.selected_text().unwrap();
        // The new CR/LF output evicts the first wrapped pair from the
        // capacity-two scrollback. Selection must clamp to the oldest line
        // still retained, rather than referencing discarded text.
        assert_eq!(evicted_selected, "KLMNOPQRST\nUVWXYZ");
    }
}
