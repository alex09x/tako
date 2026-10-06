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
    PROD_VT_ERR_BUFFER_TOO_SMALL, PROD_VT_ERR_NULL_ARGUMENT, PROD_VT_OK, ProdVt,
    ProdVtCheckpointInfo, checkpoint_status, guarded, term,
};

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
