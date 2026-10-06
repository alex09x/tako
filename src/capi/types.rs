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
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::terminal::Terminal;
use crate::terminal::checkpoint::CheckpointError;

/// Opaque handle handed to the C caller.
pub struct ProdVt {
    pub(crate) terminal: Terminal,
}

impl ProdVt {
    pub(crate) fn new(terminal: Terminal) -> Self {
        Self { terminal }
    }
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

/// The version of the status-bearing checkpoint ABI this build exports.
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
#[repr(C)]
pub struct ProdVtCheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

impl ProdVtCheckpointInfo {
    pub const ZERO: Self = Self {
        version: 0,
        flags: 0,
        cols: 0,
        rows: 0,
        payload_len: 0,
    };
}

/// Catches an unwind out of `f` and returns `fail` instead of letting it
/// cross the C ABI, where unwinding is undefined behaviour (and, with
/// `panic = "abort"`, simply aborts the process).
pub(crate) fn guarded<T>(fail: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fail)
}

/// Hand a heap buffer to C: `out` receives the pointer, `out_len` the
/// length. Returns 1 on success, 0 when the out-params are unusable.
pub(crate) unsafe fn copy_bytes(data: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) -> c_int {
    if out.is_null() || out_len.is_null() {
        return 0;
    }
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

pub(crate) unsafe fn term<'a>(vt: *mut ProdVt) -> Option<&'a mut Terminal> {
    if vt.is_null() {
        return None;
    }
    Some(unsafe { &mut (*vt).terminal })
}

/// Zero a byte-buffer out-parameter pair.
pub(crate) unsafe fn clear_bytes_out(out: *mut *mut u8, out_len: *mut usize) {
    unsafe {
        if !out.is_null() {
            *out = std::ptr::null_mut();
        }
        if !out_len.is_null() {
            *out_len = 0;
        }
    }
}

pub(crate) fn checkpoint_status(err: &CheckpointError) -> c_int {
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
