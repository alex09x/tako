/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::collections::{HashMap, VecDeque};
use std::time::Instant;

use crate::charset::Charset;
use crate::cursor_style::CursorStyle;
use crate::graphics::GraphicsState;
use crate::grid::Grid;
use crate::kitty_keyboard::KittyKeyboardState;
use crate::modes::TerminalModes;
use crate::palette::Palette;
use crate::parser::Parser;
use crate::response::ResponseQueue;
use crate::tabstops::TabStops;
use crate::title_stack::TitleStack;

use super::commands::CommandLog;
use super::events::{ContextFrame, TerminalEvent};
use super::types::{
    ClipboardPolicy, Cursor, DcsKind, GraphemeWidthMethod, GraphicsPlacement, InFlightOsc99,
    ProtectedMode, ScreenBuffer, SemanticContent,
};

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
    pub(crate) selection: Option<super::types::Selection>,
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
    /// Commands the shell marked on the primary screen.
    pub(crate) commands: CommandLog,
    /// The last OSC 7 report, when it fit in [`commands::MAX_CWD_BYTES`].
    pub(crate) last_cwd: Option<String>,
    /// Where the command line starts (absolute line, column): the cursor at
    /// `133;B`. Dropped by anything that may have moved or erased it.
    pub(crate) input_start: Option<(u64, usize)>,
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
    /// Where the prompt started (absolute line): recorded at `133;A`/`133;P`.
    pub(crate) last_prompt_line: Option<u64>,
    /// In-flight chunked OSC 99 notifications keyed by identifier.
    pub(crate) in_flight_osc99: HashMap<String, InFlightOsc99>,
    /// In-flight chunked OSC 99 notification without an explicit identifier.
    pub(crate) unidentified_osc99: Option<InFlightOsc99>,
    /// Hierarchical context stack (OSC 3008, C5): breadcrumbs and elevation.
    pub(crate) context_stack: Vec<ContextFrame>,
    /// Count of elevated context frames evicted due to MAX_CONTEXT_STACK_DEPTH.
    pub(crate) evicted_elevated: usize,
    /// Policy governing access to host clipboard via escape sequences (Track G4).
    pub(crate) clipboard_policy: ClipboardPolicy,
    /// Sliding window timestamps of recent desktop notifications for rate-limiting (Track G4).
    pub(crate) notification_timestamps: VecDeque<Instant>,
}

impl Terminal {
    pub fn new(cols: usize, rows: usize) -> Self {
        Self::with_scrollback(cols, rows, crate::grid::DEFAULT_SCROLLBACK_CAPACITY)
    }

    /// The current context frames in stack order (root first, active top last) (C5).
    pub fn context_stack(&self) -> &[ContextFrame] {
        &self.context_stack
    }

    /// Whether any frame in the context stack represents an elevated context (C5).
    pub fn is_elevated(&self) -> bool {
        self.evicted_elevated > 0 || self.context_stack.iter().any(|f| f.is_elevated)
    }

    /// The active tint color, if any, for the topmost frame or elevated state (C5).
    pub fn active_tint(&self) -> Option<&str> {
        self.context_stack
            .iter()
            .rev()
            .find_map(|f| f.tint.as_deref())
            .or_else(|| {
                if self.is_elevated() {
                    Some("#ea580c")
                } else {
                    None
                }
            })
    }

    /// Current policy governing escape sequence clipboard access (Track G4).
    pub fn clipboard_policy(&self) -> ClipboardPolicy {
        self.clipboard_policy
    }

    /// Update the policy governing escape sequence clipboard access (Track G4).
    pub fn set_clipboard_policy(&mut self, policy: ClipboardPolicy) {
        self.clipboard_policy = policy;
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
            commands: CommandLog::default(),
            last_cwd: None,
            input_start: None,
            viewport_offset: 0,
            dcs: None,
            dcs_buf: Vec::new(),
            default_fg: None,
            default_bg: None,
            cursor_color: None,
            pending_wrap: false,
            grapheme_width_method: GraphemeWidthMethod::Unicode,
            last_prompt_line: None,
            in_flight_osc99: HashMap::new(),
            unidentified_osc99: None,
            context_stack: Vec::new(),
            evicted_elevated: 0,
            clipboard_policy: ClipboardPolicy::WriteOnly,
            notification_timestamps: VecDeque::new(),
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
}
