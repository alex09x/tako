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
fn every_symbol_the_consumer_links_is_present() {
    let addrs = exported_symbol_addresses();
    assert_eq!(addrs.len(), 21);
    assert!(addrs.iter().all(|p| !p.is_null()));
}

/// A terminal with a little state in it, through the C entry points.
fn vt_with(text: &[u8]) -> *mut c_void {
    let vt = unsafe { prod_vt_new(40, 10, 200) };
    assert!(!vt.is_null());
    unsafe { prod_vt_write(vt, text.as_ptr(), text.len()) };
    vt
}

/// The two-call idiom, as a C caller would write it.
fn export_via_abi(vt: *mut c_void, max_bytes: u64) -> Vec<u8> {
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

fn status_text(status: c_int) -> String {
    let p = unsafe { prod_vt_checkpoint_status_message(status) };
    assert!(!p.is_null(), "a status message is never NULL");
    unsafe { std::ffi::CStr::from_ptr(p) }
        .to_string_lossy()
        .into_owned()
}

// ---------------------------------------------------------------------------
// Negotiation
// ---------------------------------------------------------------------------

#[test]
fn abi_version_is_queryable_and_pinned() {
    assert_eq!(unsafe { prod_vt_checkpoint_abi_version() }, 2);
}

#[test]
fn every_status_has_a_message_and_none_is_null() {
    // Including a code this build has never heard of: a consumer logs the
    // status it got, whatever it got.
    for status in [
        PROD_VT_OK,
        PROD_VT_ERR_NULL_ARGUMENT,
        PROD_VT_ERR_BUFFER_TOO_SMALL,
        PROD_VT_ERR_UNEXPECTED_EOF,
        PROD_VT_ERR_INVALID_MAGIC,
        PROD_VT_ERR_UNSUPPORTED_VERSION,
        PROD_VT_ERR_CHECKSUM_MISMATCH,
        PROD_VT_ERR_INVALID_PAYLOAD_LENGTH,
        PROD_VT_ERR_TOO_LARGE,
        -9999,
    ] {
        assert!(!status_text(status).is_empty());
    }
    assert_eq!(status_text(PROD_VT_OK), "ok");
    assert_eq!(status_text(-9999), "unknown checkpoint status");
}

// ---------------------------------------------------------------------------
// Export: required-size diagnostics and deterministic outputs
// ---------------------------------------------------------------------------

#[test]
fn export_sizes_then_writes_exactly() {
    let vt = vt_with(b"sized export");
    let blob = export_via_abi(vt, 0);
    assert_eq!(&blob[..4], b"TKCK");

    // A buffer one byte short is refused, reports the real size, and writes
    // nothing -- the sentinel survives.
    let mut short = vec![0xABu8; blob.len() - 1];
    let mut needed: usize = 0;
    let code =
        unsafe { prod_vt_checkpoint_export2(vt, 0, short.as_mut_ptr(), short.len(), &mut needed) };
    assert_eq!(code, PROD_VT_ERR_BUFFER_TOO_SMALL);
    assert_eq!(needed, blob.len());
    assert!(short.iter().all(|&b| b == 0xAB), "nothing was written");

    unsafe { prod_vt_free(vt) };
}

#[test]
fn export_reports_zero_length_on_every_non_sizing_failure() {
    let vt = vt_with(b"deterministic outputs");

    // A caller cap the state cannot fit is a refusal, not a sizing hint: the
    // container is over the *declared limit*, so there is no size to report.
    let mut len: usize = 12345;
    let code = unsafe { prod_vt_checkpoint_export2(vt, 8, std::ptr::null_mut(), 0, &mut len) };
    assert_eq!(code, PROD_VT_ERR_TOO_LARGE, "{}", status_text(code));
    assert_eq!(len, 0, "the stale 12345 was overwritten");

    // A NULL handle likewise: status first, and the out-parameter defined.
    let mut len2: usize = 999;
    let code = unsafe {
        prod_vt_checkpoint_export2(std::ptr::null_mut(), 0, std::ptr::null_mut(), 0, &mut len2)
    };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);
    assert_eq!(len2, 0);

    // A NULL out_len is the one thing that cannot be made deterministic, so it
    // is rejected before anything else happens.
    let code =
        unsafe { prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, std::ptr::null_mut()) };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);

    // A NULL buffer with a non-zero capacity is a caller bug, not a size query.
    let mut len3: usize = 777;
    let code = unsafe { prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 64, &mut len3) };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);
    assert_eq!(len3, 0);

    unsafe { prod_vt_free(vt) };
}

// ---------------------------------------------------------------------------
// Import: typed refusals, and fail-intact
// ---------------------------------------------------------------------------

#[test]
fn import_reports_which_refusal_it_is() {
    let vt = vt_with(b"source state");
    let good = export_via_abi(vt, 0);

    let dest = unsafe { prod_vt_new(40, 10, 200) };
    let cases: Vec<(c_int, Vec<u8>)> = vec![
        (PROD_VT_ERR_NULL_ARGUMENT, Vec::new()),
        (PROD_VT_ERR_UNEXPECTED_EOF, good[..8].to_vec()),
        (PROD_VT_ERR_INVALID_MAGIC, {
            let mut b = good.clone();
            b[0] ^= 0xFF;
            b
        }),
        (PROD_VT_ERR_UNSUPPORTED_VERSION, {
            let mut b = good.clone();
            // Header layout: magic(4) | version(4) | flags(4) | len(4) | crc(4).
            b[4..8].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
            b
        }),
        (PROD_VT_ERR_INVALID_PAYLOAD_LENGTH, {
            let mut b = good.clone();
            b.pop();
            b
        }),
        (PROD_VT_ERR_CHECKSUM_MISMATCH, {
            let mut b = good.clone();
            let last = b.len() - 1;
            b[last] ^= 0xFF;
            b
        }),
    ];

    for (expected, blob) in cases {
        let code = unsafe { prod_vt_checkpoint_import2(dest, blob.as_ptr(), blob.len()) };
        assert_eq!(
            code,
            expected,
            "expected {}, got {}",
            status_text(expected),
            status_text(code)
        );
    }

    // Nothing above landed: the destination is still exactly what it was.
    let untouched = export_via_abi(dest, 0);
    let fresh = unsafe { prod_vt_new(40, 10, 200) };
    assert_eq!(untouched, export_via_abi(fresh, 0), "fail-intact");
    unsafe { prod_vt_free(fresh) };

    // And the good one still imports.
    let code = unsafe { prod_vt_checkpoint_import2(dest, good.as_ptr(), good.len()) };
    assert_eq!(code, PROD_VT_OK, "{}", status_text(code));
    assert_eq!(
        export_via_abi(dest, 0),
        good,
        "the round trip is byte-exact"
    );

    unsafe { prod_vt_free(dest) };
    unsafe { prod_vt_free(vt) };
}

// ---------------------------------------------------------------------------
// Inspect and verify
// ---------------------------------------------------------------------------
