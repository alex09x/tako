/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Targeted behavioral tests for C ABI symbols in src/capi.rs.
//!
//! Exercises every C ABI entry point with raw C types, pointers, NULL handling,
//! buffer ownership via `prod_vt_buffer_free`, and validates observable state
//! matching the VT behaviour the engine implements.

pub(crate) use std::ffi::CStr;
pub(crate) use std::os::raw::{c_char, c_int, c_void};
pub(crate) use std::ptr::{null, null_mut};

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProdVtCursor {
    pub x: u16,
    pub y: u16,
    pub visible: c_int,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProdVtScrollbar {
    pub total: u64,
    pub offset: u64,
    pub len: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProdVtCheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

pub const PROD_VT_OK: c_int = 0;
pub const PROD_VT_ERR_NULL_ARGUMENT: c_int = -1;
pub const PROD_VT_ERR_BUFFER_TOO_SMALL: c_int = -2;
pub const PROD_VT_ERR_UNEXPECTED_EOF: c_int = -3;
pub const PROD_VT_ERR_INVALID_MAGIC: c_int = -4;
pub const PROD_VT_ERR_UNSUPPORTED_VERSION: c_int = -5;
pub const PROD_VT_ERR_CHECKSUM_MISMATCH: c_int = -6;
pub const PROD_VT_ERR_INVALID_PAYLOAD_LENGTH: c_int = -7;
pub const PROD_VT_ERR_INVALID_DATA: c_int = -8;
pub const PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS: c_int = -9;
pub const PROD_VT_ERR_ALLOCATION_LIMIT: c_int = -10;
pub const PROD_VT_ERR_TOO_LARGE: c_int = -11;

unsafe extern "C" {
    pub fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    pub fn prod_vt_free(vt: *mut c_void);
    pub fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    pub fn prod_vt_discard_events(vt: *mut c_void);
    pub fn prod_vt_resize(
        vt: *mut c_void,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> c_int;
    pub fn prod_vt_scroll_delta(vt: *mut c_void, delta: isize);
    pub fn prod_vt_scroll_bottom(vt: *mut c_void);
    pub fn prod_vt_mode(vt: *mut c_void, mode: u16, enabled: *mut c_int) -> c_int;
    pub fn prod_vt_active_screen(vt: *mut c_void, alternate: *mut c_int) -> c_int;
    pub fn prod_vt_viewport_active(vt: *mut c_void, active: *mut c_int) -> c_int;
    pub fn prod_vt_cursor_state(vt: *mut c_void, cursor: *mut ProdVtCursor) -> c_int;
    pub fn prod_vt_scrollbar_state(vt: *mut c_void, scrollbar: *mut ProdVtScrollbar) -> c_int;
    pub fn prod_vt_viewport_ansi(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_viewport_text(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_snapshot_ansi(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_snapshot_ansi_v2(
        vt: *mut c_void,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_checkpoint_export_limited(
        vt: *mut c_void,
        max_bytes: u64,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_version() -> u32;
    pub fn prod_vt_checkpoint_supports(version: u32) -> c_int;
    pub fn prod_vt_checkpoint_inspect(
        data: *const u8,
        len: usize,
        out_version: *mut u32,
        out_cols: *mut u32,
        out_rows: *mut u32,
        out_payload_len: *mut u32,
    ) -> c_int;
    pub fn prod_vt_checkpoint_export(
        vt: *mut c_void,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_restore(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    pub fn prod_vt_checkpoint_import(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    pub fn prod_vt_checkpoint_verify(data: *const u8, len: usize) -> c_int;
    pub fn prod_vt_checkpoint_abi_version() -> u32;
    pub fn prod_vt_checkpoint_status_message(status: c_int) -> *const c_char;
    pub fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_measure2(
        vt: *mut c_void,
        max_bytes: u64,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_import2(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    pub fn prod_vt_checkpoint_inspect2(
        data: *const u8,
        len: usize,
        out: *mut ProdVtCheckpointInfo,
    ) -> c_int;
    pub fn prod_vt_checkpoint_verify2(data: *const u8, len: usize) -> c_int;
    pub fn prod_vt_title(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_drain_responses(
        vt: *mut c_void,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_encode_wheel(
        vt: *mut c_void,
        up: c_int,
        column: u16,
        row: u16,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_buffer_free(data: *mut u8);
}

/// Retention anchor to pull the exported C ABI objects into this test binary.
pub(crate) fn exported_symbol_addresses() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_discard_events as *const (),
        c::prod_vt_resize as *const (),
        c::prod_vt_scroll_delta as *const (),
        c::prod_vt_scroll_bottom as *const (),
        c::prod_vt_mode as *const (),
        c::prod_vt_active_screen as *const (),
        c::prod_vt_viewport_active as *const (),
        c::prod_vt_cursor_state as *const (),
        c::prod_vt_scrollbar_state as *const (),
        c::prod_vt_viewport_ansi as *const (),
        c::prod_vt_viewport_text as *const (),
        c::prod_vt_snapshot_ansi as *const (),
        c::prod_vt_snapshot_ansi_v2 as *const (),
        c::prod_vt_checkpoint as *const (),
        c::prod_vt_checkpoint_export_limited as *const (),
        c::prod_vt_checkpoint_version as *const (),
        c::prod_vt_checkpoint_supports as *const (),
        c::prod_vt_checkpoint_inspect as *const (),
        c::prod_vt_checkpoint_export as *const (),
        c::prod_vt_restore as *const (),
        c::prod_vt_checkpoint_import as *const (),
        c::prod_vt_checkpoint_verify as *const (),
        c::prod_vt_checkpoint_abi_version as *const (),
        c::prod_vt_checkpoint_status_message as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_measure2 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
        c::prod_vt_checkpoint_inspect2 as *const (),
        c::prod_vt_checkpoint_verify2 as *const (),
        c::prod_vt_title as *const (),
        c::prod_vt_drain_responses as *const (),
        c::prod_vt_encode_wheel as *const (),
        c::prod_vt_buffer_free as *const (),
    ]
}

/// Helper to take ownership of a C ABI allocated buffer via `prod_vt_buffer_free`.
pub(crate) unsafe fn take_buffer<F>(f: F) -> Option<Vec<u8>>
where
    F: FnOnce(*mut *mut u8, *mut usize) -> c_int,
{
    let mut ptr: *mut u8 = null_mut();
    let mut len: usize = 0;
    let status = f(&mut ptr, &mut len);
    if status == 0 {
        return None;
    }
    let vec = if ptr.is_null() {
        Vec::new()
    } else {
        let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
        let copied = slice.to_vec();
        unsafe { prod_vt_buffer_free(ptr) };
        copied
    };
    Some(vec)
}

/// Helper to recalculate CRC32 on forged checkpoint payload for testing parser validations.
pub(crate) fn reseal_checkpoint(mut ckpt: Vec<u8>) -> Vec<u8> {
    assert!(ckpt.len() >= 20);
    let crc = tako_core::terminal::checkpoint::crc32(&ckpt[20..]);
    ckpt[16..20].copy_from_slice(&crc.to_le_bytes());
    ckpt
}

/// RAII wrapper for *mut c_void VT handle to ensure cleanup on panic.
pub(crate) struct TestVt(*mut c_void);

impl TestVt {
    pub(crate) fn new(cols: u16, rows: u16, max_scrollback: usize) -> Self {
        let ptr = unsafe { prod_vt_new(cols, rows, max_scrollback) };
        assert!(!ptr.is_null(), "prod_vt_new must not return null");
        Self(ptr)
    }

    pub(crate) fn write(&self, bytes: &[u8]) {
        unsafe { prod_vt_write(self.0, bytes.as_ptr(), bytes.len()) };
    }

    pub(crate) fn as_ptr(&self) -> *mut c_void {
        self.0
    }
}

impl Drop for TestVt {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { prod_vt_free(self.0) };
        }
    }
}
