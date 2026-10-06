/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::os::raw::c_int;

use crate::grid::Color;

use super::render::row_ansi;
use super::types::{ProdVt, copy_bytes, guarded, term};

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_viewport_ansi(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        let rows = t.active_grid().rows();
        let mut buf = Vec::new();
        for row in 0..rows {
            if row > 0 {
                buf.extend_from_slice(b"\r\n");
            }
            row_ansi(t, row, &mut buf);
        }
        unsafe { copy_bytes(buf, out, out_len) }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_viewport_text(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        unsafe { copy_bytes(t.plain_string().into_bytes(), out, out_len) }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_snapshot_ansi(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        // Scrollback first (oldest to newest), then the live screen.
        let mut buf = Vec::new();
        let history: Vec<Vec<u8>> = t
            .active_grid()
            .scrollback_iter()
            .map(|line| {
                let mut s: Vec<u8> = Vec::new();
                for cell in line {
                    if cell.is_wide_spacer {
                        continue;
                    }
                    let ch = if cell.char == '\0' { ' ' } else { cell.char };
                    let mut b = [0u8; 4];
                    s.extend_from_slice(ch.encode_utf8(&mut b).as_bytes());
                    s.extend_from_slice(t.active_grid().grapheme(cell).as_bytes());
                }
                while s.last() == Some(&b' ') {
                    s.pop();
                }
                s
            })
            .collect();
        for line in history {
            buf.extend_from_slice(&line);
            buf.extend_from_slice(b"\r\n");
        }
        let rows = t.active_grid().rows();
        for row in 0..rows {
            if row > 0 {
                buf.extend_from_slice(b"\r\n");
            }
            row_ansi(t, row, &mut buf);
        }
        unsafe { copy_bytes(buf, out, out_len) }
    })
}

/// Versioned ANSI snapshot (v2) which trims trailing blank grid rows and appends cursor positioning.
///
/// Preserved as an explicitly versioned alternative to `prod_vt_snapshot_ansi`.
/// Note: For full terminal continuation (including in-flight parser sequences, tab stops,
/// scroll margins, and wrap state), callers should use `prod_vt_checkpoint` and `prod_vt_restore`.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_snapshot_ansi_v2(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        let mut buf = Vec::new();
        let history: Vec<Vec<u8>> = t
            .active_grid()
            .scrollback_iter()
            .map(|line| {
                let mut s: Vec<u8> = Vec::new();
                for cell in line {
                    if cell.is_wide_spacer {
                        continue;
                    }
                    let ch = if cell.char == '\0' { ' ' } else { cell.char };
                    let mut b = [0u8; 4];
                    s.extend_from_slice(ch.encode_utf8(&mut b).as_bytes());
                    s.extend_from_slice(t.active_grid().grapheme(cell).as_bytes());
                }
                while s.last() == Some(&b' ') {
                    s.pop();
                }
                s
            })
            .collect();
        for line in history {
            buf.extend_from_slice(&line);
            buf.extend_from_slice(b"\r\n");
        }
        let rows = t.active_grid().rows();
        let (cursor_row, cursor_col) = t.cursor();

        let mut last_active_row = cursor_row.min(rows.saturating_sub(1));
        for r in (0..rows).rev() {
            let cells = t.viewport_row(r);
            let has_content = cells.iter().any(|c| {
                (c.char != '\0' && c.char != ' ') || !c.attrs.is_empty() || c.bg != Color::Default
            });
            if has_content {
                last_active_row = last_active_row.max(r);
                break;
            }
        }

        for row in 0..=last_active_row {
            if row > 0 {
                buf.extend_from_slice(b"\r\n");
            }
            row_ansi(t, row, &mut buf);
        }

        if !t.pending_wrap() {
            let pos_seq = format!("\x1b[{};{}H", cursor_row + 1, cursor_col + 1);
            buf.extend_from_slice(pos_seq.as_bytes());
        }
        if !t.cursor_visible() {
            buf.extend_from_slice(b"\x1b[?25l");
        }

        unsafe { copy_bytes(buf, out, out_len) }
    })
}
