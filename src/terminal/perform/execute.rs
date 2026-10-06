/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::graphics::GraphicsResponse;

use super::super::events::TerminalEvent;
use super::super::state::Terminal;
use super::super::types::{
    DcsKind, GraphicsPlacement, MAX_INLINE_IMAGE_PIXEL_DIM, MAX_INLINE_IMAGE_ROW_SPAN,
    ProtectedMode, SavedCursor,
};

impl Terminal {
    pub(crate) fn perform_execute(&mut self, byte: u8) {
        match byte {
            0x0A => {
                if self.modes.linefeed_mode {
                    self.cursor.col = 0;
                }
                self.line_feed();
            }
            0x0D => {
                let (hl, _) = self.h_margins();
                self.cursor.col = if self.modes.origin_mode || self.cursor.col >= hl {
                    hl
                } else {
                    0
                };
                self.pending_wrap = false;
            }
            0x08 => {
                self.cursor.col = self.cursor.col.saturating_sub(1);
                self.pending_wrap = false;
            }
            0x09 => {
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
            0x0E => self.shift_out = true,
            0x0F => self.shift_out = false,
            0x05 => {
                let s = self.answerback.clone();
                self.response.push_str(&s);
            }
            0x07 => self.events.push(TerminalEvent::Bell),
            _ => {}
        }
    }

    pub(crate) fn perform_hook(
        &mut self,
        _params: &[u16],
        _params_sep: u32,
        intermediates: &[u8],
        _ignore: bool,
        action: char,
    ) {
        self.dcs_buf.clear();
        self.dcs = match (intermediates, action) {
            ([b'$'], 'q') => Some(DcsKind::Decrqss),
            ([b'+'], 'q') => Some(DcsKind::XtGetTcap),
            _ => None,
        };
    }

    pub(crate) fn perform_put(&mut self, byte: u8) {
        if self.dcs.is_some() {
            if self.dcs_buf.len() < 256 {
                self.dcs_buf.push(byte);
            } else {
                self.dcs = None;
                self.dcs_buf.clear();
            }
        }
    }

    pub(crate) fn perform_unhook(&mut self) {
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

    pub(crate) fn perform_esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
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
            b'H' => self.tabstops.set(self.cursor.col),
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
            b'D' => self.line_feed(),
            b'M' => self.reverse_index(),
            b'E' => {
                self.cursor.col = 0;
                self.line_feed();
            }
            b'N' => self.single_shift = Some(self.g2),
            b'O' => self.single_shift = Some(self.g3),
            b'~' => self.gr_slot = 1,
            b'}' => self.gr_slot = 2,
            b'|' => self.gr_slot = 3,
            b'6' => self.back_index(),
            b'9' => self.forward_index(),
            b'c' => self.hard_reset(),
            b'V' => self.protected_mode = ProtectedMode::Iso,
            b'W' => self.protected_mode = ProtectedMode::Off,
            _ => {}
        }
    }

    pub(crate) fn perform_apc_dispatch(&mut self, data: &[u8]) {
        if data.first() != Some(&b'G') {
            return;
        }
        let rest = &data[1..];
        let (control, payload) = match rest.iter().position(|&b| b == b';') {
            Some(i) => (&rest[..i], &rest[i + 1..]),
            None => (rest, &[][..]),
        };
        let control = String::from_utf8_lossy(control);
        let resp = self.graphics.handle(&control, payload);
        if let Some(reply) = self.graphics.take_last_reply() {
            self.response.push_str(&reply);
        }
        match resp {
            GraphicsResponse::Displayed {
                image_id,
                placement_id,
            } => {
                let place_row = self.cursor.row;
                let place_col = self.cursor.col;
                self.graphics_placements.push(GraphicsPlacement {
                    image_id,
                    placement_id,
                    row: place_row,
                    col: place_col,
                });
                let cmd = crate::graphics::parse_control_data(&control);
                if cmd.get_u32('C') != Some(1) {
                    let rows_span = if let Some(r) = cmd.get_u32('r') {
                        (r as usize).clamp(1, MAX_INLINE_IMAGE_ROW_SPAN)
                    } else if let Some(img) = self.graphics.image(image_id) {
                        if img.height > 0 {
                            let grid_rows = self.active_grid().rows();
                            let cell_h = if grid_rows > 0 && self.height_px > 0 {
                                (self.height_px / grid_rows as u32).max(1)
                            } else {
                                20
                            };
                            let h = img.height.min(MAX_INLINE_IMAGE_PIXEL_DIM);
                            ((h.saturating_add(cell_h).saturating_sub(1)) / cell_h)
                                .min(MAX_INLINE_IMAGE_ROW_SPAN as u32)
                                .max(1) as usize
                        } else {
                            1
                        }
                    } else {
                        1
                    };
                    for _ in 0..rows_span.min(MAX_INLINE_IMAGE_ROW_SPAN) {
                        self.line_feed();
                    }
                    self.cursor.col = 0;
                    self.pending_wrap = false;
                }
            }
            GraphicsResponse::Deleted { image_ids } => {
                self.graphics_placements
                    .retain(|p| !image_ids.contains(&p.image_id));
            }
            _ => {}
        }
    }
}
