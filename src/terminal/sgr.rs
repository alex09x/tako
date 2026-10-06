/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{CellAttrs, Color};

use super::state::Terminal;
use super::types::{SavedCursor, ScreenBuffer};

impl Terminal {
    pub(crate) fn sgr_reset(&mut self) {
        self.cursor.fg = Color::Default;
        self.cursor.bg = Color::Default;
        self.cursor.attrs = CellAttrs::empty();
        self.cursor.underline_style = 0;
        self.cursor.underline_color = Color::Default;
    }

    pub(crate) fn sgr(&mut self, params: &[u16], params_sep: u32) {
        if params.is_empty() {
            self.sgr_reset();
            return;
        }
        let mut groups: Vec<&[u16]> = Vec::new();
        let mut start = 0;
        for k in 0..params.len() {
            let colon_next = k < 15 && (params_sep >> k) & 1 == 1;
            if !colon_next || k + 1 == params.len() {
                groups.push(&params[start..=k]);
                start = k + 1;
            }
        }

        let mut gi = 0;
        while gi < groups.len() {
            let g = groups[gi];
            match g[0] {
                0 => self.sgr_reset(),
                1 => self.cursor.attrs.insert(CellAttrs::BOLD),
                2 => self.cursor.attrs.insert(CellAttrs::DIM),
                3 => self.cursor.attrs.insert(CellAttrs::ITALIC),
                4 => {
                    let style = g.get(1).copied().unwrap_or(1);
                    match style {
                        0 => {
                            self.cursor.attrs.remove(CellAttrs::UNDERLINE);
                            self.cursor.underline_style = 0;
                        }
                        s @ 1..=5 => {
                            self.cursor.attrs.insert(CellAttrs::UNDERLINE);
                            self.cursor.underline_style = s as u8;
                        }
                        _ => {}
                    }
                }
                5 | 6 => self.cursor.attrs.insert(CellAttrs::BLINK),
                7 => self.cursor.attrs.insert(CellAttrs::REVERSE),
                8 => self.cursor.attrs.insert(CellAttrs::HIDDEN),
                9 => self.cursor.attrs.insert(CellAttrs::STRIKETHROUGH),
                21 => {
                    self.cursor.attrs.insert(CellAttrs::UNDERLINE);
                    self.cursor.underline_style = 2;
                }
                22 => self.cursor.attrs.remove(CellAttrs::BOLD | CellAttrs::DIM),
                23 => self.cursor.attrs.remove(CellAttrs::ITALIC),
                24 => {
                    self.cursor.attrs.remove(CellAttrs::UNDERLINE);
                    self.cursor.underline_style = 0;
                }
                25 => self.cursor.attrs.remove(CellAttrs::BLINK),
                27 => self.cursor.attrs.remove(CellAttrs::REVERSE),
                28 => self.cursor.attrs.remove(CellAttrs::HIDDEN),
                29 => self.cursor.attrs.remove(CellAttrs::STRIKETHROUGH),
                53 => self.cursor.attrs.insert(CellAttrs::OVERLINE),
                55 => self.cursor.attrs.remove(CellAttrs::OVERLINE),
                code @ 30..=37 => self.cursor.fg = Color::Indexed((code - 30) as u8),
                code @ 40..=47 => self.cursor.bg = Color::Indexed((code - 40) as u8),
                code @ 90..=97 => self.cursor.fg = Color::Indexed((code - 90 + 8) as u8),
                code @ 100..=107 => self.cursor.bg = Color::Indexed((code - 100 + 8) as u8),
                39 => self.cursor.fg = Color::Default,
                49 => self.cursor.bg = Color::Default,
                59 => self.cursor.underline_color = Color::Default,
                code @ (38 | 48 | 58) => {
                    let (color, consumed_groups) = if g.len() >= 2 {
                        (Self::parse_extended_color_group(g), 0)
                    } else {
                        let rest: Vec<u16> = groups[gi + 1..]
                            .iter()
                            .take(4)
                            .flat_map(|gr| gr.iter().copied())
                            .collect();
                        match rest.first() {
                            Some(5) if rest.len() >= 2 => (Some(Color::Indexed(rest[1] as u8)), 2),
                            Some(2) if rest.len() >= 4 => (
                                Some(Color::Rgb(rest[1] as u8, rest[2] as u8, rest[3] as u8)),
                                4,
                            ),
                            _ => (None, 0),
                        }
                    };
                    if let Some(color) = color {
                        match code {
                            38 => self.cursor.fg = color,
                            48 => self.cursor.bg = color,
                            _ => self.cursor.underline_color = color,
                        }
                    }
                    gi += consumed_groups;
                }
                _ => {}
            }
            gi += 1;
        }
    }

    pub(crate) fn parse_extended_color_group(g: &[u16]) -> Option<Color> {
        match g.get(1)? {
            5 => Some(Color::Indexed(*g.get(2)? as u8)),
            2 => {
                let (r, gg, b) = if g.len() >= 6 {
                    (g[3], g[4], g[5])
                } else if g.len() >= 5 {
                    (g[2], g[3], g[4])
                } else {
                    return None;
                };
                Some(Color::Rgb(r as u8, gg as u8, b as u8))
            }
            _ => None,
        }
    }

    pub(crate) fn cursor_to_home(&mut self) {
        if self.modes.origin_mode {
            self.cursor.row = self.scroll_top.min(self.scroll_bottom);
            self.cursor.col = self.h_margins().0;
        } else {
            self.cursor.row = 0;
            self.cursor.col = 0;
        }
        self.pending_wrap = false;
    }

    pub(crate) fn restore_saved_cursor(&mut self) {
        let Some(saved) = self.cursor.saved else {
            return;
        };
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        self.cursor.row = saved.row.min(rows.saturating_sub(1));
        self.cursor.col = saved.col.min(cols.saturating_sub(1));
        self.cursor.fg = saved.fg;
        self.cursor.bg = saved.bg;
        self.cursor.attrs = saved.attrs;
        self.g0 = saved.g0;
        self.g1 = saved.g1;
        self.shift_out = saved.shift_out;
        self.modes.origin_mode = saved.origin_mode;
        self.pending_wrap = saved.pending_wrap;
        self.protected_mode = saved.protected_mode;
        self.gr_slot = saved.gr_slot;
    }

    pub(crate) fn csi_private_mode(&mut self, params: &[u16], action: char) {
        let set = action == 'h';
        for &p in params {
            self.modes.apply_private_mode(p, set);
            if p == 69 && !set {
                self.scroll_left = 0;
                self.scroll_right = self.active_grid().cols().saturating_sub(1);
            }
            match p {
                25 => self.cursor_visible = set,
                6 => self.cursor_to_home(),
                47 => {
                    if set {
                        self.switch_screen(ScreenBuffer::Alternate);
                    } else {
                        self.switch_screen(ScreenBuffer::Primary);
                    }
                }
                1047 => {
                    if set {
                        if self.active == ScreenBuffer::Primary {
                            self.switch_screen(ScreenBuffer::Alternate);
                        }
                    } else if self.active == ScreenBuffer::Alternate {
                        self.alternate.clear_all();
                        self.switch_screen(ScreenBuffer::Primary);
                    }
                }
                1049 => {
                    if set {
                        if self.active == ScreenBuffer::Primary {
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
                            self.switch_screen(ScreenBuffer::Alternate);
                            self.alternate.clear_all();
                        }
                    } else if self.active == ScreenBuffer::Alternate {
                        self.switch_screen(ScreenBuffer::Primary);
                        self.restore_saved_cursor();
                    }
                }
                _ => {}
            }
        }
    }
}
