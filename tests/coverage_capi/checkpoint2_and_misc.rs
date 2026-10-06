/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

/// Pins NULL arguments and errors in `prod_vt_checkpoint_measure2`.
#[test]
fn test_checkpoint_measure2_null_and_error_paths() {
    let vt = TestVt::new(40, 10, 100);
    let mut out_len: usize = 999;

    // NULL out_len
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(vt.as_ptr(), 0, null_mut()) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL vt
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(null_mut(), 0, &mut out_len) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(out_len, 0, "out_len must be reset to 0 on NULL vt");

    // max_bytes too small -> PROD_VT_ERR_TOO_LARGE
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(vt.as_ptr(), 5, &mut out_len) },
        PROD_VT_ERR_TOO_LARGE
    );
    assert_eq!(out_len, 0, "out_len must be 0 on error");

    // Success path
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(vt.as_ptr(), 0, &mut out_len) },
        PROD_VT_OK
    );
    assert!(out_len > 0, "measured checkpoint size must be non-zero");
}

/// Pins `prod_vt_checkpoint_export2` NULL args, buffer sizing errors, and dimension errors.
#[test]
fn test_checkpoint_export2_null_and_error_paths() {
    let vt = TestVt::new(40, 10, 100);
    let mut out_len: usize = 999;
    let mut buf = [0u8; 1024];

    // NULL out_len
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_export2(vt.as_ptr(), 0, buf.as_mut_ptr(), buf.len(), null_mut())
        },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL buf when cap != 0
    assert_eq!(
        unsafe { prod_vt_checkpoint_export2(vt.as_ptr(), 0, null_mut(), 100, &mut out_len) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(out_len, 0);

    // NULL vt
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_export2(null_mut(), 0, buf.as_mut_ptr(), buf.len(), &mut out_len)
        },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(out_len, 0);

    // max_bytes too small -> PROD_VT_ERR_TOO_LARGE
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_export2(vt.as_ptr(), 5, buf.as_mut_ptr(), buf.len(), &mut out_len)
        },
        PROD_VT_ERR_TOO_LARGE
    );

    // Buffer too small (cap = 1) -> PROD_VT_ERR_BUFFER_TOO_SMALL with required size in out_len
    assert_eq!(
        unsafe { prod_vt_checkpoint_export2(vt.as_ptr(), 0, buf.as_mut_ptr(), 1, &mut out_len) },
        PROD_VT_ERR_BUFFER_TOO_SMALL
    );
    assert!(out_len > 1, "out_len must report required size");
}

/// Pins NULL arguments, dimension out of bounds, and invalid data in `prod_vt_checkpoint_import2`.
#[test]
fn test_checkpoint_import2_null_and_error_paths() {
    let vt = TestVt::new(40, 10, 100);

    // NULL vt
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(null_mut(), b"dummy".as_ptr(), 5) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL data or len == 0
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), null(), 5) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), b"dummy".as_ptr(), 0) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // Corrupt magic returns invalid magic
    let junk = b"not a valid checkpoint magic buffer 20 bytes long";
    let status = unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), junk.as_ptr(), junk.len()) };
    assert_eq!(status, PROD_VT_ERR_INVALID_MAGIC);

    // Export a valid checkpoint, tamper with dimensions, and verify PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS
    let mut valid_ckpt = unsafe {
        take_buffer(|o, l| prod_vt_checkpoint(vt.as_ptr(), o, l)).expect("export checkpoint")
    };
    // Bytes 20..24 are cols (u32 LE in payload). Set to 30,000 (> MAX_DIM 10,000)
    valid_ckpt[20..24].copy_from_slice(&30_000u32.to_le_bytes());
    let forged_dim = reseal_checkpoint(valid_ckpt);
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), forged_dim.as_ptr(), forged_dim.len()) },
        PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS
    );

    // Export a valid checkpoint, corrupt the inner payload data, reseal CRC, verify PROD_VT_ERR_INVALID_DATA
    let mut valid_ckpt2 = unsafe {
        take_buffer(|o, l| prod_vt_checkpoint_export(vt.as_ptr(), o, l)).expect("export checkpoint")
    };
    // Corrupt tab stops / cursor active buffer tag in payload (offset 28+)
    if valid_ckpt2.len() > 30 {
        valid_ckpt2[28] = 0xFF;
        let forged_data = reseal_checkpoint(valid_ckpt2);
        let err = unsafe {
            prod_vt_checkpoint_import2(vt.as_ptr(), forged_data.as_ptr(), forged_data.len())
        };
        assert!(err == PROD_VT_ERR_INVALID_DATA || err < 0);
    }
}

/// Pins NULL arguments and errors in `prod_vt_checkpoint_inspect2`.
#[test]
fn test_checkpoint_inspect2_null_and_error_paths() {
    let mut info = ProdVtCheckpointInfo {
        version: 99,
        flags: 99,
        cols: 99,
        rows: 99,
        payload_len: 99,
    };

    // NULL out
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(b"dummy".as_ptr(), 5, null_mut()) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL data or len == 0 zeroes out and returns error
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(null(), 5, &mut info) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(info.version, 0);

    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(b"dummy".as_ptr(), 0, &mut info) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(info.version, 0);

    // Corrupt data returns invalid magic
    let junk = b"corrupted header bytes longer than 20 bytes";
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(junk.as_ptr(), junk.len(), &mut info) },
        PROD_VT_ERR_INVALID_MAGIC
    );
    assert_eq!(info.version, 0);
}

/// Pins NULL arguments and validation in `prod_vt_checkpoint_verify2` and `prod_vt_checkpoint_verify`.
#[test]
fn test_checkpoint_verify_null_and_errors() {
    // NULL or len == 0 returns NULL_ARGUMENT
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(null(), 10) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(b"x".as_ptr(), 0) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // Less than 20 bytes returns unexpected EOF
    let short_junk = b"short buffer";
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(short_junk.as_ptr(), short_junk.len()) },
        PROD_VT_ERR_UNEXPECTED_EOF
    );

    // Old verify returns 0
    assert_eq!(unsafe { prod_vt_checkpoint_verify(null(), 10) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_verify(b"x".as_ptr(), 0) }, 0);
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify(short_junk.as_ptr(), short_junk.len()) },
        0
    );

    // Corrupt data of >= 20 bytes returns invalid magic
    let junk = b"bad checkpoint data 20 bytes long!!";
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(junk.as_ptr(), junk.len()) },
        PROD_VT_ERR_INVALID_MAGIC
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify(junk.as_ptr(), junk.len()) },
        0
    );
}

// ---------------------------------------------------------------------------
// prod_vt_encode_wheel comprehensive (uncovered lines ~946-981)
// ---------------------------------------------------------------------------

/// Pins `prod_vt_encode_wheel` for SGR, UTF-8, X10 encodings, and wheel up/down.
/// Wheel events encode button 64 (up) / 65 (down).
#[test]
fn test_encode_wheel_all_encodings_and_directions() {
    let vt = TestVt::new(80, 24, 100);

    let mut ptr: *mut u8 = null_mut();
    let mut len: usize = 0;

    // NULL vt returns 0
    assert_eq!(
        unsafe { prod_vt_encode_wheel(null_mut(), 1, 10, 5, &mut ptr, &mut len) },
        0
    );

    // Mouse tracking OFF returns 0
    assert_eq!(
        unsafe { prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, &mut ptr, &mut len) },
        0
    );

    // Enable mouse tracking (1000) with SGR encoding (1006)
    vt.write(b"\x1b[?1000h\x1b[?1006h");

    // SGR Wheel up
    let up_sgr =
        unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(up_sgr).unwrap(), "\x1b[<64;11;6M");

    // SGR Wheel down
    let down_sgr =
        unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 0, 10, 5, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(down_sgr).unwrap(), "\x1b[<65;11;6M");

    // Switch to UTF-8 encoding (1005), disable SGR (1006)
    vt.write(b"\x1b[?1006l\x1b[?1005h");
    let up_utf8 =
        unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, o, l)) }.unwrap();
    assert!(!up_utf8.is_empty(), "UTF8 wheel up emitted");
    let down_utf8 =
        unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 0, 10, 5, o, l)) }.unwrap();
    assert!(!down_utf8.is_empty(), "UTF8 wheel down emitted");

    // Disable UTF-8 (1005) -> default X10 encoding
    vt.write(b"\x1b[?1005l");
    let up_x10 =
        unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, o, l)) }.unwrap();
    assert_eq!(up_x10.len(), 6, "X10 mouse sequence is 6 bytes");
    let down_x10 =
        unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 0, 10, 5, o, l)) }.unwrap();
    assert_eq!(down_x10.len(), 6, "X10 mouse sequence is 6 bytes");

    // NULL out parameters return 0
    assert_eq!(
        unsafe { prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, &mut ptr, null_mut()) },
        0
    );
}

// ---------------------------------------------------------------------------
// Title and responses drainage
// ---------------------------------------------------------------------------

/// Pins `prod_vt_title` and `prod_vt_drain_responses`.
#[test]
fn test_title_and_drain_responses_c_abi() {
    let vt = TestVt::new(80, 24, 100);

    // Set title via OSC 2
    vt.write(b"\x1b]2;Special Test Title\x07");
    let title_bytes = unsafe { take_buffer(|o, l| prod_vt_title(vt.as_ptr(), o, l)) }.unwrap();
    assert_eq!(
        String::from_utf8(title_bytes).unwrap(),
        "Special Test Title"
    );

    // Query device attributes (DA1) -> causes terminal to emit response
    vt.write(b"\x1b[c");
    let resp = unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt.as_ptr(), o, l)) }.unwrap();
    assert!(!resp.is_empty(), "responses must be drained");

    // Second drain is empty
    let empty_resp =
        unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt.as_ptr(), o, l)) }.unwrap();
    assert!(empty_resp.is_empty(), "subsequent drain must be empty");
}

// ---------------------------------------------------------------------------
// ABI version and supports check
// ---------------------------------------------------------------------------

/// Pins `prod_vt_checkpoint_version`, `prod_vt_checkpoint_supports`, and `prod_vt_checkpoint_abi_version`.
#[test]
fn test_checkpoint_abi_versions_and_support() {
    let ver = unsafe { prod_vt_checkpoint_version() };
    assert_eq!(unsafe { prod_vt_checkpoint_supports(ver) }, 1);
    assert_eq!(unsafe { prod_vt_checkpoint_supports(999999) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_abi_version() }, 2);
}
