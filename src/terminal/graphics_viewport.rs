/*
 * tako — Terminal emulation engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::state::Terminal;
use super::types::{GraphicsPlacement, ScreenBuffer};
use crate::terminal::perform::kitty_geometry::placement_spans;

impl Terminal {
    pub(crate) fn graphics_live_top(&self) -> i64 {
        self.active_grid()
            .first_retained_line()
            .saturating_add(self.active_grid().scrollback_len() as u64)
            .min(i64::MAX as u64) as i64
    }

    fn graphics_row_span(&self, p: &GraphicsPlacement) -> i64 {
        let grid = self.active_grid();
        let cols = grid.cols().max(1) as u32;
        let rows = grid.rows().max(1) as u32;
        let cw = if self.width_px > 0 {
            (self.width_px / cols).max(1)
        } else {
            10
        };
        let ch = if self.height_px > 0 {
            (self.height_px / rows).max(1)
        } else {
            20
        };
        let size = self
            .graphics
            .image(p.image_id)
            .map(|image| (image.width, image.height))
            .unwrap_or((1, 1));
        placement_spans(p.options, size, (cw, ch))
            .1
            .max(1)
            .min(i64::MAX as usize) as i64
    }

    /// Placements intersecting the viewport and their signed row offsets.
    /// A negative offset keeps the top of a partially visible image outside
    /// the viewport, where the renderer clips it rather than rescaling it.
    pub(crate) fn viewport_graphics_placements(&self) -> Vec<(GraphicsPlacement, i32)> {
        let top = self
            .graphics_live_top()
            .saturating_sub(self.viewport_offset.min(i64::MAX as usize) as i64);
        let bottom = top.saturating_add(self.active_grid().rows() as i64);
        self.graphics_placements
            .iter()
            .filter_map(|p| {
                let visible_start = p.line.saturating_add(i64::from(p.clip_top_rows));
                let visible_end = p
                    .line
                    .saturating_add(self.graphics_row_span(p))
                    .saturating_sub(i64::from(p.clip_bottom_rows));
                if p.screen != self.active
                    || visible_start >= bottom
                    || visible_end <= top
                    || visible_start >= visible_end
                {
                    return None;
                }
                let mut visible = *p;
                let offset = if p.line < top {
                    visible.row = 0;
                    -(top.saturating_sub(p.line).min(i64::from(i32::MAX)) as i32)
                } else {
                    visible.row = usize::try_from(p.line - top).unwrap_or(usize::MAX);
                    0
                };
                Some((visible, offset))
            })
            .collect()
    }

    /// Keep the legacy live-screen row in sync while absolute anchors retain
    /// placements that have moved into scrollback.
    pub(crate) fn reindex_graphics_rows(&mut self) {
        if self.graphics_placements.is_empty() {
            return;
        }
        let top = self.graphics_live_top();
        for p in &mut self.graphics_placements {
            if p.screen == self.active {
                p.row = usize::try_from(p.line.saturating_sub(top).max(0)).unwrap_or(usize::MAX);
            }
        }
    }

    pub(crate) fn refresh_graphics_rows(&mut self) {
        self.reindex_graphics_rows();
        if self.graphics_placements.is_empty() {
            return;
        }
        let first = self
            .active_grid()
            .first_retained_line()
            .min(i64::MAX as u64) as i64;
        let grid = self.active_grid();
        let cols = grid.cols().max(1) as u32;
        let rows = grid.rows().max(1) as u32;
        let cw = if self.width_px > 0 {
            (self.width_px / cols).max(1)
        } else {
            10
        };
        let ch = if self.height_px > 0 {
            (self.height_px / rows).max(1)
        } else {
            20
        };
        let before = self.graphics_placements.len();
        let images = &self.graphics;
        self.graphics_placements.retain(|p| {
            let Some(image) = images.image(p.image_id) else {
                return false;
            };
            if p.screen != self.active {
                return true;
            }
            let span = placement_spans(p.options, (image.width, image.height), (cw, ch))
                .1
                .max(1)
                .min(i64::MAX as usize) as i64;
            p.line
                .saturating_add(span)
                .saturating_sub(i64::from(p.clip_bottom_rows))
                > first
        });
        if self.graphics_placements.len() != before {
            self.rebuild_graphics_placements();
        }
    }

    pub(crate) fn clear_graphics_screen(&mut self, screen: ScreenBuffer) {
        self.graphics_placements.retain(|p| p.screen != screen);
        self.rebuild_graphics_placements();
    }

    /// Clear images intersecting the live screen, leaving earlier history.
    pub(crate) fn clear_visible_graphics(&mut self) {
        let top = self.graphics_live_top();
        let bottom = top.saturating_add(self.active_grid().rows() as i64);
        self.graphics_placements = self
            .graphics_placements
            .iter()
            .copied()
            .filter(|p| {
                p.screen != self.active
                    || p.line.saturating_add(i64::from(p.clip_top_rows)) >= bottom
                    || p.line
                        .saturating_add(self.graphics_row_span(p))
                        .saturating_sub(i64::from(p.clip_bottom_rows))
                        <= top
            })
            .collect();
        self.rebuild_graphics_placements();
    }

    pub(crate) fn rebuild_graphics_placements(&mut self) {
        self.graphics.placements = self
            .graphics_placements
            .iter()
            .map(|p| crate::graphics::Placement {
                image_id: p.image_id,
                placement_id: p.placement_id,
                options: p.options,
            })
            .collect();
    }
}
