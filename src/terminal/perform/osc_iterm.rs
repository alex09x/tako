/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::super::events::TerminalEvent;
use super::super::state::Terminal;
use super::super::types::{ClipboardPolicy, GraphicsPlacement};
use super::osc_iterm_size::{Dim, InlineBox, inline_box};
use crate::graphics::PlacementOptions;

impl Terminal {
    pub(crate) fn handle_osc_1337(&mut self, params: &[&[u8]]) {
        if params.len() > 1 && params[1].starts_with(b"File=") {
            let joined: Vec<u8> = params[1..].join(&b';');
            if let Some(colon_idx) = joined.iter().position(|&b| b == b':') {
                let args_bytes = &joined[5..colon_idx];
                let payload_bytes = &joined[colon_idx + 1..];
                let args_str = String::from_utf8_lossy(args_bytes);
                let mut is_inline = false;
                let mut width_arg: Option<Dim> = None;
                let mut height_arg: Option<Dim> = None;
                for part in args_str.split(';') {
                    if let Some((k, v)) = part.split_once('=') {
                        match k.trim() {
                            "inline" => is_inline = v.trim() == "1",
                            "width" => width_arg = Dim::parse(v.trim()),
                            "height" => height_arg = Dim::parse(v.trim()),
                            // preserveAspectRatio=0 (stretch) is not supported:
                            // the image is always fitted, see osc_iterm_size.
                            _ => {}
                        }
                    }
                }
                if is_inline {
                    use base64::Engine as _;
                    const MAX_IMAGE_RAW_BYTES: usize =
                        crate::graphics::DEFAULT_MAX_IMAGE_MEMORY_BYTES as usize;
                    if payload_bytes.len() <= MAX_IMAGE_RAW_BYTES * 4 / 3 + 4096 {
                        let cleaned: Vec<u8> = payload_bytes
                            .iter()
                            .copied()
                            .filter(|b| !b.is_ascii_whitespace())
                            .collect();
                        if (cleaned.len().saturating_sub(2) * 3) / 4 <= MAX_IMAGE_RAW_BYTES
                            && let Ok(image_data) =
                                base64::engine::general_purpose::STANDARD.decode(&cleaned)
                        {
                            let (detected_w, detected_h) =
                                crate::graphics::detect_image_dimensions(&image_data)
                                    .unwrap_or((0, 0));
                            let grid_rows = self.active_grid().rows();
                            let grid_cols = self.active_grid().cols();
                            let cell_h = if grid_rows > 0 && self.height_px > 0 {
                                (self.height_px / grid_rows as u32).max(1)
                            } else {
                                20
                            };
                            let cell_w = if grid_cols > 0 && self.width_px > 0 {
                                (self.width_px / grid_cols as u32).max(1)
                            } else {
                                10
                            };

                            // The image keeps the size it is encoded at -- what the
                            // decoders check and the memory caps count; the size
                            // asked for is the placement's cell box.
                            let InlineBox {
                                columns,
                                rows,
                                advance,
                            } = inline_box(
                                (detected_w, detected_h),
                                width_arg,
                                height_arg,
                                (cell_w, cell_h),
                            );

                            if let Ok((image_id, placement_id)) =
                                self.graphics.store_and_place_raw_image(
                                    crate::graphics::ImageFormat::Png,
                                    detected_w,
                                    detected_h,
                                    image_data,
                                )
                            {
                                let place_row = self.cursor.row;
                                let place_col = self.cursor.col;
                                self.graphics_placements.push(GraphicsPlacement {
                                    image_id,
                                    placement_id,
                                    row: place_row,
                                    col: place_col,
                                    options: PlacementOptions {
                                        columns,
                                        rows,
                                        ..Default::default()
                                    },
                                    screen: self.active,
                                    line: self.graphics_live_top().saturating_add(place_row as i64),
                                    clip_top_rows: 0,
                                    clip_bottom_rows: 0,
                                });
                                for _ in 0..advance {
                                    self.line_feed();
                                }
                                self.cursor.col = 0;
                            }
                        }
                    }
                }
            }
        } else if let Some(first) = params.get(1) {
            let rest = String::from_utf8_lossy(first);
            let copy_b64 = if let Some(b64) = rest.strip_prefix("CopyToClipboard=") {
                Some(b64)
            } else if let Some(payload) = rest.strip_prefix("Copy=") {
                Some(payload.split_once(':').map(|(_, b)| b).unwrap_or(payload))
            } else {
                None
            };
            if let Some(b64) = copy_b64 {
                if self.clipboard_policy != ClipboardPolicy::Disabled {
                    const MAX_CLIPBOARD_BYTES: usize = 1024 * 1024;
                    let non_ws_count = b64.chars().filter(|c| !c.is_ascii_whitespace()).count();
                    if b64.len() <= 2 * 1024 * 1024
                        && (non_ws_count.saturating_sub(2) * 3) / 4 <= MAX_CLIPBOARD_BYTES
                    {
                        use base64::Engine as _;
                        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64)
                            && bytes.len() <= MAX_CLIPBOARD_BYTES
                        {
                            self.events.push(TerminalEvent::ClipboardSet(
                                String::from_utf8_lossy(&bytes).into_owned(),
                            ));
                        }
                    }
                }
            } else if rest == "ClearStatus" {
                self.events.push(TerminalEvent::StatusClear);
            } else if let Some(status_part) = rest.strip_prefix("SetStatus=") {
                let mut status_val = status_part.to_string();
                let mut text_val = None;
                if let Some((s, t)) = status_part.split_once(';') {
                    status_val = s.to_string();
                    text_val = Some(t.to_string());
                } else if params.len() > 2 {
                    let joined = params[2..]
                        .iter()
                        .map(|p| String::from_utf8_lossy(p))
                        .collect::<Vec<_>>()
                        .join(";");
                    text_val = Some(joined);
                }
                if let Some(ref t) = text_val
                    && let Some(stripped) = t.strip_prefix("text=")
                {
                    text_val = Some(stripped.to_string());
                }
                if let Some(status) = Self::normalize_status_string(&status_val) {
                    if status == "clear" {
                        self.events.push(TerminalEvent::StatusClear);
                    } else {
                        let text = text_val.as_deref().and_then(Self::sanitize_status_text);
                        self.events.push(TerminalEvent::StatusSet { status, text });
                    }
                }
            }
        }
    }
}
