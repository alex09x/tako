/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::core::{TakoCore, lock_recover};
use super::pack::{
    collapse_row_ranges, packed_rows_from_terminal, snapshot_from_terminal,
    viewport_packed_from_terminal,
};
use super::render_types::{
    FfiRenderFrame, FfiRenderFrameDelta, FfiRenderFrameOverscan, FfiResyncReason, FfiSnapshot,
};
use super::types::{
    DEFAULT_BG, DEFAULT_FG, FfiCell, FfiGrapheme, FfiGraphemeWidthMethod, MAX_OVERSCAN_ROWS,
    PACKED_CELL_SIZE, cell_to_ffi, grapheme_text,
};
use crate::terminal::ScreenBuffer;

#[uniffi::export]
impl TakoCore {
    /// Rows changed since the last call (viewport indices); clears the flags.
    pub fn take_damage(&self) -> Vec<u32> {
        let mut terminal = lock_recover(&self.inner);
        let rows = terminal.take_damage();
        lock_recover(&self.delta).foreign_drain = true;
        rows
    }

    /// Forces a full redraw on the next `takeDamage()`.
    pub fn mark_all_damaged(&self) {
        lock_recover(&self.inner).mark_all_damaged();
    }

    /// Geometry, cursor, title, modes, viewport, damaged rows, selection, placements.
    pub fn snapshot(&self) -> FfiSnapshot {
        let mut terminal = lock_recover(&self.inner);
        let snapshot = snapshot_from_terminal(&mut terminal);
        lock_recover(&self.delta).foreign_drain = true;
        snapshot
    }

    /// Scrolls the viewport up into scrollback by `lines`.
    pub fn scroll_viewport_up(&self, lines: u32) {
        lock_recover(&self.inner).scroll_viewport_up(lines as usize);
    }

    /// Scrolls the viewport back down toward the live screen.
    pub fn scroll_viewport_down(&self, lines: u32) {
        lock_recover(&self.inner).scroll_viewport_down(lines as usize);
    }

    /// Snaps the viewport back to the live screen.
    pub fn scroll_viewport_bottom(&self) {
        lock_recover(&self.inner).scroll_viewport_bottom();
    }

    /// Current viewport offset above the live screen, in lines.
    pub fn viewport_offset(&self) -> u32 {
        lock_recover(&self.inner).viewport_offset() as u32
    }

    /// Lines currently retained in scrollback.
    pub fn scrollback_len(&self) -> u32 {
        lock_recover(&self.inner).active_grid().scrollback_len() as u32
    }

    /// One viewport row as styled cells.
    pub fn viewport_row(&self, row: u32) -> Vec<FfiCell> {
        let terminal = lock_recover(&self.inner);
        let (dfg, dbg, _) = terminal.default_colors();
        let palette = terminal.palette();
        let grid = terminal.active_grid();
        terminal
            .viewport_row(row as usize)
            .iter()
            .map(|cell| {
                let uri = cell
                    .hyperlink
                    .and_then(|id| terminal.hyperlink_uri(id))
                    .map(str::to_string);
                cell_to_ffi(
                    cell,
                    uri,
                    grapheme_text(grid, cell),
                    palette,
                    dfg.unwrap_or(DEFAULT_FG),
                    dbg.unwrap_or(DEFAULT_BG),
                )
            })
            .collect()
    }

    /// The whole viewport as packed bytes: 16 per cell, rows top to bottom.
    pub fn viewport_packed(&self) -> Vec<u8> {
        let terminal = lock_recover(&self.inner);
        viewport_packed_from_terminal(&terminal).0
    }

    /// The clusters of the cells `viewport_packed` marks `PACKED_GRAPHEME`.
    pub fn viewport_graphemes(&self) -> Vec<FfiGrapheme> {
        let terminal = lock_recover(&self.inner);
        viewport_packed_from_terminal(&terminal).1
    }

    /// Sets the host's grapheme-width-method.
    pub fn set_grapheme_width_method(&self, method: FfiGraphemeWidthMethod) {
        lock_recover(&self.inner).set_grapheme_width_method(method.into());
    }

    /// Single call per frame: snapshot + packed viewport cells under one lock.
    pub fn render_frame(&self) -> FfiRenderFrame {
        let mut engine = lock_recover(&self.inner);
        let epoch = engine.epoch;
        let snapshot = snapshot_from_terminal(&mut engine);
        let (packed_cells, graphemes) = viewport_packed_from_terminal(&engine);
        lock_recover(&self.delta).foreign_drain = true;
        FfiRenderFrame {
            snapshot,
            packed_cells,
            epoch,
            graphemes,
        }
    }

    /// `render_frame`, plus up to `rows_below` rows from beneath the viewport.
    pub fn render_frame_overscan(&self, rows_below: u32) -> FfiRenderFrameOverscan {
        let mut terminal = lock_recover(&self.inner);
        let epoch = terminal.epoch;
        let snapshot = snapshot_from_terminal(&mut terminal);
        let overscan_rows = rows_below.min(MAX_OVERSCAN_ROWS);
        let rows = terminal.active_grid().rows() as u32;
        let indices: Vec<u32> = (0..rows.saturating_add(overscan_rows)).collect();
        let (packed_cells, graphemes) = packed_rows_from_terminal(&terminal, &indices);
        lock_recover(&self.delta).foreign_drain = true;
        FfiRenderFrameOverscan {
            snapshot,
            packed_cells,
            overscan_rows,
            epoch,
            graphemes,
        }
    }

    /// One frame for a host that keeps its own row cache.
    pub fn render_frame_delta(&self, since_version: u64) -> FfiRenderFrameDelta {
        let mut terminal = lock_recover(&self.inner);
        let mut state = lock_recover(&self.delta);

        let mut snapshot = snapshot_from_terminal(&mut terminal);
        let cols = snapshot.cols;
        let rows = snapshot.rows;
        let viewport_offset = snapshot.viewport_offset;
        let alternate = terminal.active_screen() == ScreenBuffer::Alternate;

        let reason = if !state.started {
            FfiResyncReason::FirstFrame
        } else if state.reset_pending {
            FfiResyncReason::Reset
        } else if since_version != state.version {
            FfiResyncReason::VersionMismatch
        } else if state.foreign_drain {
            FfiResyncReason::DamageOwnershipLost
        } else if cols != state.cols || rows != state.rows {
            FfiResyncReason::Resized
        } else if viewport_offset != state.viewport_offset {
            FfiResyncReason::ViewportScrolled
        } else if alternate != state.alternate {
            FfiResyncReason::ScreenSwitched
        } else if rows > 0 && snapshot.damaged_rows.len() as u32 >= rows {
            FfiResyncReason::FullDamage
        } else {
            FfiResyncReason::Delta
        };
        let full_resync = reason != FfiResyncReason::Delta;

        let row_indices: Vec<u32> = if full_resync {
            (0..rows).collect()
        } else {
            snapshot.damaged_rows.clone()
        };
        let (packed_cells, graphemes) = packed_rows_from_terminal(&terminal, &row_indices);

        snapshot.damaged_rows = row_indices.clone();
        let row_ranges = collapse_row_ranges(&row_indices);

        let base_version = if full_resync { 0 } else { state.version };
        let frame_version = state.version + 1;

        state.version = frame_version;
        state.started = true;
        state.cols = cols;
        state.rows = rows;
        state.viewport_offset = viewport_offset;
        state.alternate = alternate;
        state.reset_pending = false;
        state.foreign_drain = false;

        FfiRenderFrameDelta {
            snapshot,
            frame_version,
            base_version,
            full_resync,
            resync_reason: reason,
            cols,
            rows,
            cell_stride: PACKED_CELL_SIZE as u32,
            row_stride: cols * PACKED_CELL_SIZE as u32,
            row_indices,
            row_ranges,
            packed_cells,
            graphemes,
        }
    }

    /// Scrolls to a specific viewport offset.
    pub fn scroll_to(&self, offset: u32) {
        let mut term = lock_recover(&self.inner);
        term.scroll_viewport_bottom();
        if offset > 0 {
            term.scroll_viewport_up(offset as usize);
        }
    }

    /// Where the viewport sits as a fraction (0 oldest, 1 live).
    pub fn scroll_position(&self) -> f64 {
        lock_recover(&self.inner).scroll_position()
    }

    /// Restores a fraction from `scroll_position`.
    pub fn set_scroll_position(&self, position: f64) {
        lock_recover(&self.inner).set_scroll_position(position);
    }
}
