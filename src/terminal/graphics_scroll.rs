/*
 * tako — Terminal emulation engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::perform::kitty_geometry::placement_spans;
use super::state::Terminal;

impl Terminal {
    /// Move images wholly inside the scrolling page. Keep clipped portions
    /// clipped on later moves; full-width top scrolls retain them in history.
    pub(crate) fn scroll_graphics_region(&mut self, count: usize, up: bool) {
        if count == 0 || self.graphics_placements.is_empty() {
            return;
        }
        let grid = self.active_grid();
        let rows = grid.rows();
        let top = self.scroll_top;
        let bottom = self.scroll_bottom.min(rows.saturating_sub(1));
        if top > bottom {
            return;
        }
        let n = count.min(bottom - top + 1) as i64;
        let live_top = self.graphics_live_top();
        let page_top = live_top.saturating_add(top as i64);
        let page_bottom = live_top.saturating_add(bottom as i64 + 1);
        let live_bottom = live_top.saturating_add(rows as i64);
        let (left, right) = self.h_margins();
        let pushes_history = up && top == 0 && self.h_margins_full();
        // A whole-screen scroll carries every image, including one that was
        // placed near the bottom and is still extending beyond the screen.
        if pushes_history && bottom + 1 == rows {
            return;
        }
        let cols = grid.cols().max(1) as u32;
        let row_count = rows.max(1) as u32;
        let cw = if self.width_px > 0 {
            (self.width_px / cols).max(1)
        } else {
            10
        };
        let ch = if self.height_px > 0 {
            (self.height_px / row_count).max(1)
        } else {
            20
        };
        let before = self.graphics_placements.len();
        let images = &self.graphics;
        self.graphics_placements.retain_mut(|p| {
            if p.screen != self.active {
                return true;
            }
            let Some(image) = images.image(p.image_id) else {
                return false;
            };
            let (columns, height) =
                placement_spans(p.options, (image.width, image.height), (cw, ch));
            let height = height.max(1).min(i64::MAX as usize) as i64;
            let start = p.line.saturating_add(i64::from(p.clip_top_rows));
            let end = p
                .line
                .saturating_add(height)
                .saturating_sub(i64::from(p.clip_bottom_rows));
            let within_columns =
                p.col >= left && p.col.saturating_add(columns) <= right.saturating_add(1);
            let inside = within_columns && start >= page_top && end <= page_bottom && start < end;
            if !inside {
                // Stashing the top region advances the live screen's absolute
                // base; windows below the region remain at the same screen row.
                if pushes_history && p.line >= live_top && start < live_bottom && end > live_top {
                    p.line = p.line.saturating_add(n);
                }
                return true;
            }
            if pushes_history {
                return true;
            }
            if up {
                p.line = p.line.saturating_sub(n);
                let clipped = page_top
                    .saturating_sub(p.line)
                    .max(0)
                    .min(i64::from(u32::MAX)) as u32;
                p.clip_top_rows = p.clip_top_rows.max(clipped);
            } else {
                p.line = p.line.saturating_add(n);
                let clipped = p
                    .line
                    .saturating_add(height)
                    .saturating_sub(page_bottom)
                    .max(0)
                    .min(i64::from(u32::MAX)) as u32;
                p.clip_bottom_rows = p.clip_bottom_rows.max(clipped);
            }
            i64::from(p.clip_top_rows).saturating_add(i64::from(p.clip_bottom_rows)) < height
        });
        if self.graphics_placements.len() != before {
            self.rebuild_graphics_placements();
        }
    }
}
