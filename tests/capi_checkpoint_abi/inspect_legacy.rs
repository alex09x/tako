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

#[test]
fn inspect_fills_on_success_and_zeroes_on_failure() {
    let vt = vt_with(b"inspect me");
    let good = export_via_abi(vt, 0);

    let mut info = ZERO_INFO;
    let code = unsafe { prod_vt_checkpoint_inspect2(good.as_ptr(), good.len(), &mut info) };
    assert_eq!(code, PROD_VT_OK, "{}", status_text(code));
    assert_eq!(info.version, unsafe { prod_vt_checkpoint_version() });
    assert_eq!((info.cols, info.rows), (40, 10));
    assert_eq!(info.payload_len as usize, good.len() - 20);

    // A second call over a corrupt buffer must not leave the previous answer
    // sitting in the caller's struct.
    let mut bad = good.clone();
    bad[0] ^= 0xFF;
    let code = unsafe { prod_vt_checkpoint_inspect2(bad.as_ptr(), bad.len(), &mut info) };
    assert_eq!(code, PROD_VT_ERR_INVALID_MAGIC);
    assert_eq!(info, ZERO_INFO, "the 40x10 answer did not survive");

    let code =
        unsafe { prod_vt_checkpoint_inspect2(good.as_ptr(), good.len(), std::ptr::null_mut()) };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);

    unsafe { prod_vt_free(vt) };
}

#[test]
fn verify_reports_the_reason() {
    let vt = vt_with(b"verify me");
    let good = export_via_abi(vt, 0);

    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(good.as_ptr(), good.len()) },
        PROD_VT_OK
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(std::ptr::null(), 0) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    let mut bad = good.clone();
    bad[1] ^= 0xFF;
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(bad.as_ptr(), bad.len()) },
        PROD_VT_ERR_INVALID_MAGIC
    );

    unsafe { prod_vt_free(vt) };
}

// ---------------------------------------------------------------------------
// The legacy surface is preserved, and no longer leaves stale outputs
// ---------------------------------------------------------------------------

#[test]
fn legacy_boolean_symbols_still_mean_one_and_zero() {
    let vt = vt_with(b"legacy caller");

    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    assert_eq!(unsafe { prod_vt_checkpoint(vt, &mut ptr, &mut len) }, 1);
    assert!(!ptr.is_null() && len > 0);
    let blob = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    unsafe { prod_vt_buffer_free(ptr) };

    // The alias and the limited form agree with it.
    let mut ptr2: *mut u8 = std::ptr::null_mut();
    let mut len2: usize = 0;
    assert_eq!(
        unsafe { prod_vt_checkpoint_export(vt, &mut ptr2, &mut len2) },
        1
    );
    assert_eq!(unsafe { std::slice::from_raw_parts(ptr2, len2) }, &blob[..]);
    unsafe { prod_vt_buffer_free(ptr2) };

    let dest = unsafe { prod_vt_new(40, 10, 200) };
    assert_eq!(
        unsafe { prod_vt_restore(dest, blob.as_ptr(), blob.len()) },
        1
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_import(dest, blob.as_ptr(), blob.len()) },
        1
    );
    assert_eq!(unsafe { prod_vt_restore(dest, std::ptr::null(), 0) }, 0);
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify(blob.as_ptr(), blob.len()) },
        1
    );
    assert_eq!(unsafe { prod_vt_checkpoint_verify(std::ptr::null(), 0) }, 0);
    assert_eq!(
        unsafe { prod_vt_checkpoint_supports(prod_vt_checkpoint_version()) },
        1
    );
    assert_eq!(unsafe { prod_vt_checkpoint_supports(0) }, 0);

    unsafe { prod_vt_free(dest) };
    unsafe { prod_vt_free(vt) };
}

#[test]
fn legacy_failure_leaves_defined_outputs_not_the_callers_stale_ones() {
    // This is the shape the backend's probe hit: a boolean 0 with the caller's
    // previous `out`/`out_len` still in place, which reads as a 123-byte
    // buffer that was never produced.
    let stale = 123usize;
    let sentinel = 0xDEAD_BEEFusize as *mut u8;

    let mut ptr = sentinel;
    let mut len = stale;
    assert_eq!(
        unsafe { prod_vt_checkpoint(std::ptr::null_mut(), &mut ptr, &mut len) },
        0
    );
    assert!(ptr.is_null(), "out was cleared");
    assert_eq!(len, 0, "out_len was cleared");

    let mut ptr = sentinel;
    let mut len = stale;
    assert_eq!(
        unsafe { prod_vt_checkpoint_export_limited(std::ptr::null_mut(), 0, &mut ptr, &mut len) },
        0
    );
    assert!(ptr.is_null());
    assert_eq!(len, 0);

    // A caller-supplied cap the state cannot fit is the other failure path.
    let vt = vt_with(b"too small a cap");
    let mut ptr = sentinel;
    let mut len = stale;
    assert_eq!(
        unsafe { prod_vt_checkpoint_export_limited(vt, 8, &mut ptr, &mut len) },
        0
    );
    assert!(ptr.is_null());
    assert_eq!(len, 0);
    unsafe { prod_vt_free(vt) };

    // And the five-out-parameter inspect.
    let (mut v, mut c, mut r, mut p) = (7u32, 7u32, 7u32, 7u32);
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect(b"nope".as_ptr(), 4, &mut v, &mut c, &mut r, &mut p) },
        0
    );
    assert_eq!((v, c, r, p), (0, 0, 0, 0));
}
