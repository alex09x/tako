/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::core::{Engine, TakoCore, lock_recover};
use super::query_types::FfiTextTail;
use super::render_types::DeltaState;
use super::types::{
    DEFAULT_BG, DEFAULT_FG, FfiCell, FfiCursorShape, FfiCursorStyle, FfiGraphicsImageMetadata,
    FfiGraphicsPlacement, FfiPaletteEntry, FfiRgb, FfiStoredImage, cell_to_ffi, grapheme_text,
};
use crate::terminal::Terminal;
use std::sync::Mutex;

#[uniffi::export]
impl TakoCore {
    #[uniffi::constructor]
    pub fn new(cols: u32, rows: u32) -> Self {
        Self {
            inner: Mutex::new(Engine {
                terminal: Terminal::new(cols as usize, rows as usize),
                epoch: 1,
            }),
            delta: Mutex::new(DeltaState::default()),
        }
    }

    /// Resizes the active/alternate grids.
    pub fn resize(&self, cols: u32, rows: u32) {
        lock_recover(&self.inner).resize(cols as usize, rows as usize);
    }

    pub fn cursor_row(&self) -> u32 {
        lock_recover(&self.inner).cursor().0 as u32
    }

    pub fn cursor_col(&self) -> u32 {
        lock_recover(&self.inner).cursor().1 as u32
    }

    pub fn cursor_visible(&self) -> bool {
        lock_recover(&self.inner).cursor_visible()
    }

    pub fn cursor_style(&self) -> FfiCursorStyle {
        lock_recover(&self.inner).cursor_style().into()
    }

    /// Sets the host's cursor style.
    pub fn set_default_cursor_style(&self, shape: FfiCursorShape, blinking: bool) {
        let mut term = lock_recover(&self.inner);
        term.terminal
            .set_default_cursor_style(crate::cursor_style::CursorStyle {
                shape: shape.into(),
                blinking,
            });
    }

    pub fn title(&self) -> String {
        lock_recover(&self.inner).title().to_string()
    }

    pub fn cols(&self) -> u32 {
        lock_recover(&self.inner).active_grid().cols() as u32
    }

    pub fn rows(&self) -> u32 {
        lock_recover(&self.inner).active_grid().rows() as u32
    }

    /// Returns the styled cell at (row, col) in the currently active grid.
    pub fn get_cell(&self, row: u32, col: u32) -> Option<FfiCell> {
        let terminal = lock_recover(&self.inner);
        let grid = terminal.active_grid();
        grid.get(row as usize, col as usize).map(|cell| {
            let hyperlink_uri = cell
                .hyperlink
                .and_then(|id| terminal.hyperlink_uri(id))
                .map(str::to_string);
            let (dfg, dbg, _) = terminal.default_colors();
            cell_to_ffi(
                cell,
                hyperlink_uri,
                grapheme_text(grid, cell),
                terminal.palette(),
                dfg.unwrap_or(DEFAULT_FG),
                dbg.unwrap_or(DEFAULT_BG),
            )
        })
    }

    /// Returns the plain-text characters of one row of the active grid.
    pub fn get_line(&self, row: u32) -> String {
        let terminal = lock_recover(&self.inner);
        let grid = terminal.active_grid();
        let row = row as usize;
        if row >= grid.rows() {
            return String::new();
        }
        let mut line = String::with_capacity(grid.cols());
        for col in 0..grid.cols() {
            match grid.get(row, col) {
                Some(cell) => {
                    line.push(cell.char);
                    line.push_str(grid.grapheme(cell));
                }
                None => line.push(' '),
            }
        }
        line
    }

    /// Returns bounded plain text from start_row for up to max_rows lines.
    pub fn get_plain_text(&self, start_row: u32, max_rows: u32) -> String {
        let terminal = lock_recover(&self.inner);
        let rows = terminal.active_grid().rows();
        if start_row as usize >= rows {
            return String::new();
        }
        let end_row = (start_row as usize + max_rows as usize).min(rows);
        let grid = terminal.active_grid();
        let mut lines = Vec::new();
        let mut current = String::new();
        for r in (start_row as usize)..end_row {
            for cell in terminal.viewport_row(r) {
                if cell.is_wide_spacer || cell.is_wide_spacer_head {
                    continue;
                }
                grid.push_cell_text(&mut current, &cell);
            }
            if r + 1 == end_row || !terminal.viewport_line_wrapped(r + 1) {
                while current.ends_with(' ') {
                    current.pop();
                }
                lines.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            while current.ends_with(' ') {
                current.pop();
            }
            lines.push(current);
        }
        while lines.last().is_some_and(|l| l.is_empty()) {
            lines.pop();
        }
        lines.join("\n")
    }

    /// Everything the terminal holds as plain text.
    pub fn buffer_text(&self) -> String {
        lock_recover(&self.inner).buffer_text()
    }

    /// The last `max_lines` lines of `buffer_text`, at most `max_bytes` of them.
    pub fn text_tail(&self, max_lines: u32, max_bytes: u32) -> FfiTextTail {
        let tail = lock_recover(&self.inner).text_tail(max_lines as usize, max_bytes as usize);
        FfiTextTail {
            text: tail.text,
            lines: tail.lines as u32,
            truncated: tail.truncated,
            more: tail.more,
        }
    }

    /// Sets the host's base theme.
    pub fn set_base_colors(
        &self,
        foreground: Option<FfiRgb>,
        background: Option<FfiRgb>,
        cursor: Option<FfiRgb>,
        palette: Vec<FfiPaletteEntry>,
    ) {
        let mut term = lock_recover(&self.inner);
        let entries: Vec<(u8, (u8, u8, u8))> = palette
            .into_iter()
            .map(|entry| (entry.index, entry.color.into()))
            .collect();
        term.terminal.set_base_colors(
            foreground.map(Into::into),
            background.map(Into::into),
            cursor.map(Into::into),
            &entries,
        );
        term.terminal.mark_all_damaged();
    }

    /// Tells the engine whether the host shows a dark or a light colour scheme.
    pub fn set_color_scheme(&self, dark: bool) {
        lock_recover(&self.inner).terminal.set_dark_scheme(dark);
    }

    /// Sets how many lines of history the terminal keeps; 0 keeps none.
    pub fn set_scrollback_limit(&self, lines: u32) {
        let mut term = lock_recover(&self.inner);
        term.terminal.set_scrollback_capacity(lines as usize);
    }

    /// Resets the terminal state completely, except the base colors.
    pub fn reset(&self) {
        let mut term = lock_recover(&self.inner);
        term.terminal = term.terminal.fresh_keeping_host_config();
        term.epoch = term.epoch.wrapping_add(1);
        lock_recover(&self.delta).reset_pending = true;
    }

    /// Currently live Kitty Graphics placements, in display order.
    pub fn graphics_placements(&self) -> Vec<FfiGraphicsPlacement> {
        lock_recover(&self.inner)
            .graphics_placements()
            .iter()
            .map(|p| FfiGraphicsPlacement {
                image_id: p.image_id,
                placement_id: p.placement_id,
                row: p.row as u32,
                col: p.col as u32,
            })
            .collect()
    }

    /// The decoded image data for a Kitty Graphics image id.
    pub fn graphics_image(&self, image_id: u32) -> Option<FfiStoredImage> {
        lock_recover(&self.inner)
            .graphics_image(image_id)
            .map(FfiStoredImage::from)
    }

    /// Metadata for a stored Kitty Graphics image.
    pub fn graphics_image_metadata(&self, image_id: u32) -> Option<FfiGraphicsImageMetadata> {
        lock_recover(&self.inner)
            .graphics_image(image_id)
            .map(|image| FfiGraphicsImageMetadata {
                format: image.format.into(),
                width: image.width,
                height: image.height,
                generation: image.generation,
            })
    }

    /// Maximum image memory (in bytes) configured for this terminal.
    pub fn max_image_memory_bytes(&self) -> u64 {
        lock_recover(&self.inner).max_image_memory_bytes()
    }

    /// Set maximum image memory (in bytes) for this terminal.
    pub fn set_max_image_memory_bytes(&self, max: u64) {
        lock_recover(&self.inner).set_max_image_memory_bytes(max);
    }
}
