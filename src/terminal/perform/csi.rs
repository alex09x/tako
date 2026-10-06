/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::Cell;
use crate::parser::Perform;
use crate::terminal::response;
use crate::terminal::state::Terminal;
use crate::terminal::types::{ProtectedMode, SavedCursor};

use super::csi_private::handle_csi_private;
use super::cursor_left::cursor_left;
use super::params::{param_nonzero_or, param_or_default};

pub(crate) fn perform_csi_dispatch(
    terminal: &mut Terminal,
    params: &[u16],
    params_sep: u32,
    intermediates: &[u8],
    _ignore: bool,
    action: char,
) {
    if !intermediates.is_empty() {
        handle_csi_private(terminal, params, intermediates, action);
        return;
    }

    // HPA, HPR and VPR are ECMA-48's names for moves CHA, CUF and CUD
    // already make, and xterm treats them as exactly those.
    let action = match action {
        '`' => 'G',
        'a' => 'C',
        'e' => 'B',
        other => other,
    };

    // Anything that moves the cursor or erases cancels a deferred wrap.
    // 'D' is absent: the CUB arm manages the deferred wrap itself, since
    // reverse wrap treats a pending wrap as one column of movement.
    if matches!(
        action,
        'A' | 'B'
            | 'C'
            | 'E'
            | 'F'
            | 'G'
            | 'H'
            | 'd'
            | 'f'
            | 'J'
            | 'K'
            | 'X'
            | 'r'
            | '@'
            | 'P'
            | 'L'
            | 'M'
    ) {
        terminal.pending_wrap = false;
    }

    match action {
        'A' => {
            let n = param_nonzero_or(params, 0, 1) as usize;
            let floor = if terminal.cursor.row >= terminal.scroll_top
                && terminal.cursor.row <= terminal.scroll_bottom
            {
                terminal.scroll_top
            } else {
                0
            };
            terminal.cursor.row = terminal.cursor.row.saturating_sub(n).max(floor);
        }
        'B' => {
            let n = param_nonzero_or(params, 0, 1) as usize;
            let ceiling = if terminal.cursor.row >= terminal.scroll_top
                && terminal.cursor.row <= terminal.scroll_bottom
            {
                terminal.scroll_bottom
            } else {
                terminal.active_grid().rows().saturating_sub(1)
            };
            terminal.cursor.row = (terminal.cursor.row + n).min(ceiling);
        }
        'C' => {
            let n = param_nonzero_or(params, 0, 1) as usize;
            let (_, hr) = terminal.h_margins();
            let max = if terminal.cursor.col <= hr {
                hr
            } else {
                terminal.active_grid().cols().saturating_sub(1)
            };
            terminal.cursor.col = (terminal.cursor.col + n).min(max);
        }
        'D' => cursor_left(terminal, params),
        'H' | 'f' => {
            let row = param_nonzero_or(params, 0, 1) as usize;
            let col = param_nonzero_or(params, 1, 1) as usize;
            let max_col = terminal.active_grid().cols().saturating_sub(1);
            if terminal.modes.origin_mode {
                let target = terminal.scroll_top + row.saturating_sub(1);
                terminal.cursor.row = target.min(terminal.scroll_bottom);
                let (hl, hr) = terminal.h_margins();
                terminal.cursor.col = (hl + col.saturating_sub(1)).min(hr);
            } else {
                let max_row = terminal.active_grid().rows().saturating_sub(1);
                terminal.cursor.row = row.saturating_sub(1).min(max_row);
                terminal.cursor.col = col.saturating_sub(1).min(max_col);
            }
        }
        'h' | 'l' => {
            // ANSI SM/RM (no '?'): IRM (4) and LNM (20).
            for &p in params {
                match p {
                    4 => terminal.modes.insert = action == 'h',
                    20 => terminal.modes.linefeed_mode = action == 'h',
                    _ => {}
                }
            }
        }
        'J' => terminal.erase_in_display(param_or_default(params, 0, 0)),
        'K' => terminal.erase_in_line(param_or_default(params, 0, 0)),
        'm' => terminal.sgr(params, params_sep),
        'r' => {
            let rows = terminal.active_grid().rows();
            let top = param_nonzero_or(params, 0, 1) as usize;
            let bottom = param_nonzero_or(params, 1, rows as u16) as usize;
            let top0 = top.saturating_sub(1).min(rows.saturating_sub(1));
            let bottom0 = bottom.saturating_sub(1).min(rows.saturating_sub(1));
            // A region of fewer than two lines is refused whole, as in
            // xterm: the old margins stay and the cursor does not move.
            if top0 >= bottom0 {
                return;
            }
            terminal.scroll_top = top0;
            terminal.scroll_bottom = bottom0;
            if terminal.modes.origin_mode {
                terminal.cursor.row = terminal.scroll_top;
                terminal.cursor.col = terminal.h_margins().0;
            } else {
                terminal.cursor.row = 0;
                terminal.cursor.col = 0;
            }
        }
        's' if terminal.modes.left_right_margin_mode => {
            // DECSLRM: set left/right margins, then home the cursor.
            let cols = terminal.active_grid().cols();
            let left = param_nonzero_or(params, 0, 1) as usize;
            let right = param_nonzero_or(params, 1, cols as u16) as usize;
            let left0 = left.saturating_sub(1).min(cols.saturating_sub(1));
            let right0 = right.saturating_sub(1).min(cols.saturating_sub(1));
            // Margins less than two columns apart are refused whole, as
            // in xterm: the old ones stay and the cursor does not move.
            if left0 >= right0 {
                return;
            }
            terminal.scroll_left = left0;
            terminal.scroll_right = right0;
            if terminal.modes.origin_mode {
                terminal.cursor.row = terminal.scroll_top;
                terminal.cursor.col = terminal.scroll_left;
            } else {
                terminal.cursor.row = 0;
                terminal.cursor.col = 0;
            }
            terminal.pending_wrap = false;
        }
        's' => {
            terminal.cursor.saved = Some(SavedCursor {
                row: terminal.cursor.row,
                col: terminal.cursor.col,
                fg: terminal.cursor.fg,
                bg: terminal.cursor.bg,
                attrs: terminal.cursor.attrs,
                g0: terminal.g0,
                g1: terminal.g1,
                shift_out: terminal.shift_out,
                origin_mode: terminal.modes.origin_mode,
                pending_wrap: terminal.pending_wrap,
                protected_mode: terminal.protected_mode,
                gr_slot: terminal.gr_slot,
            });
        }
        'u' => {
            terminal.restore_saved_cursor();
        }
        'L' => terminal.insert_lines(param_nonzero_or(params, 0, 1) as usize),
        'M' => terminal.delete_lines(param_nonzero_or(params, 0, 1) as usize),
        '@' => terminal.insert_chars(param_nonzero_or(params, 0, 1) as usize),
        'P' => terminal.delete_chars(param_nonzero_or(params, 0, 1) as usize),
        'c' => terminal.response.push_str(&response::da1_response()),
        'n' => match param_or_default(params, 0, 0) {
            5 => terminal.response.push_str(&response::device_status_ok()),
            6 => {
                let (row, col) = terminal.reported_cursor();
                let reply = response::cursor_position_report(row, col);
                terminal.response.push_str(&reply);
            }
            _ => {}
        },
        'g' => match param_or_default(params, 0, 0) {
            3 => terminal.tabstops.clear_all(),
            _ => terminal.tabstops.clear(terminal.cursor.col),
        },
        'I' => {
            let n = param_nonzero_or(params, 0, 1) as usize;
            let (_, hr) = terminal.h_margins();
            let max = if terminal.cursor.col <= hr {
                hr
            } else {
                terminal.active_grid().cols().saturating_sub(1)
            };
            for _ in 0..n {
                terminal.cursor.col = terminal.tabstops.next_stop(terminal.cursor.col).min(max);
            }
        }
        'Z' => {
            let n = param_nonzero_or(params, 0, 1) as usize;
            let (hl, _) = terminal.h_margins();
            let floor = if terminal.cursor.col >= hl { hl } else { 0 };
            for _ in 0..n {
                terminal.cursor.col = terminal.tabstops.prev_stop(terminal.cursor.col).max(floor);
            }
        }
        'b' => {
            // REP: repeat the last printed character n times.
            if let Some(ch) = terminal.last_printed_char {
                let n = param_nonzero_or(params, 0, 1) as usize;
                for _ in 0..n {
                    terminal.print(ch);
                }
            }
        }
        't' => {
            // XTWINOPS: only the title push/pop operations are implemented.
            match param_or_default(params, 0, 0) {
                14 => {
                    if terminal.width_px > 0 && terminal.height_px > 0 {
                        let reply = format!("\x1b[4;{};{}t", terminal.height_px, terminal.width_px);
                        terminal.response.push_str(&reply);
                    }
                }
                16 => {
                    let rows = terminal.active_grid().rows() as u32;
                    let cols = terminal.active_grid().cols() as u32;
                    if terminal.width_px > 0 && terminal.height_px > 0 && rows > 0 && cols > 0 {
                        let reply = format!(
                            "\x1b[6;{};{}t",
                            terminal.height_px / rows,
                            terminal.width_px / cols
                        );
                        terminal.response.push_str(&reply);
                    }
                }
                18 => {
                    let reply = format!(
                        "\x1b[8;{};{}t",
                        terminal.active_grid().rows(),
                        terminal.active_grid().cols()
                    );
                    terminal.response.push_str(&reply);
                }
                21 => {
                    let reply = format!("\x1b]l{}\x1b\\", terminal.title);
                    terminal.response.push_str(&reply);
                }
                22 => terminal.title_stack.push(&terminal.title),
                23 => {
                    if let Some(title) = terminal.title_stack.pop() {
                        terminal.title = title;
                    }
                }
                _ => {}
            }
        }
        'G' => {
            // CHA: absolute column.
            let n = param_nonzero_or(params, 0, 1) as usize;
            let max = terminal.active_grid().cols().saturating_sub(1);
            terminal.cursor.col = n.saturating_sub(1).min(max);
        }
        'd' => {
            // VPA: absolute row (region-relative in origin mode, like CUP).
            let n = param_nonzero_or(params, 0, 1) as usize;
            if terminal.modes.origin_mode {
                let target = terminal.scroll_top + n.saturating_sub(1);
                terminal.cursor.row = target.min(terminal.scroll_bottom);
            } else {
                let max = terminal.active_grid().rows().saturating_sub(1);
                terminal.cursor.row = n.saturating_sub(1).min(max);
            }
        }
        'E' => {
            // CNL: down n rows (clamped like CUD), column 0.
            let n = param_nonzero_or(params, 0, 1) as usize;
            let ceiling = if terminal.cursor.row >= terminal.scroll_top
                && terminal.cursor.row <= terminal.scroll_bottom
            {
                terminal.scroll_bottom
            } else {
                terminal.active_grid().rows().saturating_sub(1)
            };
            terminal.cursor.row = (terminal.cursor.row + n).min(ceiling);
            terminal.cursor.col = 0;
        }
        'F' => {
            // CPL: up n rows (clamped like CUU), column 0.
            let n = param_nonzero_or(params, 0, 1) as usize;
            let floor = if terminal.cursor.row >= terminal.scroll_top
                && terminal.cursor.row <= terminal.scroll_bottom
            {
                terminal.scroll_top
            } else {
                0
            };
            terminal.cursor.row = terminal.cursor.row.saturating_sub(n).max(floor);
            terminal.cursor.col = 0;
        }
        'S' => terminal.scroll_region_up(param_nonzero_or(params, 0, 1) as usize),
        'T' => terminal.scroll_region_down(param_nonzero_or(params, 0, 1) as usize),
        'X' => {
            // ECH: blank n cells at the cursor without shifting, keeping
            // the current background (BCE), never splitting a wide pair.
            let n = param_nonzero_or(params, 0, 1) as usize;
            let row = terminal.cursor.row;
            let start = terminal.cursor.col;
            let end = start.saturating_add(n).min(terminal.active_grid().cols());
            let blank = Cell {
                bg: terminal.cursor.bg,
                ..Cell::default()
            };
            let respect = terminal.protected_mode == ProtectedMode::Iso;
            terminal
                .active_grid_mut()
                .fill_cells_respecting(row, start, end, blank, respect);
        }
        _ => {}
    }
}
