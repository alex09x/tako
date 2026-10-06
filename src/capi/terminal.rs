/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::os::raw::{c_int, c_void};

use crate::modes::MouseTracking;
use crate::mouse_encode::{
    MouseAction, MouseButton, MouseEncoding, MouseEvent, MouseMods, encode as encode_mouse,
};
use crate::terminal::{ScreenBuffer, Terminal};

use super::types::{ProdVt, ProdVtCursor, ProdVtScrollbar, copy_bytes, guarded, term};

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut ProdVt {
    guarded(std::ptr::null_mut(), || {
        let terminal = Terminal::with_scrollback(cols as usize, rows as usize, max_scrollback);
        Box::into_raw(Box::new(ProdVt::new(terminal)))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_free(vt: *mut ProdVt) {
    guarded((), || {
        if !vt.is_null() {
            drop(unsafe { Box::from_raw(vt) });
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_write(vt: *mut ProdVt, data: *const u8, len: usize) {
    guarded((), || {
        let Some(t) = (unsafe { term(vt) }) else {
            return;
        };
        if data.is_null() || len == 0 {
            return;
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        t.feed(bytes);
    })
}

/// Discard queued host-visible events without consuming them.
///
/// For hosts that drive the terminal via `prod_vt_write` and intentionally
/// do not consume [`crate::terminal::TerminalEvent`] notifications (bell, title
/// changes, clipboard updates, desktop notifications). Drops `take_events()`
/// and releases all owned payload allocations.
///
/// Safe to call repeatedly or when no events are queued. Null-safe (no-op if
/// `vt` is null).
///
/// Does not drain the response queue, reset the terminal, modify title/grid/
/// parser/scrollback/modes state, bump epochs, or affect checkpoints.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_discard_events(vt: *mut ProdVt) {
    guarded((), || {
        let Some(t) = (unsafe { term(vt) }) else {
            return;
        };
        drop(t.take_events());
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_resize(
    vt: *mut ProdVt,
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        if cols == 0 || rows == 0 {
            return 0;
        }
        t.resize_with_cell_size(cols as usize, rows as usize, cell_width_px, cell_height_px);
        1
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_scroll_delta(vt: *mut ProdVt, delta: isize) {
    guarded((), || {
        let Some(t) = (unsafe { term(vt) }) else {
            return;
        };
        // Positive delta scrolls back into history, matching the Go caller.
        if delta > 0 {
            t.scroll_viewport_up(delta as usize);
        } else if delta < 0 {
            t.scroll_viewport_down((-delta) as usize);
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_scroll_bottom(vt: *mut ProdVt) {
    guarded((), || {
        if let Some(t) = unsafe { term(vt) } {
            t.scroll_viewport_bottom();
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_mode(vt: *mut ProdVt, mode: u16, enabled: *mut c_int) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        if enabled.is_null() {
            return 0;
        }
        let m = t.modes();
        let on = match mode {
            9 => m.mouse_tracking == MouseTracking::Normal,
            1000 => m.mouse_tracking == MouseTracking::Normal,
            1002 => m.mouse_tracking == MouseTracking::ButtonEvent,
            1003 => m.mouse_tracking == MouseTracking::AnyEvent,
            1006 => m.mouse_sgr,
            1005 => m.mouse_utf8,
            1007 => m.alternate_scroll,
            7 => m.autowrap,
            6 => m.origin_mode,
            1 => m.cursor_key_app_mode,
            2004 => m.bracketed_paste,
            1004 => m.focus_events,
            25 => t.cursor_visible(),
            _ => return 0,
        };
        unsafe { *enabled = on as c_int };
        1
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_active_screen(vt: *mut ProdVt, alternate: *mut c_int) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        if alternate.is_null() {
            return 0;
        }
        unsafe { *alternate = (t.active_screen() == ScreenBuffer::Alternate) as c_int };
        1
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_viewport_active(vt: *mut ProdVt, active: *mut c_int) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        if active.is_null() {
            return 0;
        }
        // "Active" means the viewport is pinned to the live screen bottom.
        unsafe { *active = (t.viewport_offset() == 0) as c_int };
        1
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_cursor_state(vt: *mut ProdVt, cursor: *mut ProdVtCursor) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        if cursor.is_null() {
            return 0;
        }
        let (row, col) = t.cursor();
        unsafe {
            (*cursor).x = col as u16;
            (*cursor).y = row as u16;
            (*cursor).visible = t.cursor_visible() as c_int;
        }
        1
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_scrollbar_state(
    vt: *mut ProdVt,
    scrollbar: *mut ProdVtScrollbar,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        if scrollbar.is_null() {
            return 0;
        }
        let rows = t.active_grid().rows() as u64;
        let history = t.active_grid().scrollback_len() as u64;
        let total = history + rows;
        // Offset counts from the top of history down to the viewport's top.
        let offset = history - (t.viewport_offset() as u64).min(history);
        unsafe {
            (*scrollbar).total = total;
            (*scrollbar).offset = offset;
            (*scrollbar).len = rows;
        }
        1
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_title(vt: *mut ProdVt, out: *mut *mut u8, out_len: *mut usize) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        unsafe { copy_bytes(t.title().as_bytes().to_vec(), out, out_len) }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_drain_responses(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        unsafe { copy_bytes(t.take_output(), out, out_len) }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_encode_wheel(
    vt: *mut ProdVt,
    up: c_int,
    column: u16,
    row: u16,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        let modes = t.modes();
        if modes.mouse_tracking == MouseTracking::Off {
            return 0;
        }
        let encoding = if modes.mouse_sgr {
            MouseEncoding::Sgr
        } else if modes.mouse_utf8 {
            MouseEncoding::Utf8
        } else {
            MouseEncoding::X10
        };
        let event = MouseEvent {
            button: if up != 0 {
                MouseButton::WheelUp
            } else {
                MouseButton::WheelDown
            },
            action: MouseAction::Press,
            mods: MouseMods::default(),
            col: column as u32,
            row: row as u32,
        };
        match encode_mouse(event, encoding) {
            Some(bytes) => unsafe { copy_bytes(bytes, out, out_len) },
            None => 0,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_buffer_free(data: *mut u8) {
    guarded((), || {
        if !data.is_null() {
            unsafe { libc::free(data as *mut c_void) };
        }
    })
}
