/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::palette;

use super::super::state::Terminal;

impl Terminal {
    pub(crate) fn handle_osc_palette(&mut self, params: &[&[u8]], bell_terminated: bool) -> bool {
        if params[0] == b"4" {
            let mut i = 1;
            while i + 1 < params.len() {
                if let Ok(index) = String::from_utf8_lossy(params[i]).parse::<u8>() {
                    let spec = String::from_utf8_lossy(params[i + 1]);
                    if spec.as_ref() == "?" {
                        let reply = self.palette.query_response(index);
                        self.response.push_str(&reply);
                    } else if let Some(rgb) = palette::parse_color_spec(&spec) {
                        self.palette.set(index, rgb);
                    }
                }
                i += 2;
            }
            return true;
        }

        if params[0] == b"104" {
            if params.len() <= 1 {
                self.palette.reset_all();
            } else {
                for raw in &params[1..] {
                    if let Ok(index) = String::from_utf8_lossy(raw).parse::<u8>() {
                        self.palette.reset(index);
                    }
                }
            }
            return true;
        }

        if matches!(params[0], b"10" | b"11" | b"12") {
            let base: u16 = match params[0] {
                b"10" => 10,
                b"11" => 11,
                _ => 12,
            };
            let terminator = if bell_terminated { "\x07" } else { "\x1b\\" };
            for (k, arg) in params[1..].iter().enumerate() {
                let slot = base + k as u16;
                if slot > 12 {
                    break;
                }
                let arg_str = String::from_utf8_lossy(arg);
                if arg_str.as_ref() == "?" {
                    let color = match slot {
                        10 => self.default_fg,
                        11 => self.default_bg,
                        _ => self.cursor_color.or(self.default_fg),
                    };
                    if let Some((r, g, b)) = color {
                        let reply = format!(
                            "\x1b]{};rgb:{:02x}{:02x}/{:02x}{:02x}/{:02x}{:02x}{}",
                            slot, r, r, g, g, b, b, terminator
                        );
                        self.response.push_str(&reply);
                    }
                } else if let Some(rgb) = palette::parse_color_spec(&arg_str) {
                    match slot {
                        10 => {
                            self.default_fg = Some(rgb);
                            self.palette.set_fg_overridden(true);
                        }
                        11 => {
                            self.default_bg = Some(rgb);
                            self.palette.set_bg_overridden(true);
                        }
                        _ => {
                            self.cursor_color = Some(rgb);
                            self.palette.set_cursor_overridden(true);
                        }
                    }
                }
            }
            return true;
        }

        if params[0] == b"110" {
            self.default_fg = self.palette.base_fg();
            self.palette.set_fg_overridden(false);
            return true;
        }

        if params[0] == b"111" {
            self.default_bg = self.palette.base_bg();
            self.palette.set_bg_overridden(false);
            return true;
        }

        if params[0] == b"112" {
            self.cursor_color = self.palette.base_cursor();
            self.palette.set_cursor_overridden(false);
            return true;
        }

        false
    }
}
