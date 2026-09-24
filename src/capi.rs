//! C ABI for hosts that link the engine directly (a Go service over cgo is
//! the first consumer; the `prod_vt_*` names are its header's).
//!
//! Ownership rules: every `*_out` buffer is
//! heap-allocated here and must be released with [`prod_vt_buffer_free`];
//! the handle from [`prod_vt_new`] must be released with
//! [`prod_vt_free`]. Every function tolerates NULL pointers by returning
//! failure (0) rather than dereferencing them.
//!
//! These are C entry points: the pointer contract above is the C caller's,
//! documented here rather than expressed as `unsafe fn`, which would change
//! nothing for C and only burden the Rust tests that drive the ABI.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::os::raw::{c_int, c_void};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::grid::{CellAttrs, Color};
use crate::modes::MouseTracking;
use crate::mouse_encode::{
    encode as encode_mouse, MouseAction, MouseButton, MouseEncoding, MouseEvent, MouseMods,
};
use crate::terminal::checkpoint::CheckpointError;
use crate::terminal::{ScreenBuffer, Terminal};

/// Opaque handle handed to the C caller.
pub struct ProdVt {
    terminal: Terminal,
}

#[repr(C)]
pub struct ProdVtCursor {
    pub x: u16,
    pub y: u16,
    pub visible: c_int,
}

#[repr(C)]
pub struct ProdVtScrollbar {
    pub total: u64,
    pub offset: u64,
    pub len: u64,
}

/// Catches an unwind out of `f` and returns `fail` instead of letting it
/// cross the C ABI, where unwinding is undefined behaviour (and, with
/// `panic = "abort"`, simply aborts the process).
///
/// Every `prod_vt_*` function routes its body through this, so an engine bug
/// that panics degrades to that one call returning its documented failure
/// value rather than taking down the whole host process.
fn guarded<T>(fail: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fail)
}

/// Hand a heap buffer to C: `out` receives the pointer, `out_len` the
/// length. Returns 1 on success, 0 when the out-params are unusable.
unsafe fn copy_bytes(data: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) -> c_int {
    if out.is_null() || out_len.is_null() {
        return 0;
    }
    // Allocate with malloc so the caller's `prod_vt_buffer_free` (a plain
    // free) is valid -- the Zig shim this replaces did the same.
    let len = data.len();
    if len == 0 {
        unsafe {
            *out = std::ptr::null_mut();
            *out_len = 0;
        }
        return 1;
    }
    let ptr = unsafe { libc::malloc(len) } as *mut u8;
    if ptr.is_null() {
        return 0;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(data.as_ptr(), ptr, len);
        *out = ptr;
        *out_len = len;
    }
    1
}

unsafe fn term<'a>(vt: *mut ProdVt) -> Option<&'a mut Terminal> {
    if vt.is_null() {
        return None;
    }
    Some(unsafe { &mut (*vt).terminal })
}

/// Render one row as ANSI: SGR runs plus the row's text.
fn row_ansi(term: &Terminal, row: usize, out: &mut Vec<u8>) {
    let cols = term.active_grid().cols();
    let cells = term.viewport_row(row);
    let mut last: Option<(Color, Color, CellAttrs)> = None;
    let mut trailing_blanks = 0usize;
    let mut line: Vec<u8> = Vec::with_capacity(cols * 2);
    for cell in cells.iter() {
        if cell.is_wide_spacer {
            continue;
        }
        let ch = if cell.char == '\0' { ' ' } else { cell.char };
        let style = (cell.fg, cell.bg, cell.attrs);
        if last != Some(style) {
            line.extend_from_slice(sgr_for(style).as_bytes());
            last = Some(style);
        }
        if ch == ' ' && cell.attrs.is_empty() && cell.bg == Color::Default {
            trailing_blanks += 1;
        } else {
            trailing_blanks = 0;
        }
        let mut buf = [0u8; 4];
        line.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
        line.extend_from_slice(term.active_grid().grapheme(cell).as_bytes());
    }
    // Trim trailing default-styled blanks; they carry no information and
    // bloat every frame the Go side ships to its UI.
    line.truncate(line.len() - trailing_blanks.min(line.len()));
    out.extend_from_slice(&line);
    if last.is_some() {
        out.extend_from_slice(b"\x1b[0m");
    }
}

fn sgr_for((fg, bg, attrs): (Color, Color, CellAttrs)) -> String {
    let mut parts: Vec<String> = vec!["0".into()];
    if attrs.contains(CellAttrs::BOLD) {
        parts.push("1".into());
    }
    if attrs.contains(CellAttrs::DIM) {
        parts.push("2".into());
    }
    if attrs.contains(CellAttrs::ITALIC) {
        parts.push("3".into());
    }
    if attrs.contains(CellAttrs::UNDERLINE) {
        parts.push("4".into());
    }
    if attrs.contains(CellAttrs::BLINK) {
        parts.push("5".into());
    }
    if attrs.contains(CellAttrs::REVERSE) {
        parts.push("7".into());
    }
    if attrs.contains(CellAttrs::HIDDEN) {
        parts.push("8".into());
    }
    if attrs.contains(CellAttrs::STRIKETHROUGH) {
        parts.push("9".into());
    }
    match fg {
        Color::Default => {}
        Color::Indexed(n) if n < 8 => parts.push((30 + n as u16).to_string()),
        Color::Indexed(n) if n < 16 => parts.push((90 + n as u16 - 8).to_string()),
        Color::Indexed(n) => parts.push(format!("38;5;{}", n)),
        Color::Rgb(r, g, b) => parts.push(format!("38;2;{};{};{}", r, g, b)),
    }
    match bg {
        Color::Default => {}
        Color::Indexed(n) if n < 8 => parts.push((40 + n as u16).to_string()),
        Color::Indexed(n) if n < 16 => parts.push((100 + n as u16 - 8).to_string()),
        Color::Indexed(n) => parts.push(format!("48;5;{}", n)),
        Color::Rgb(r, g, b) => parts.push(format!("48;2;{};{};{}", r, g, b)),
    }
    format!("\x1b[{}m", parts.join(";"))
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut ProdVt {
    guarded(std::ptr::null_mut(), || {
        let terminal = Terminal::with_scrollback(cols as usize, rows as usize, max_scrollback);
        Box::into_raw(Box::new(ProdVt { terminal }))
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
        let Some(t) = (unsafe { term(vt) }) else { return };
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
        let Some(t) = (unsafe { term(vt) }) else { return };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
pub extern "C" fn prod_vt_scrollbar_state(vt: *mut ProdVt, scrollbar: *mut ProdVtScrollbar) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
pub extern "C" fn prod_vt_viewport_ansi(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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

/// Zero a byte-buffer out-parameter pair.
///
/// Every failure path writes this before returning, so a caller never has to
/// tell "the callee left my variables alone" from "the callee produced a
/// 123-byte buffer". A NULL out-parameter is skipped, not dereferenced.
unsafe fn clear_bytes_out(out: *mut *mut u8, out_len: *mut usize) {
    unsafe {
        if !out.is_null() {
            *out = std::ptr::null_mut();
        }
        if !out_len.is_null() {
            *out_len = 0;
        }
    }
}

/// Export a native binary checkpoint from the terminal state.
///
/// Allocates a buffer containing the serialized state, setting `*out` and `*out_len`.
/// The caller must free the buffer with [`prod_vt_buffer_free`].
/// Returns 1 on success, 0 on invalid arguments or failure.
///
/// On failure `*out` is NULL and `*out_len` is 0: the boolean contract is
/// unchanged, but the out-parameters are no longer whatever the caller last
/// left in them. Use [`prod_vt_checkpoint_export2`] for the reason.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        unsafe { clear_bytes_out(out, out_len) };
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
        let Ok(data) = t.export_checkpoint() else { return 0 };
        unsafe { copy_bytes(data, out, out_len) }
    })
}

/// Export bounded by a caller-supplied byte cap.
///
/// The effective limit is the smaller of `max_bytes` and the 64 MiB wire cap,
/// with 0 meaning the wire cap alone, and it bounds the whole blob including
/// its 20-byte container header. Returns 1 on success, 0 if the state does not
/// fit -- in which case nothing is written and the terminal is untouched.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_export_limited(
    vt: *mut ProdVt,
    max_bytes: u64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || {
        unsafe { clear_bytes_out(out, out_len) };
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
        let Ok(data) = t.export_checkpoint_limited(max_bytes) else { return 0 };
        unsafe { copy_bytes(data, out, out_len) }
    })
}

/// The checkpoint container version this build writes.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_version() -> u32 {
    guarded(0, Terminal::checkpoint_version)
}

/// Whether this build can import that container version.
///
/// Explicit negotiation: a peer decides from this, rather than inferring an
/// unreadable version from a failed import that also means "corrupt".
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_supports(version: u32) -> c_int {
    guarded(0, || if Terminal::checkpoint_supports(version) { 1 } else { 0 })
}

/// Read a checkpoint's declared version and geometry without decoding it.
///
/// Returns 1 and fills any non-null out parameter on success; 0 if the buffer
/// is not a checkpoint this build can read.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_inspect(
    data: *const u8,
    len: usize,
    out_version: *mut u32,
    out_cols: *mut u32,
    out_rows: *mut u32,
    out_payload_len: *mut u32,
) -> c_int {
    guarded(0, || {
        // Deterministic on failure too: a caller that forgets to check the return
        // reads zeroes, not the geometry of whatever it inspected last.
        unsafe {
            for p in [out_version, out_cols, out_rows, out_payload_len] {
                if !p.is_null() {
                    *p = 0;
                }
            }
        }
        if data.is_null() || len == 0 {
            return 0;
        }
        let slice = unsafe { std::slice::from_raw_parts(data, len) };
        let Ok(info) = Terminal::inspect_checkpoint(slice) else { return 0 };
        unsafe {
            if !out_version.is_null() {
                *out_version = info.version;
            }
            if !out_cols.is_null() {
                *out_cols = info.cols;
            }
            if !out_rows.is_null() {
                *out_rows = info.rows;
            }
            if !out_payload_len.is_null() {
                *out_payload_len = info.payload_len;
            }
        }
        1
    })
}

/// Alias for [`prod_vt_checkpoint`].
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_export(
    vt: *mut ProdVt,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    guarded(0, || prod_vt_checkpoint(vt, out, out_len))
}

/// Restore the terminal state from a native binary checkpoint.
///
/// Validates magic header, version, CRC32 checksum, dimension bounds, and data integrity.
/// Restoration is atomic: if the checkpoint is invalid or corrupted, the terminal state is unchanged.
/// Returns 1 on success, 0 on failure or invalid arguments.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_restore(
    vt: *mut ProdVt,
    data: *const u8,
    len: usize,
) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
        if data.is_null() || len == 0 {
            return 0;
        }
        let slice = unsafe { std::slice::from_raw_parts(data, len) };
        match t.import_checkpoint(slice) {
            Ok(()) => 1,
            Err(_) => 0,
        }
    })
}

/// Alias for [`prod_vt_restore`].
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_import(
    vt: *mut ProdVt,
    data: *const u8,
    len: usize,
) -> c_int {
    guarded(0, || prod_vt_restore(vt, data, len))
}

/// Inspect and verify a checkpoint buffer without mutating or referencing a terminal instance.
///
/// Returns 1 if header, version, length, and CRC32 checksum are valid, 0 otherwise.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_verify(
    data: *const u8,
    len: usize,
) -> c_int {
    guarded(0, || {
        if data.is_null() || len == 0 {
            return 0;
        }
        let slice = unsafe { std::slice::from_raw_parts(data, len) };
        if Terminal::verify_checkpoint(slice) {
            1
        } else {
            0
        }
    })
}

// ---------------------------------------------------------------------------
// Checkpoint ABI version 2: status-bearing, caller-owned buffers
// ---------------------------------------------------------------------------
//
// The functions above are the original CodeHaus surface and keep their
// contract exactly: `c_int`, 1 success, 0 failure. They are still exported and
// still linked by existing callers.
//
// What they cannot do is say *why*. Every refusal -- a NULL handle, a
// truncated buffer, a container this build is too old to read, a CRC mismatch,
// a state too large for the wire cap -- collapses into the same 0, so a caller
// cannot tell "renegotiate the version" from "the bytes are corrupt" from
// "your buffer was too small". Nor can it size a buffer without guessing.
//
// This surface answers both. It is additive: new symbols, a version a caller
// can query before binding to them, `0` for success and a negative typed
// status for every failure, deterministic out-parameters on *every* path, and
// a required-size diagnostic so a caller can allocate exactly once.

/// The version of the status-bearing checkpoint ABI this build exports.
///
/// A consumer queries [`prod_vt_checkpoint_abi_version`] at load time and
/// refuses to bind the `*2` symbols if it does not recognise the answer,
/// rather than inferring the ABI from whether `dlsym` happened to resolve.
pub const PROD_VT_CHECKPOINT_ABI_VERSION: u32 = 2;

/// Success. The only non-negative status.
pub const PROD_VT_OK: c_int = 0;
/// A required pointer argument was NULL, or a required length was 0.
pub const PROD_VT_ERR_NULL_ARGUMENT: c_int = -1;
/// The caller's buffer is too small; `*out_len` holds the size required.
pub const PROD_VT_ERR_BUFFER_TOO_SMALL: c_int = -2;
/// The buffer ended in the middle of a field.
pub const PROD_VT_ERR_UNEXPECTED_EOF: c_int = -3;
/// The buffer does not start with the checkpoint magic.
pub const PROD_VT_ERR_INVALID_MAGIC: c_int = -4;
/// The container version is outside what this build reads. Renegotiate.
pub const PROD_VT_ERR_UNSUPPORTED_VERSION: c_int = -5;
/// The payload CRC32 does not match the header. The bytes are damaged.
pub const PROD_VT_ERR_CHECKSUM_MISMATCH: c_int = -6;
/// The declared payload length disagrees with the bytes supplied.
pub const PROD_VT_ERR_INVALID_PAYLOAD_LENGTH: c_int = -7;
/// A field decoded to something structurally impossible.
pub const PROD_VT_ERR_INVALID_DATA: c_int = -8;
/// Declared geometry is outside the supported range.
pub const PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS: c_int = -9;
/// Decoding the container would allocate past the import budget.
pub const PROD_VT_ERR_ALLOCATION_LIMIT: c_int = -10;
/// The container exceeds the wire cap, on export or on import.
pub const PROD_VT_ERR_TOO_LARGE: c_int = -11;

/// Header and geometry of a checkpoint, as one C-visible record.
///
/// A struct rather than five out-parameters: adding a field to the record is a
/// visible ABI change a caller recompiles against, whereas adding a sixth
/// pointer parameter silently changes the call signature.
#[repr(C)]
pub struct ProdVtCheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

impl ProdVtCheckpointInfo {
    const ZERO: Self = Self {
        version: 0,
        flags: 0,
        cols: 0,
        rows: 0,
        payload_len: 0,
    };
}

fn checkpoint_status(err: &CheckpointError) -> c_int {
    match err {
        CheckpointError::UnexpectedEof => PROD_VT_ERR_UNEXPECTED_EOF,
        CheckpointError::InvalidMagic => PROD_VT_ERR_INVALID_MAGIC,
        CheckpointError::UnsupportedVersion(_) => PROD_VT_ERR_UNSUPPORTED_VERSION,
        CheckpointError::ChecksumMismatch { .. } => PROD_VT_ERR_CHECKSUM_MISMATCH,
        CheckpointError::InvalidPayloadLength { .. } => PROD_VT_ERR_INVALID_PAYLOAD_LENGTH,
        CheckpointError::InvalidData(_) => PROD_VT_ERR_INVALID_DATA,
        CheckpointError::DimensionOutOfBounds { .. } => PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS,
        CheckpointError::AllocationLimitExceeded => PROD_VT_ERR_ALLOCATION_LIMIT,
        CheckpointError::TooLarge { .. } => PROD_VT_ERR_TOO_LARGE,
    }
}

/// The version of the status-bearing checkpoint ABI this build exports.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_abi_version() -> u32 {
    guarded(0, || PROD_VT_CHECKPOINT_ABI_VERSION)
}

/// A static, NUL-terminated description of a status code.
///
/// Never NULL and never owned by the caller: the pointer is valid for the
/// lifetime of the library and must not be freed. An unrecognised code
/// describes itself as unknown rather than returning NULL, so a caller can log
/// it unconditionally.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_status_message(status: c_int) -> *const std::os::raw::c_char {
    let fail = c"unknown checkpoint status".as_ptr();
    guarded(fail, || {
        let s: &'static str = match status {
            PROD_VT_OK => "ok\0",
            PROD_VT_ERR_NULL_ARGUMENT => "null argument\0",
            PROD_VT_ERR_BUFFER_TOO_SMALL => "buffer too small\0",
            PROD_VT_ERR_UNEXPECTED_EOF => "unexpected end of checkpoint buffer\0",
            PROD_VT_ERR_INVALID_MAGIC => "invalid checkpoint magic\0",
            PROD_VT_ERR_UNSUPPORTED_VERSION => "unsupported checkpoint version\0",
            PROD_VT_ERR_CHECKSUM_MISMATCH => "checkpoint CRC32 mismatch\0",
            PROD_VT_ERR_INVALID_PAYLOAD_LENGTH => "invalid payload length\0",
            PROD_VT_ERR_INVALID_DATA => "invalid checkpoint data\0",
            PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS => "terminal dimension out of bounds\0",
            PROD_VT_ERR_ALLOCATION_LIMIT => "checkpoint memory limit exceeded\0",
            PROD_VT_ERR_TOO_LARGE => "checkpoint exceeds the wire limit\0",
            _ => "unknown checkpoint status\0",
        };
        s.as_ptr() as *const std::os::raw::c_char
    })
}

/// Export a checkpoint into a caller-owned buffer.
///
/// `max_bytes` is the caller's own cap, composed with the 64 MiB wire cap; 0
/// means the wire cap alone. It bounds the whole container, header included --
/// the same number import measures against.
///
/// `*out_len` is always written, on every path:
///
/// * [`PROD_VT_OK`] -- the number of bytes written into `buf`.
/// * [`PROD_VT_ERR_BUFFER_TOO_SMALL`] -- the number of bytes `buf` needs.
///   Nothing was written to `buf`; call again with a buffer that size.
/// * any other status -- 0.
///
/// So the two-call idiom is: pass `buf = NULL, cap = 0`, read the required
/// size out of `*out_len`, allocate, call again. `out_len` itself must not be
/// NULL; `buf` may be, if and only if `cap` is 0.
///
/// The terminal is never mutated, on any path.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_export2(
    vt: *mut ProdVt,
    max_bytes: u64,
    buf: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> c_int {
    prod_vt_checkpoint_export3(vt, 0, max_bytes, buf, cap, out_len)
}

/// [`prod_vt_checkpoint_export2`] in a chosen container version, so a host
/// can write the newest version its peer supports
/// ([`prod_vt_checkpoint_supports`]) and upgrading one side never makes the
/// other refuse its checkpoints. `version` 0 is the current version; one this
/// build cannot write fails with [`PROD_VT_ERR_UNSUPPORTED_VERSION`], with
/// `*out_len` 0. Everything else is exactly as in export2.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_export3(
    vt: *mut ProdVt,
    version: u32,
    max_bytes: u64,
    buf: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if out_len.is_null() {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        unsafe { *out_len = 0 };
        if buf.is_null() && cap != 0 {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        // Measure first, and with a counting sink. A caller in the sizing half of
        // the two-call idiom -- or one whose buffer turns out to be too small --
        // gets the exact figure without the checkpoint ever being materialized,
        // so asking how big a 64 MiB state is costs kilobytes rather than 64 MiB.
        let size = match t.measure_checkpoint_version(version, max_bytes) {
            Ok(size) => size as usize,
            Err(e) => return checkpoint_status(&e),
        };
        // The required size is reported before the capacity check, so a caller
        // that asked for a size gets one and a caller that guessed too small
        // learns the exact figure instead of doubling until it fits.
        unsafe { *out_len = size };
        if cap < size {
            return PROD_VT_ERR_BUFFER_TOO_SMALL;
        }
        let data = match t.export_checkpoint_version(version, max_bytes) {
            Ok(data) => data,
            Err(e) => {
                unsafe { *out_len = 0 };
                return checkpoint_status(&e);
            }
        };
        // The measurement and the export run the same encoder over the same
        // immutable terminal, so this cannot differ. It is checked rather than
        // assumed because the alternative to checking is a buffer overrun.
        if data.len() != size {
            unsafe { *out_len = data.len() };
            return PROD_VT_ERR_BUFFER_TOO_SMALL;
        }
        if !data.is_empty() {
            unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), buf, data.len()) };
        }
        PROD_VT_OK
    })
}

/// How many bytes [`prod_vt_checkpoint_export2`] would write, without writing
/// them.
///
/// The sizing half of the two-call idiom, spelled as its own entry point: a
/// caller that only wants the figure need not pass a NULL buffer to an export
/// function and read the size out of an error status. Same bound, same
/// refusals, same number.
///
/// `*out_len` is set to the required byte count on [`PROD_VT_OK`] and to 0 on
/// every failure. The terminal is never mutated.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_measure2(
    vt: *mut ProdVt,
    max_bytes: u64,
    out_len: *mut usize,
) -> c_int {
    prod_vt_checkpoint_measure3(vt, 0, max_bytes, out_len)
}

/// How many bytes [`prod_vt_checkpoint_export3`] would write for `version`
/// (0 for the current one), without writing them.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_measure3(
    vt: *mut ProdVt,
    version: u32,
    max_bytes: u64,
    out_len: *mut usize,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if out_len.is_null() {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        unsafe { *out_len = 0 };
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        match t.measure_checkpoint_version(version, max_bytes) {
            Ok(size) => {
                unsafe { *out_len = size as usize };
                PROD_VT_OK
            }
            Err(e) => checkpoint_status(&e),
        }
    })
}

/// Restore the terminal from a checkpoint, reporting why if it refuses.
///
/// Fail-intact, exactly as [`prod_vt_restore`]: on any negative status the
/// terminal is byte-for-byte what it was before the call.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_import2(
    vt: *mut ProdVt,
    data: *const u8,
    len: usize,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        if data.is_null() || len == 0 {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        let slice = unsafe { std::slice::from_raw_parts(data, len) };
        match t.import_checkpoint(slice) {
            Ok(()) => PROD_VT_OK,
            Err(e) => checkpoint_status(&e),
        }
    })
}

/// Read a checkpoint's header and geometry without decoding it.
///
/// `*out` is fully written on success and zeroed on every failure, so a caller
/// that ignores the status still reads zeroes rather than the previous
/// checkpoint's geometry.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_inspect2(
    data: *const u8,
    len: usize,
    out: *mut ProdVtCheckpointInfo,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if out.is_null() {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        unsafe { *out = ProdVtCheckpointInfo::ZERO };
        if data.is_null() || len == 0 {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        let slice = unsafe { std::slice::from_raw_parts(data, len) };
        match Terminal::inspect_checkpoint(slice) {
            Ok(info) => {
                unsafe {
                    *out = ProdVtCheckpointInfo {
                        version: info.version,
                        flags: info.flags,
                        cols: info.cols,
                        rows: info.rows,
                        payload_len: info.payload_len,
                    };
                }
                PROD_VT_OK
            }
            Err(e) => checkpoint_status(&e),
        }
    })
}

/// Whether a buffer is a checkpoint this build could import, and if not, why.
///
/// Header, version, declared length and CRC32 only -- it does not decode the
/// payload, so a container that passes here can still fail an import on a
/// structurally invalid field.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_verify2(data: *const u8, len: usize) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if data.is_null() || len == 0 {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        let slice = unsafe { std::slice::from_raw_parts(data, len) };
        match crate::terminal::checkpoint::validate(slice) {
            Ok(()) => PROD_VT_OK,
            Err(e) => checkpoint_status(&e),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_title(vt: *mut ProdVt, out: *mut *mut u8, out_len: *mut usize) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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
        let Some(t) = (unsafe { term(vt) }) else { return 0 };
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


#[cfg(test)]
mod tests {
    use super::*;

    /// A panic inside the closure must not escape `guarded`: it comes back
    /// as the caller-supplied failure value, exactly as a documented ABI
    /// failure would.
    #[test]
    fn guarded_returns_fail_value_on_panic() {
        let prev_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let result = guarded(42, || -> i32 { panic!("simulated engine bug") });
        std::panic::set_hook(prev_hook);
        assert_eq!(result, 42, "a panic must degrade to the fail value, not propagate");
    }

    /// The ordinary path is unaffected: `guarded` is transparent when `f`
    /// returns normally.
    #[test]
    fn guarded_returns_closure_value_when_no_panic() {
        assert_eq!(guarded(0, || 7), 7);
        assert_eq!(guarded(-1, || 0), 0);
    }

    /// Round-trip a heap buffer the way the C caller does.
    unsafe fn take(f: impl FnOnce(*mut *mut u8, *mut usize) -> c_int) -> Option<Vec<u8>> {
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        if f(&mut ptr, &mut len) == 0 {
            return None;
        }
        let out = if ptr.is_null() {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec()
        };
        prod_vt_buffer_free(ptr);
        Some(out)
    }

    #[test]
    fn lifecycle_write_and_text() {
        let vt = prod_vt_new(20, 5, 1000);
        assert!(!vt.is_null());
        let data = b"hello\r\nworld";
        prod_vt_write(vt, data.as_ptr(), data.len());
        let text = unsafe { take(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
        assert_eq!(String::from_utf8(text).unwrap(), "hello\nworld");
        prod_vt_free(vt);
    }

    #[test]
    fn null_handles_are_safe() {
        assert_eq!(prod_vt_resize(std::ptr::null_mut(), 10, 10, 0, 0), 0);
        prod_vt_write(std::ptr::null_mut(), b"x".as_ptr(), 1);
        prod_vt_discard_events(std::ptr::null_mut());
        prod_vt_scroll_bottom(std::ptr::null_mut());
        prod_vt_free(std::ptr::null_mut());
        prod_vt_buffer_free(std::ptr::null_mut());
        let mut flag: c_int = 0;
        assert_eq!(prod_vt_mode(std::ptr::null_mut(), 1000, &mut flag), 0);
    }

    #[test]
    fn discard_events_drops_queued_events_and_preserves_state() {
        let vt = prod_vt_new(20, 5, 100);
        // Repeated discard on empty queue is safe.
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);

        // Feed an OSC title and text
        let title_seq = b"\x1b]0;my new title\x07hello";
        prod_vt_write(vt, title_seq.as_ptr(), title_seq.len());

        let t = unsafe { term(vt) }.unwrap();
        assert!(!t.events.is_empty(), "events must be queued by OSC title");

        // Discard events
        prod_vt_discard_events(vt);

        let t = unsafe { term(vt) }.unwrap();
        assert!(t.events.is_empty(), "events must be drained by discard");

        // Repeated discard is safe
        prod_vt_discard_events(vt);

        // Title and grid text are preserved
        let title = unsafe { take(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
        assert_eq!(String::from_utf8(title).unwrap(), "my new title");

        let text = unsafe { take(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
        assert!(String::from_utf8(text).unwrap().contains("hello"));

        prod_vt_free(vt);
    }

    #[test]
    fn cursor_and_screen_state() {
        let vt = prod_vt_new(10, 4, 100);
        let seq = b"\x1b[2;3Hx";
        prod_vt_write(vt, seq.as_ptr(), seq.len());
        let mut cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
        assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
        assert_eq!((cursor.y, cursor.x), (1, 3));
        assert_eq!(cursor.visible, 1);

        let mut alt: c_int = -1;
        assert_eq!(prod_vt_active_screen(vt, &mut alt), 1);
        assert_eq!(alt, 0);
        let alt_on = b"\x1b[?1049h";
        prod_vt_write(vt, alt_on.as_ptr(), alt_on.len());
        assert_eq!(prod_vt_active_screen(vt, &mut alt), 1);
        assert_eq!(alt, 1);
        prod_vt_free(vt);
    }

    #[test]
    fn mode_queries_track_the_terminal() {
        let vt = prod_vt_new(10, 4, 100);
        let mut on: c_int = -1;
        assert_eq!(prod_vt_mode(vt, 1000, &mut on), 1);
        assert_eq!(on, 0);
        let seq = b"\x1b[?1000h\x1b[?1006h";
        prod_vt_write(vt, seq.as_ptr(), seq.len());
        assert_eq!(prod_vt_mode(vt, 1000, &mut on), 1);
        assert_eq!(on, 1);
        assert_eq!(prod_vt_mode(vt, 1006, &mut on), 1);
        assert_eq!(on, 1);
        prod_vt_free(vt);
    }

    #[test]
    fn scrollbar_and_viewport_scrolling() {
        let vt = prod_vt_new(10, 3, 1000);
        let data = b"a\r\nb\r\nc\r\nd\r\ne\r\nf";
        prod_vt_write(vt, data.as_ptr(), data.len());

        let mut bar = ProdVtScrollbar { total: 0, offset: 0, len: 0 };
        assert_eq!(prod_vt_scrollbar_state(vt, &mut bar), 1);
        assert_eq!(bar.len, 3);
        assert!(bar.total > 3, "history should have accumulated: {:?}", bar.total);
        let at_bottom = bar.offset;

        prod_vt_scroll_delta(vt, 2);
        let mut active: c_int = -1;
        assert_eq!(prod_vt_viewport_active(vt, &mut active), 1);
        assert_eq!(active, 0, "scrolled up, so no longer pinned to the bottom");
        assert_eq!(prod_vt_scrollbar_state(vt, &mut bar), 1);
        assert!(bar.offset < at_bottom);

        prod_vt_scroll_bottom(vt);
        assert_eq!(prod_vt_viewport_active(vt, &mut active), 1);
        assert_eq!(active, 1);
        prod_vt_free(vt);
    }

    #[test]
    fn ansi_render_carries_styles() {
        let vt = prod_vt_new(10, 2, 100);
        let data = b"\x1b[1;31mRED\x1b[0m";
        prod_vt_write(vt, data.as_ptr(), data.len());
        let ansi = unsafe { take(|o, l| prod_vt_viewport_ansi(vt, o, l)) }.unwrap();
        let s = String::from_utf8(ansi).unwrap();
        assert!(s.contains("RED"), "{:?}", s);
        assert!(s.contains("\x1b["), "styles must be present: {:?}", s);
        assert!(s.contains("31"), "red foreground must survive: {:?}", s);
        prod_vt_free(vt);
    }

    #[test]
    fn title_and_responses_drain() {
        let vt = prod_vt_new(10, 2, 100);
        let seq = b"\x1b]0;my title\x07\x1b[c";
        prod_vt_write(vt, seq.as_ptr(), seq.len());
        let title = unsafe { take(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
        assert_eq!(String::from_utf8(title).unwrap(), "my title");

        let resp = unsafe { take(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
        assert_eq!(resp, b"\x1b[?62;22c".to_vec());
        // Draining twice yields nothing.
        let again = unsafe { take(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
        assert!(again.is_empty());
        prod_vt_free(vt);
    }

    #[test]
    fn wheel_encoding_respects_mouse_modes() {
        let vt = prod_vt_new(80, 24, 100);
        // No tracking: nothing to send.
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        assert_eq!(prod_vt_encode_wheel(vt, 1, 5, 7, &mut ptr, &mut len), 0);

        let on = b"\x1b[?1000h\x1b[?1006h";
        prod_vt_write(vt, on.as_ptr(), on.len());
        let up = unsafe { take(|o, l| prod_vt_encode_wheel(vt, 1, 5, 7, o, l)) }.unwrap();
        assert_eq!(String::from_utf8(up).unwrap(), "\x1b[<64;6;8M");
        let down = unsafe { take(|o, l| prod_vt_encode_wheel(vt, 0, 5, 7, o, l)) }.unwrap();
        assert_eq!(String::from_utf8(down).unwrap(), "\x1b[<65;6;8M");
        prod_vt_free(vt);
    }

    #[test]
    fn resize_reflows_and_reports() {
        let vt = prod_vt_new(10, 3, 100);
        let data = b"abcdefghij";
        prod_vt_write(vt, data.as_ptr(), data.len());
        assert_eq!(prod_vt_resize(vt, 5, 3, 9, 18), 1);
        let text = unsafe { take(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
        assert_eq!(String::from_utf8(text).unwrap(), "abcde\nfghij");
        assert_eq!(prod_vt_resize(vt, 0, 3, 0, 0), 0, "zero dimensions rejected");
        prod_vt_free(vt);
    }

    #[test]
    fn snapshot_includes_scrollback() {
        let vt = prod_vt_new(5, 2, 100);
        let data = b"one\r\ntwo\r\nthree";
        prod_vt_write(vt, data.as_ptr(), data.len());
        let snap = unsafe { take(|o, l| prod_vt_snapshot_ansi(vt, o, l)) }.unwrap();
        let s = String::from_utf8(snap).unwrap();
        assert!(s.contains("one"), "scrollback must be included: {:?}", s);
        assert!(s.contains("three"), "{:?}", s);
        prod_vt_free(vt);
    }
}
