/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use std::os::raw::{c_char, c_int, c_void};

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProdVtCheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

pub const ZERO_INFO: ProdVtCheckpointInfo = ProdVtCheckpointInfo {
    version: 0,
    flags: 0,
    cols: 0,
    rows: 0,
    payload_len: 0,
};

// Status codes, spelled out rather than imported: a test that re-used the
// crate's constants would still pass if their values changed, and their values
// are the ABI.
pub const PROD_VT_OK: c_int = 0;
pub const PROD_VT_ERR_NULL_ARGUMENT: c_int = -1;
pub const PROD_VT_ERR_BUFFER_TOO_SMALL: c_int = -2;
pub const PROD_VT_ERR_UNEXPECTED_EOF: c_int = -3;
pub const PROD_VT_ERR_INVALID_MAGIC: c_int = -4;
pub const PROD_VT_ERR_UNSUPPORTED_VERSION: c_int = -5;
pub const PROD_VT_ERR_CHECKSUM_MISMATCH: c_int = -6;
pub const PROD_VT_ERR_INVALID_PAYLOAD_LENGTH: c_int = -7;
pub const PROD_VT_ERR_TOO_LARGE: c_int = -11;

unsafe extern "C" {
    pub fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    pub fn prod_vt_free(vt: *mut c_void);
    pub fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    pub fn prod_vt_buffer_free(data: *mut u8);

    pub fn prod_vt_checkpoint_abi_version() -> u32;
    pub fn prod_vt_checkpoint_status_message(status: c_int) -> *const c_char;
    pub fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_export3(
        vt: *mut c_void,
        version: u32,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_measure3(
        vt: *mut c_void,
        version: u32,
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

    // The original surface, still exported and still boolean.
    pub fn prod_vt_checkpoint(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_checkpoint_export(
        vt: *mut c_void,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_export_limited(
        vt: *mut c_void,
        max_bytes: u64,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_restore(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    pub fn prod_vt_checkpoint_import(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    pub fn prod_vt_checkpoint_verify(data: *const u8, len: usize) -> c_int;
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
}

/// Pull the exported objects into this test binary's link.
///
/// A `#[no_mangle]` function is exported unconditionally from the staticlib
/// and cdylib a C consumer links, but an integration test links the *rlib*,
/// and the linker drops any object file no Rust path references -- so the
/// `extern "C"` block above would fail to resolve symbols that are perfectly
/// present in the artifact CodeHaus consumes. Taking each address by its Rust
/// path is what keeps the objects; every call below still goes through the
/// extern declarations, by symbol name.
pub fn exported_symbol_addresses() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_buffer_free as *const (),
        c::prod_vt_checkpoint_abi_version as *const (),
        c::prod_vt_checkpoint_status_message as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_export3 as *const (),
        c::prod_vt_checkpoint_measure3 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
        c::prod_vt_checkpoint_inspect2 as *const (),
        c::prod_vt_checkpoint_verify2 as *const (),
        c::prod_vt_checkpoint as *const (),
        c::prod_vt_checkpoint_export as *const (),
        c::prod_vt_checkpoint_export_limited as *const (),
        c::prod_vt_restore as *const (),
        c::prod_vt_checkpoint_import as *const (),
        c::prod_vt_checkpoint_verify as *const (),
        c::prod_vt_checkpoint_version as *const (),
        c::prod_vt_checkpoint_supports as *const (),
        c::prod_vt_checkpoint_inspect as *const (),
    ]
}

/// A terminal with a little state in it, through the C entry points.
pub fn vt_with(text: &[u8]) -> *mut c_void {
    let vt = unsafe { prod_vt_new(40, 10, 200) };
    assert!(!vt.is_null());
    unsafe { prod_vt_write(vt, text.as_ptr(), text.len()) };
    vt
}

/// The two-call idiom, as a C caller would write it.
pub fn export_via_abi(vt: *mut c_void, max_bytes: u64) -> Vec<u8> {
    let mut needed: usize = 0;
    let sized =
        unsafe { prod_vt_checkpoint_export2(vt, max_bytes, std::ptr::null_mut(), 0, &mut needed) };
    assert_eq!(sized, PROD_VT_ERR_BUFFER_TOO_SMALL);
    assert!(needed > 0);

    let mut buf = vec![0u8; needed];
    let mut written: usize = 0;
    let code = unsafe {
        prod_vt_checkpoint_export2(vt, max_bytes, buf.as_mut_ptr(), buf.len(), &mut written)
    };
    assert_eq!(code, PROD_VT_OK, "{}", status_text(code));
    assert_eq!(
        written, needed,
        "the sizing call and the writing call agree"
    );
    buf.truncate(written);
    buf
}

pub fn status_text(status: c_int) -> String {
    let p = unsafe { prod_vt_checkpoint_status_message(status) };
    assert!(!p.is_null(), "a status message is never NULL");
    unsafe { std::ffi::CStr::from_ptr(p) }
        .to_string_lossy()
        .into_owned()
}
