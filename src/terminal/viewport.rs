/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::state::Terminal;

impl Terminal {
    /// Scroll the viewport back in history by `n` lines, clamped by
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

    /// Keep viewport anchored when new lines are appended to scrollback.
    pub(crate) fn keep_viewport_anchored(&mut self, scrollback_before: usize) {
        if self.viewport_offset == 0 {
            return;
        }
        let now = self.active_grid().scrollback_len();
        let grown = now.saturating_sub(scrollback_before);
        if grown == 0 {
            return;
        }
        self.viewport_offset = (self.viewport_offset + grown).min(now);
        self.active_grid_mut().mark_all_dirty();
    }
}
