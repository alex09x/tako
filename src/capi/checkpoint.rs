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

use crate::terminal::Terminal;

use super::types::{
    PROD_VT_CHECKPOINT_ABI_VERSION, PROD_VT_ERR_ALLOCATION_LIMIT, PROD_VT_ERR_BUFFER_TOO_SMALL,
    PROD_VT_ERR_CHECKSUM_MISMATCH, PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS, PROD_VT_ERR_INVALID_DATA,
    PROD_VT_ERR_INVALID_MAGIC, PROD_VT_ERR_INVALID_PAYLOAD_LENGTH, PROD_VT_ERR_NULL_ARGUMENT,
    PROD_VT_ERR_TOO_LARGE, PROD_VT_ERR_UNEXPECTED_EOF, PROD_VT_ERR_UNSUPPORTED_VERSION, PROD_VT_OK,
    ProdVt, clear_bytes_out, copy_bytes, guarded, term,
};

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
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        let Ok(data) = t.export_checkpoint() else {
            return 0;
        };
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
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
        let Ok(data) = t.export_checkpoint_limited(max_bytes) else {
            return 0;
        };
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
    guarded(0, || {
        if Terminal::checkpoint_supports(version) {
            1
        } else {
            0
        }
    })
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
        let Ok(info) = Terminal::inspect_checkpoint(slice) else {
            return 0;
        };
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
pub extern "C" fn prod_vt_restore(vt: *mut ProdVt, data: *const u8, len: usize) -> c_int {
    guarded(0, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return 0;
        };
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
pub extern "C" fn prod_vt_checkpoint_import(vt: *mut ProdVt, data: *const u8, len: usize) -> c_int {
    guarded(0, || prod_vt_restore(vt, data, len))
}

/// Inspect and verify a checkpoint buffer without mutating or referencing a terminal instance.
///
/// Returns 1 if header, version, length, and CRC32 checksum are valid, 0 otherwise.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_checkpoint_verify(data: *const u8, len: usize) -> c_int {
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
