/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::params::param_nonzero_or;
use crate::terminal::state::Terminal;

pub(crate) fn cursor_left(terminal: &mut Terminal, params: &[u16]) {
    // Upstream-exact cursorLeft (upstream `Terminal`): plain mode moves
    // toward column 0 ignoring margins; reverse-wrap modes use
    // the margin/region rules below.
    let mut n = param_nonzero_or(params, 0, 1) as usize;
    let rw_ext = terminal.modes.reverse_wrap_extended && terminal.modes.autowrap;
    let rw_basic = terminal.modes.reverse_wrap && terminal.modes.autowrap;
    if !(rw_basic || rw_ext) {
        terminal.cursor.col -= n.min(terminal.cursor.col);
        terminal.pending_wrap = false;
    } else {
        if terminal.pending_wrap {
            n = n.saturating_sub(1);
            terminal.pending_wrap = false;
        }
        let cols = terminal.active_grid().cols();
        let top = terminal.scroll_top;
        let bottom = terminal.scroll_bottom;
        let (hl, hr) = terminal.h_margins();
        let right_margin = hr;
        let left_margin = if terminal.cursor.col < hl { 0 } else { hl };

        // Basic reverse wrap starting ON the left margin at or
        // above the top margin jumps straight to the region's
        // top-left (xterm quirk, unit-tested upstream).
        if terminal.cursor.col == left_margin && !rw_ext && terminal.cursor.row <= top {
            terminal.cursor.row = top;
            terminal.cursor.col = left_margin;
        } else {
            loop {
                let step = n.min(terminal.cursor.col - left_margin);
                terminal.cursor.col -= step;
                n -= step;
                if n == 0 {
                    break;
                }
                if terminal.cursor.row == top {
                    if !rw_ext {
                        break;
                    }
                    terminal.cursor.row = bottom;
                    terminal.cursor.col = right_margin.min(cols.saturating_sub(1));
                    n -= 1;
                    continue;
                }
                if terminal.cursor.row == 0 {
                    break;
                }
                // A wrap marker lives on the continuation row,
                // so the current row records whether reverse-wrap
                // may cross back into the row above it.
                if !rw_ext && !terminal.active_grid().is_line_wrapped(terminal.cursor.row) {
                    break;
                }
                terminal.cursor.row -= 1;
                terminal.cursor.col = right_margin.min(cols.saturating_sub(1));
                n -= 1;
            }
        }
    }
}
