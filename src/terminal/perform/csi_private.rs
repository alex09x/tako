/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::cursor_style::CursorStyle;
use crate::kitty_keyboard::KittyFlags;
use crate::tabstops::TabStops;
use crate::terminal::response;
use crate::terminal::state::Terminal;
use crate::terminal::types::{ProtectedMode, ScreenBuffer};

use super::params::{param_nonzero_or, param_or_default};

pub(crate) fn handle_csi_private(
    terminal: &mut Terminal,
    params: &[u16],
    intermediates: &[u8],
    action: char,
) {
    // DECRQCRA. The only way an out-of-process harness can read the
    // screen back, which is what esctest and vttest rely on.
    if intermediates == *b"*" && action == 'y' {
        terminal.report_checksum(params);
        return;
    }
    // XTCHECKSUM: pick which parts of DEC's checksum behaviour to keep.
    if intermediates == *b"#" && action == 'y' {
        terminal.checksum_ext = params.first().copied().unwrap_or(0);
        return;
    }
    if intermediates == *b"?$" {
        if action == 'p' {
            let ps = param_or_default(params, 0, 0);
            let set = |b: bool| if b { 1 } else { 2 };
            let v = match ps {
                1 => set(terminal.modes.cursor_key_app_mode),
                6 => set(terminal.modes.origin_mode),
                7 => set(terminal.modes.autowrap),
                25 => set(terminal.cursor_visible),
                45 => set(terminal.modes.reverse_wrap),
                69 => set(terminal.modes.left_right_margin_mode),
                47 | 1047 | 1049 => set(terminal.active == ScreenBuffer::Alternate),
                1000 => set(terminal.modes.mouse_tracking == crate::modes::MouseTracking::Normal),
                1002 => {
                    set(terminal.modes.mouse_tracking == crate::modes::MouseTracking::ButtonEvent)
                }
                1003 => set(terminal.modes.mouse_tracking == crate::modes::MouseTracking::AnyEvent),
                1004 => set(terminal.modes.focus_events),
                1005 => set(terminal.modes.mouse_utf8),
                1006 => set(terminal.modes.mouse_sgr),
                1007 => set(terminal.modes.alternate_scroll),
                1045 => set(terminal.modes.reverse_wrap_extended),
                2004 => set(terminal.modes.bracketed_paste),
                2026 => set(terminal.modes.synchronized_output),
                2027 => set(terminal.modes.grapheme_cluster),
                2031 => set(terminal.modes.color_scheme_updates),
                _ => 0,
            };
            terminal.response.push_str(&format!("\x1b[?{};{}$y", ps, v));
        }
        return;
    }
    if intermediates == *b"?" {
        match action {
            'h' | 'l' => terminal.csi_private_mode(params, action),
            'u' => {
                let reply = terminal.kitty_keyboard.query_response();
                terminal.response.push_str(&reply);
            }
            'n' => {
                // DECDSR. Answering every code we recognise matters more
                // than the values: an unanswered status request leaves
                // the asking program blocked on a read, not falling back.
                terminal.report_private_dsr(params);
            }
            // DECSED/DECSEL: selective erase always respects protection.
            'J' => {
                terminal.pending_wrap = false;
                terminal.erase_in_display_protected(param_or_default(params, 0, 0), true);
            }
            'K' => {
                terminal.pending_wrap = false;
                terminal.erase_in_line_protected(param_or_default(params, 0, 0), true);
            }
            // DECST8C (`CSI ? 5 W`): a tab stop every eight columns
            // again. Programs also send it with no parameter.
            'W' if matches!(param_or_default(params, 0, 5), 0 | 5) => {
                let cols = terminal.active_grid().cols();
                terminal.tabstops = TabStops::new(cols);
            }
            // XTQMODKEYS (`CSI ? Pp m`). Only modifyOtherKeys (4) can be
            // set; the others report the encoding the terminal always
            // uses -- modifiers on cursor and function keys, none on the
            // keypad or the keyboard as a whole.
            'm' => {
                let resource = param_or_default(params, 0, 0);
                let value = match resource {
                    0 | 3 => Some(0),
                    1 | 2 => Some(2),
                    4 => Some(u16::from(terminal.modes.modify_other_keys)),
                    _ => None,
                };
                if let Some(value) = value {
                    terminal
                        .response
                        .push_str(&format!("\x1b[>{resource};{value}m"));
                }
            }
            _ => {}
        }
        return;
    }
    if intermediates == *b">" {
        match action {
            'u' => {
                let flags = KittyFlags::from_bits_truncate(param_or_default(params, 0, 0) as u8);
                terminal.kitty_keyboard.push(flags);
            }
            'c' => terminal.response.push_str(&response::da2_response()),
            // XTSHIFTESCAPE.
            's' => terminal.modes.shift_capture = Some(param_or_default(params, 0, 0) == 1),
            // XTMODKEYS (`CSI > Pp ; Pv m`): modifyOtherKeys (4) is the
            // resource programs set. Leaving out the value -- or every
            // parameter -- puts it back to its default, off.
            'm' => {
                if params.is_empty() || param_or_default(params, 0, 0) == 4 {
                    terminal.modes.modify_other_keys = params.get(1).map_or(0, |&v| v.min(2) as u8);
                }
            }
            // XTMODKEYS disable (`CSI > 4 n`), which for this resource is
            // the same as turning it off.
            'n' => {
                if param_or_default(params, 0, 0) == 4 {
                    terminal.modes.modify_other_keys = 0;
                }
            }
            'q' => {
                let name = if terminal.xtversion.is_empty() {
                    "tako".to_string()
                } else {
                    terminal.xtversion.clone()
                };
                terminal
                    .response
                    .push_str(&response::xtversion_response(&name));
            }
            _ => {}
        }
        return;
    }
    if intermediates == *b"<" {
        if action == 'u' {
            let n = param_nonzero_or(params, 0, 1) as usize;
            terminal.kitty_keyboard.pop(n);
        }
        return;
    }
    if intermediates == *b"=" {
        match action {
            'u' => {
                let flags = KittyFlags::from_bits_truncate(param_or_default(params, 0, 0) as u8);
                terminal.kitty_keyboard.set(flags);
            }
            // DA3: tertiary device attributes (site/unit id).
            'c' => terminal.response.push_str("\x1bP!|00000000\x1b\\"),
            _ => {}
        }
        return;
    }
    if intermediates == *b" " {
        if action == 'q' {
            let param = param_or_default(params, 0, 0);
            if param == 0 {
                // 0 is "the default": the host's, not a fixed shape.
                terminal.cursor_style = terminal.default_cursor_style;
                terminal.cursor_style_overridden = false;
            } else if let Some(style) = CursorStyle::from_decscusr_param(param) {
                terminal.cursor_style = style;
                terminal.cursor_style_overridden = true;
            }
        }
        return;
    }
    if intermediates == *b"!" {
        if action == 'p' {
            terminal.soft_reset();
        }
        return;
    }
    if intermediates == *b"$" {
        if action == 'p' {
            // ANSI DECRQM: report IRM (4) / LNM (20) state.
            let ps = param_or_default(params, 0, 0);
            let v = match ps {
                4 => {
                    if terminal.modes.insert {
                        1
                    } else {
                        2
                    }
                }
                20 => {
                    if terminal.modes.linefeed_mode {
                        1
                    } else {
                        2
                    }
                }
                _ => 0,
            };
            terminal.response.push_str(&format!("\x1b[{};{}$y", ps, v));
        }
        return;
    }
    if intermediates == *b"'" {
        match action {
            '}' => terminal.insert_columns(param_nonzero_or(params, 0, 1) as usize),
            '~' => terminal.delete_columns(param_nonzero_or(params, 0, 1) as usize),
            _ => {}
        }
        return;
    }
    if intermediates == *b"\"" && action == 'q' {
        // DECSCA: 1 = protect, 0/2 = unprotect (DEC flavor).
        terminal.protected_mode = match param_or_default(params, 0, 0) {
            1 => ProtectedMode::Dec,
            _ => ProtectedMode::Off,
        };
    }
}
