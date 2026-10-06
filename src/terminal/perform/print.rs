/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::charset::{self, Charset};
use crate::grid::Cell;
use unicode_width::UnicodeWidthChar;

use super::super::state::Terminal;
use super::super::types::ProtectedMode;

impl Terminal {
    pub(crate) fn perform_print(&mut self, c: char) {
        let cols = self.active_grid().cols();
        if cols == 0 {
            return;
        }
        if self.cursor.col >= cols {
            self.cursor.col = cols - 1;
        }

        if c >= '\u{A0}' && self.join_previous_cluster(c) {
            return;
        }

        if self.pending_wrap && self.modes.autowrap {
            let (hl, _hr) = self.h_margins();
            self.cursor.col = hl;
            self.line_feed();
            let dest_row = self.cursor.row;
            if self.h_margins_full() {
                self.active_grid_mut().set_line_wrapped(dest_row, true);
            }
        }
        self.pending_wrap = false;

        let charset = if let Some(ss) = self.single_shift.take() {
            ss
        } else if self.shift_out {
            self.g1
        } else {
            self.g0
        };
        let c = charset::translate(charset, c);
        let c = if charset != Charset::Ascii
            && (c as u32) > 0x7F
            && charset::translate(charset, c) == c
        {
            match charset {
                Charset::DecSpecialGraphics | Charset::British => {
                    if (c as u32) > 0x7F && !('\u{2500}'..='\u{25C7}').contains(&c)
                        && !"\u{00A3}\u{00B0}\u{00B1}\u{00B7}\u{03C0}\u{2260}\u{2264}\u{2265}\u{23BA}\u{23BB}\u{23BC}\u{23BD}\u{2409}\u{240A}\u{240B}\u{240C}\u{240D}\u{2424}\u{2518}\u{2510}\u{250C}\u{2514}\u{253C}\u{251C}\u{2524}\u{2534}\u{252C}\u{2502}".contains(c)
                    {
                        ' '
                    } else {
                        c
                    }
                }
                Charset::Ascii => c,
            }
        } else {
            c
        };
        let wide = UnicodeWidthChar::width(c).unwrap_or(1) >= 2;

        let cell = Cell {
            char: c,
            fg: self.cursor.fg,
            bg: self.cursor.bg,
            attrs: self.cursor.attrs,
            underline_style: self.cursor.underline_style,
            underline_color: self.cursor.underline_color,
            hyperlink: self.current_hyperlink,
            protected: self.protected_mode != ProtectedMode::Off,
            ..Cell::default()
        };

        if self.modes.insert && self.cursor.col + if wide { 2 } else { 1 } < cols {
            self.insert_chars(if wide { 2 } else { 1 });
        }

        let (hl, hr) = self.h_margins();
        let right_bound = if self.cursor.col <= hr { hr } else { cols - 1 };
        let left_home = hl;
        if wide && self.cursor.col + 1 > right_bound {
            if right_bound + 1 - left_home < 2 {
                if self.modes.autowrap {
                    self.pending_wrap = true;
                }
                return;
            }
            if self.modes.autowrap {
                let row = self.cursor.row;
                let col = self.cursor.col;
                if right_bound + 1 == cols {
                    let head = Cell {
                        char: ' ',
                        is_wide_spacer_head: true,
                        bg: self.cursor.bg,
                        hyperlink: self.current_hyperlink,
                        protected: self.protected_mode != ProtectedMode::Off,
                        ..Cell::default()
                    };
                    self.active_grid_mut().set(row, col, head);
                }
                self.cursor.col = left_home;
                self.line_feed();
                let dest_row = self.cursor.row;
                if right_bound + 1 == cols {
                    self.active_grid_mut().set_line_wrapped(dest_row, true);
                }
            } else {
                return;
            }
        }

        let row = self.cursor.row;
        let col = self.cursor.col;
        self.dissolve_wide_pair_at(row, col);
        if wide {
            self.dissolve_wide_pair_at(row, col + 1);
            self.active_grid_mut().set_wide(row, col, cell);
            self.cursor.col += 2;
        } else {
            self.active_grid_mut().set(row, col, cell);
            self.cursor.col += 1;
        }

        if self.cursor.col > right_bound {
            self.cursor.col = right_bound;
            if self.modes.autowrap {
                self.pending_wrap = true;
            }
        }

        self.last_printed_char = Some(c);
    }

    pub(crate) fn perform_print_slice(&mut self, bytes: &[u8]) {
        if self.modes.insert
            || !self.modes.autowrap
            || !self.h_margins_full()
            || self.single_shift.is_some()
            || self.shift_out
            || self.g0 != Charset::Ascii
            || self.current_hyperlink.is_some()
        {
            for &byte in bytes {
                self.perform_print(byte as char);
            }
            return;
        }

        let cols = self.active_grid().cols();
        if cols == 0 {
            return;
        }
        self.cursor.col = self.cursor.col.min(cols - 1);

        let template = Cell {
            char: '\0',
            fg: self.cursor.fg,
            bg: self.cursor.bg,
            attrs: self.cursor.attrs,
            underline_style: self.cursor.underline_style,
            underline_color: self.cursor.underline_color,
            protected: self.protected_mode != ProtectedMode::Off,
            ..Cell::default()
        };

        let mut offset = 0;
        while offset < bytes.len() {
            if self.pending_wrap {
                self.cursor.col = 0;
                self.line_feed();
                let row = self.cursor.row;
                self.active_grid_mut().set_line_wrapped(row, true);
            }

            let row = self.cursor.row;
            let col = self.cursor.col;
            let count = (cols - col).min(bytes.len() - offset);
            let run = &bytes[offset..offset + count];

            if !self
                .active_grid_mut()
                .write_narrow_ascii(row, col, run, template)
            {
                self.perform_print(bytes[offset] as char);
                offset += 1;
                continue;
            }

            offset += count;
            self.last_printed_char = run.last().map(|&byte| byte as char);
            if col + count == cols {
                self.cursor.col = cols - 1;
                self.pending_wrap = true;
            } else {
                self.cursor.col = col + count;
            }
        }
    }
}
