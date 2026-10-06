/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::charset::Charset;
use crate::grid::{CellAttrs, Color};

/// Which screen buffer is currently active.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenBuffer {
    Primary,
    Alternate,
}

/// Maximum rows an inline image or placement can advance the cursor (bounds loop iteration against DoS).
pub const MAX_INLINE_IMAGE_ROW_SPAN: usize = 1024;
/// Maximum pixel dimension (width or height) allowed for image layout calculations.
pub const MAX_INLINE_IMAGE_PIXEL_DIM: u32 = crate::graphics::MAX_IMAGE_SIDE;

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

/// Policy governing access to host clipboard via escape sequences (OSC 52, OSC 1337 Copy) (Track G4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ClipboardPolicy {
    /// Completely disable clipboard escape sequences (both read and write).
    Disabled,
    /// Allow writing to the clipboard; refuse reading/querying by default (G4 policy).
    #[default]
    WriteOnly,
    /// Explicitly allow both clipboard write and read queries.
    ReadWrite,
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

/// The execution state of a recorded command mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandMarkStatus {
    Running,
    Success,
    Error(Option<i32>),
}

/// A mark associated with a recorded command prompt line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandMark {
    pub command_id: u64,
    /// Absolute line where this command's prompt started.
    pub prompt_line: u64,
    /// Index into the retained lines buffer (0 = oldest retained line in scrollback).
    pub retained_row: usize,
    pub status: CommandMarkStatus,
}

/// A sticky header pinned at the top of the pane while scrolling through long command output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StickyCommandHeader {
    pub command_id: u64,
    pub command: String,
    pub prompt_line: u64,
    pub prompt_retained_row: usize,
    pub status: CommandMarkStatus,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct InFlightOsc99 {
    pub(crate) id: Option<String>,
    pub(crate) title: String,
    pub(crate) body: String,
    pub(crate) app_name: Option<String>,
    pub(crate) urgency: u8,
    pub(crate) actions: Vec<String>,
    pub(crate) report_activation: bool,
    pub(crate) focus: bool,
    pub(crate) report_close: bool,
    pub(crate) timeout_ms: Option<u64>,
    pub(crate) only_when_unfocused: bool,
}
