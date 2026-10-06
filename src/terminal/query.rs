/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::cursor_style::CursorStyle;
use crate::graphics::StoredImage;
use crate::grid::{Cell, Grid, SemanticPrompt};
use crate::modes::TerminalModes;
use crate::palette::Palette;

use super::events::TerminalEvent;
use super::state::Terminal;
use super::types::{GraphemeWidthMethod, GraphicsPlacement, ScreenBuffer, SemanticContent};

impl Terminal {
    pub fn active_grid(&self) -> &Grid {
        match self.active {
            ScreenBuffer::Primary => &self.primary,
            ScreenBuffer::Alternate => &self.alternate,
        }
    }

    pub(crate) fn active_grid_mut(&mut self) -> &mut Grid {
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

    /// Drains and returns any queued device-reply bytes.
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
        let changed = self.dark_scheme != Some(dark);
        self.dark_scheme = Some(dark);
        if changed && self.modes.color_scheme_updates {
            self.report_private_dsr(&[996]);
        }
    }

    /// Resize with the text area's pixel dimensions.
    pub fn resize_with_pixels(&mut self, cols: usize, rows: usize, width_px: u32, height_px: u32) {
        if width_px > 0 {
            self.width_px = width_px;
        }
        if height_px > 0 {
            self.height_px = height_px;
        }
        self.resize(cols, rows);
    }

    /// Resize given a cell's pixel size.
    pub fn resize_with_cell_size(&mut self, cols: usize, rows: usize, cell_w: u32, cell_h: u32) {
        self.width_px = (cols as u32).saturating_mul(cell_w);
        self.height_px = (rows as u32).saturating_mul(cell_h);
        self.resize(cols, rows);
    }

    /// Current text-area pixel dimensions.
    pub fn pixel_size(&self) -> (u32, u32) {
        (self.width_px, self.height_px)
    }

    /// The GR charset slot selected via LS1R/LS2R/LS3R (0 = none).
    pub fn gr_slot(&self) -> u8 {
        self.gr_slot
    }

    pub fn viewport_row(&self, row: usize) -> Vec<Cell> {
        let grid = self.active_grid();
        let cols = grid.cols();
        if self.viewport_offset == 0 {
            return (0..cols)
                .map(|c| grid.get(row, c).copied().unwrap_or_default())
                .collect();
        }
        if row < self.viewport_offset {
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

    /// Whether a viewport row is a soft-wrapped continuation of the row above it.
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

    /// Rows that changed since the last call, as a bitmap of viewport row indices.
    pub fn take_damage(&mut self) -> Vec<u32> {
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

    /// Whether `take_damage` would currently report at least one row.
    pub fn has_damage(&self) -> bool {
        if self.modes.synchronized_output {
            return false;
        }
        self.active_grid().has_dirty()
    }

    /// Force a full redraw on the next `take_damage`.
    pub fn mark_all_damaged(&mut self) {
        self.active_grid_mut().mark_all_dirty();
    }

    /// The cursor's current OSC 133 semantic mode.
    pub fn semantic_content(&self) -> SemanticContent {
        self.semantic_content
    }

    /// Whether the cursor sits on a prompt row (OSC 133).
    pub fn cursor_is_at_prompt(&self) -> bool {
        if self.active == ScreenBuffer::Alternate {
            return false;
        }
        matches!(
            self.active_grid().row_semantic_prompt(self.cursor.row),
            SemanticPrompt::Prompt | SemanticPrompt::PromptContinuation
        )
    }

    /// Drains queued host-visible events.
    pub fn take_events(&mut self) -> Vec<TerminalEvent> {
        std::mem::take(&mut self.events)
    }

    /// Live default fg / bg / cursor colors.
    pub fn default_colors(
        &self,
    ) -> (
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
    ) {
        (self.default_fg, self.default_bg, self.cursor_color)
    }

    /// Host-configured base fg / bg / cursor colors.
    pub fn base_colors(
        &self,
    ) -> (
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
    ) {
        (
            self.palette.base_fg(),
            self.palette.base_bg(),
            self.palette.base_cursor(),
        )
    }

    /// Sets the host's base fg / bg / cursor colors and base palette entries.
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

    /// A power-on terminal that keeps what the host configured.
    pub fn fresh_keeping_host_config(&self) -> Terminal {
        let grid = self.active_grid();
        let mut fresh = Terminal::new(grid.cols(), grid.rows());
        let (fg, bg, cursor) = self.base_colors();
        let palette: Vec<(u8, (u8, u8, u8))> = (0..=255u8)
            .map(|index| (index, self.palette.base(index)))
            .collect();
        fresh.set_base_colors(fg, bg, cursor, &palette);
        fresh.set_default_cursor_style(self.default_cursor_style);
        fresh.set_scrollback_capacity(self.primary.scrollback_capacity());
        fresh.set_grapheme_width_method(self.grapheme_width_method);
        fresh
    }

    /// Sets the host's grapheme-width-method.
    pub fn set_grapheme_width_method(&mut self, method: GraphemeWidthMethod) {
        self.grapheme_width_method = method;
        self.modes.grapheme_cluster = method == GraphemeWidthMethod::Unicode;
    }

    /// The host's grapheme-width-method.
    pub fn grapheme_width_method(&self) -> GraphemeWidthMethod {
        self.grapheme_width_method
    }

    /// Sets the host's cursor style.
    pub fn set_default_cursor_style(&mut self, style: CursorStyle) {
        self.default_cursor_style = style;
        if !self.cursor_style_overridden {
            self.cursor_style = style;
        }
    }

    /// Currently live Kitty Graphics placements.
    pub fn graphics_placements(&self) -> &[GraphicsPlacement] {
        &self.graphics_placements
    }

    /// Current DEC private-mode state.
    pub fn modes(&self) -> &TerminalModes {
        &self.modes
    }

    /// Whether an app-initiated Synchronized Output frame is currently open.
    pub fn is_synchronized_output(&self) -> bool {
        self.modes.synchronized_output
    }

    /// Whether a deferred wrap is armed.
    pub fn pending_wrap(&self) -> bool {
        self.pending_wrap
    }

    /// The Kitty keyboard protocol's active flags.
    pub fn kitty_keyboard_flags(&self) -> u8 {
        self.kitty_keyboard.current().bits()
    }

    /// The stored image for `id`, if any.
    pub fn graphics_image(&self, id: u32) -> Option<&StoredImage> {
        self.graphics.image(id)
    }

    /// Maximum image memory (in bytes) allowed for this terminal.
    pub fn max_image_memory_bytes(&self) -> u64 {
        self.graphics.max_memory_bytes()
    }

    /// Sets the maximum image memory (in bytes) allowed for this terminal.
    pub fn set_max_image_memory_bytes(&mut self, max: u64) {
        self.graphics.set_max_memory_bytes(max);
    }

    /// The active 256-color indexed palette.
    pub fn palette(&self) -> &Palette {
        &self.palette
    }

    /// Plain-text dump of the active screen.
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

    /// Like [`Self::plain_string`], but soft-wrapped rows are joined into one line.
    pub fn plain_string_unwrapped(&self) -> String {
        let grid = self.active_grid();
        let mut logical: Vec<String> = Vec::new();
        let mut current = String::new();
        for row in 0..grid.rows() {
            for col in 0..grid.cols() {
                let Some(cell) = grid.get(row, col) else {
                    continue;
                };
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

    /// The current cursor shape/blink style.
    pub fn cursor_style(&self) -> CursorStyle {
        self.cursor_style
    }

    pub fn hyperlink_uri(&self, id: u32) -> Option<&str> {
        self.hyperlinks
            .get((id as usize).checked_sub(1)?)
            .map(String::as_str)
    }
}
