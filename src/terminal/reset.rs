/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::charset::Charset;
use crate::cursor_style::CursorShape;
use crate::grid::{Cell, CellAttrs, Color, Grid};
use crate::kitty_keyboard::KittyKeyboardState;
use crate::modes::TerminalModes;
use crate::tabstops::TabStops;
use crate::title_stack::TitleStack;

use super::state::Terminal;
use super::types::{Cursor, GraphemeWidthMethod, ProtectedMode, ScreenBuffer};

impl Terminal {
    /// Maps an SCS final byte to the charset it designates.
    pub(crate) fn charset_for_designator(byte: u8) -> Charset {
        match byte {
            b'0' => Charset::DecSpecialGraphics,
            b'A' => Charset::British,
            _ => Charset::Ascii,
        }
    }

    /// DECRQSS (`DCS $ q <setting> ST`): report the current value of a setting.
    pub(crate) fn decrqss(&mut self, req: &[u8]) {
        let reply = match req {
            b"m" => {
                let mut out = String::from("0");
                let a = self.cursor.attrs;
                if a.contains(CellAttrs::BOLD) {
                    out.push_str(";1");
                }
                if a.contains(CellAttrs::DIM) {
                    out.push_str(";2");
                }
                if a.contains(CellAttrs::ITALIC) {
                    out.push_str(";3");
                }
                if a.contains(CellAttrs::UNDERLINE) {
                    out.push_str(";4");
                }
                if a.contains(CellAttrs::BLINK) {
                    out.push_str(";5");
                }
                if a.contains(CellAttrs::REVERSE) {
                    out.push_str(";7");
                }
                if a.contains(CellAttrs::HIDDEN) {
                    out.push_str(";8");
                }
                if a.contains(CellAttrs::STRIKETHROUGH) {
                    out.push_str(";9");
                }
                if a.contains(CellAttrs::OVERLINE) {
                    out.push_str(";53");
                }
                match self.cursor.fg {
                    Color::Default => {}
                    Color::Indexed(n) if n < 8 => out.push_str(&format!(";{}", 30 + n as u16)),
                    Color::Indexed(n) if n < 16 => out.push_str(&format!(";{}", 90 + n as u16 - 8)),
                    Color::Indexed(n) => out.push_str(&format!(";38:5:{}", n)),
                    Color::Rgb(r, g, b) => out.push_str(&format!(";38:2::{}:{}:{}", r, g, b)),
                }
                match self.cursor.bg {
                    Color::Default => {}
                    Color::Indexed(n) if n < 8 => out.push_str(&format!(";{}", 40 + n as u16)),
                    Color::Indexed(n) if n < 16 => {
                        out.push_str(&format!(";{}", 100 + n as u16 - 8))
                    }
                    Color::Indexed(n) => out.push_str(&format!(";48:5:{}", n)),
                    Color::Rgb(r, g, b) => out.push_str(&format!(";48:2::{}:{}:{}", r, g, b)),
                }
                out.push('m');
                Some(out)
            }
            b"r" => Some(format!(
                "{};{}r",
                self.scroll_top + 1,
                self.scroll_bottom + 1
            )),
            b"s" => {
                let (hl, hr) = self.h_margins();
                Some(format!("{};{}s", hl + 1, hr + 1))
            }
            b" q" => {
                let s = match (self.cursor_style.shape, self.cursor_style.blinking) {
                    (CursorShape::Block, true) => 1,
                    (CursorShape::Block, false) => 2,
                    (CursorShape::Underline, true) => 3,
                    (CursorShape::Underline, false) => 4,
                    (CursorShape::Bar, true) => 5,
                    (CursorShape::Bar, false) => 6,
                };
                Some(format!("{} q", s))
            }
            b"\"q" => Some(format!(
                "{}\"q",
                match self.protected_mode {
                    ProtectedMode::Off => 0,
                    _ => 1,
                }
            )),
            _ => None,
        };
        match reply {
            Some(body) => self.response.push_str(&format!("\x1bP1$r{}\x1b\\", body)),
            None => {
                if req.len() <= 2 {
                    self.response.push_str("\x1bP0$r\x1b\\");
                }
            }
        }
    }

    /// XTGETTCAP (`DCS + q <hex names> ST`): report terminfo capabilities.
    pub(crate) fn xtgettcap(&mut self, req: &[u8]) {
        fn from_hex(s: &[u8]) -> Option<String> {
            if !s.len().is_multiple_of(2) || s.is_empty() {
                return None;
            }
            let mut out = Vec::with_capacity(s.len() / 2);
            for pair in s.chunks(2) {
                let hi = (pair[0] as char).to_digit(16)? as u8;
                let lo = (pair[1] as char).to_digit(16)? as u8;
                out.push(hi << 4 | lo);
            }
            String::from_utf8(out).ok()
        }
        fn to_hex(s: &str) -> String {
            s.bytes().map(|b| format!("{:02X}", b)).collect()
        }

        for name_hex in req.split(|&b| b == b';') {
            let Some(name) = from_hex(name_hex) else {
                self.response.push_str(&format!(
                    "\x1bP0+r{}\x1b\\",
                    String::from_utf8_lossy(name_hex)
                ));
                continue;
            };
            let value = match name.as_str() {
                "TN" | "name" => Some("xterm-256color".to_string()),
                "Co" | "colors" => Some("256".to_string()),
                "RGB" => Some("8/8/8".to_string()),
                "bce" => Some(String::new()),
                _ => None,
            };
            match value {
                Some(v) if v.is_empty() => {
                    self.response
                        .push_str(&format!("\x1bP1+r{}\x1b\\", to_hex(&name)));
                }
                Some(v) => {
                    self.response.push_str(&format!(
                        "\x1bP1+r{}={}\x1b\\",
                        to_hex(&name),
                        to_hex(&v)
                    ));
                }
                None => {
                    self.response
                        .push_str(&format!("\x1bP0+r{}\x1b\\", to_hex(&name)));
                }
            }
        }
    }

    /// DECSTR (`CSI ! p`): reset cursor attributes/charset/modes/scroll region.
    pub(crate) fn soft_reset(&mut self) {
        self.cursor.fg = Color::Default;
        self.cursor.bg = Color::Default;
        self.cursor.attrs = CellAttrs::empty();
        self.cursor.saved = None;
        self.cursor_visible = true;
        self.modes.origin_mode = false;
        self.modes.autowrap = true;
        self.modes.cursor_key_app_mode = false;
        self.modes.alternate_scroll = true;
        let rows = self.active_grid().rows();
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);
        self.scroll_left = 0;
        self.scroll_right = self.active_grid().cols().saturating_sub(1);
        self.g0 = Charset::Ascii;
        self.g1 = Charset::Ascii;
        self.shift_out = false;
        self.pending_wrap = false;
        self.protected_mode = ProtectedMode::Off;
    }

    /// RIS (`ESC c`): full terminal reset.
    pub(crate) fn hard_reset(&mut self) {
        let (cols, rows) = (self.active_grid().cols(), self.active_grid().rows());
        let scrollback = self.primary.scrollback_capacity();
        self.primary = Grid::with_scrollback_capacity(cols, rows, scrollback);
        self.alternate = Grid::with_scrollback_capacity(cols, rows, 0);
        self.switch_screen(ScreenBuffer::Primary);
        self.cursor = Cursor::default();
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);
        self.scroll_left = 0;
        self.scroll_right = cols.saturating_sub(1);
        self.title = String::new();
        self.cursor_visible = true;
        self.selection = None;
        self.g0 = Charset::Ascii;
        self.g1 = Charset::Ascii;
        self.shift_out = false;
        self.tabstops = TabStops::new(cols);
        self.kitty_keyboard = KittyKeyboardState::new();
        self.modes = TerminalModes::new();
        self.modes.grapheme_cluster = self.grapheme_width_method == GraphemeWidthMethod::Unicode;
        self.cursor_style = self.default_cursor_style;
        self.cursor_style_overridden = false;
        self.palette.reset_all();
        self.default_fg = self.palette.base_fg();
        self.default_bg = self.palette.base_bg();
        self.cursor_color = self.palette.base_cursor();
        self.palette.set_fg_overridden(false);
        self.palette.set_bg_overridden(false);
        self.palette.set_cursor_overridden(false);
        self.title_stack = TitleStack::new();
        self.last_printed_char = None;
        self.pending_wrap = false;
        self.protected_mode = ProtectedMode::Off;
        self.commands.clear();
        self.input_start = None;
        self.last_cwd = None;
        self.last_prompt_line = None;
        self.context_stack.clear();
        self.evicted_elevated = 0;
    }

    /// DECALN (`ESC # 8`): fill the screen with 'E', reset scroll region, home cursor.
    pub(crate) fn decaln(&mut self) {
        let rows = self.active_grid().rows();
        let cols = self.active_grid().cols();
        for row in 0..rows {
            for col in 0..cols {
                self.active_grid_mut().set(
                    row,
                    col,
                    Cell {
                        char: 'E',
                        ..Cell::default()
                    },
                );
            }
            self.active_grid_mut().set_line_wrapped(row, false);
        }
        self.scroll_top = 0;
        self.scroll_bottom = rows.saturating_sub(1);
        self.scroll_left = 0;
        self.scroll_right = cols.saturating_sub(1);
        self.cursor.row = 0;
        self.cursor.col = 0;
        self.pending_wrap = false;
    }
}
