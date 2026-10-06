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

/// Pins viewport and snapshot ANSI multi-row output, scrollback formatting,
/// and wide character spacer handling in snapshot history.
#[test]
fn test_snapshot_ansi_scrollback_wide_chars_and_multiline() {
    let vt = TestVt::new(20, 3, 100);
    // Push lines into scrollback with wide characters
    vt.write(b"line 1 \xe4\xbd\xa0\xe5\xa5\xbd\r\n");
    vt.write(b"line 2 test\r\n");
    vt.write(b"line 3\r\n");
    vt.write(b"live screen 1\r\n");
    vt.write(b"live screen 2");

    // Test viewport ANSI (only live rows)
    let vp_ansi = unsafe { take_buffer(|o, l| prod_vt_viewport_ansi(vt.as_ptr(), o, l)) }.unwrap();
    let vp_str = String::from_utf8(vp_ansi).unwrap();
    assert!(
        vp_str.contains("live screen 1"),
        "viewport contains live screen row 1"
    );
    assert!(
        vp_str.contains("\r\n"),
        "multi-row output separated by CRLF"
    );

    // Test snapshot ANSI (scrollback + live rows)
    let snap_ansi =
        unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi(vt.as_ptr(), o, l)) }.unwrap();
    let snap_str = String::from_utf8(snap_ansi).unwrap();
    assert!(
        snap_str.contains("line 1 你好"),
        "scrollback contains line 1 with wide chars"
    );
    assert!(
        snap_str.contains("line 2 test"),
        "scrollback contains line 2"
    );
    assert!(
        snap_str.contains("live screen 2"),
        "snapshot contains live screen 2"
    );

    // NULL vt safety
    assert_eq!(
        unsafe { prod_vt_viewport_ansi(null_mut(), null_mut(), null_mut()) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_snapshot_ansi(null_mut(), null_mut(), null_mut()) },
        0
    );
}

// ---------------------------------------------------------------------------
// Snapshot ANSI v2 (uncovered lines ~401-447)
// ---------------------------------------------------------------------------

/// Pins `prod_vt_snapshot_ansi_v2` with scrollback, wide chars, hidden cursor,
/// and cursor position sequence.
#[test]
fn test_snapshot_ansi_v2_comprehensive() {
    let vt = TestVt::new(25, 4, 100);
    // Push lines into scrollback, including wide character spacers
    vt.write(b"sb1 \xe4\xbd\xa0\xe5\xa5\xbd\r\n");
    vt.write(b"sb2 text\r\n");
    // On screen: position cursor at (2, 5), hide cursor, write some text
    vt.write(b"\x1b[?25l"); // hide cursor
    vt.write(b"\x1b[2;5Hcontent");

    let snap_bytes = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt.as_ptr(), o, l)) }
        .expect("snapshot_ansi_v2 must succeed");
    let s = String::from_utf8(snap_bytes).unwrap();

    assert!(s.contains("sb1 你好"), "v2 scrollback includes wide chars");
    assert!(s.contains("content"), "v2 includes screen content");
    assert!(
        s.contains("\x1b[?25l"),
        "v2 emits cursor hide sequence when cursor is invisible"
    );
    assert!(s.contains("\x1b["), "v2 emits cursor position sequence");

    // Test with pending wrap: fill entire row of width 10
    let vt_wrap = TestVt::new(10, 3, 100);
    vt_wrap.write(b"0123456789"); // exactly 10 chars fills the row, cursor wraps next char
    let snap_wrap =
        unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt_wrap.as_ptr(), o, l)) }.unwrap();
    let s_wrap = String::from_utf8(snap_wrap).unwrap();
    assert!(s_wrap.contains("0123456789"));

    // Test NULL vt safety
    assert_eq!(
        unsafe { prod_vt_snapshot_ansi_v2(null_mut(), null_mut(), null_mut()) },
        0
    );
}

// ---------------------------------------------------------------------------
// Checkpoint inspect, export & restore error paths (lines ~547, 596, 711-713, 741-743)
// ---------------------------------------------------------------------------

/// Pins `prod_vt_checkpoint_inspect` with null data and invalid buffer.
#[test]
fn test_checkpoint_inspect_null_and_error() {
    let mut version: u32 = 99;
    let mut cols: u32 = 99;
    let mut rows: u32 = 99;
    let mut payload_len: u32 = 99;

    // NULL data or len == 0 writes zeroes and returns 0
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_inspect(
                null(),
                0,
                &mut version,
                &mut cols,
                &mut rows,
                &mut payload_len,
            )
        },
        0
    );
    assert_eq!((version, cols, rows, payload_len), (0, 0, 0, 0));

    // Garbage data returns 0 and leaves zeroes
    let junk = b"not a valid checkpoint header";
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_inspect(
                junk.as_ptr(),
                junk.len(),
                &mut version,
                &mut cols,
                &mut rows,
                &mut payload_len,
            )
        },
        0
    );
    assert_eq!((version, cols, rows, payload_len), (0, 0, 0, 0));
}

/// Pins `prod_vt_restore` and `prod_vt_checkpoint_import` failure on corrupt data.
#[test]
fn test_restore_and_import_rejects_corrupted_data() {
    let vt = TestVt::new(40, 10, 100);
    vt.write(b"preserved text");

    // NULL data or len == 0 returns 0
    assert_eq!(unsafe { prod_vt_restore(vt.as_ptr(), null(), 0) }, 0);
    assert_eq!(
        unsafe { prod_vt_checkpoint_import(vt.as_ptr(), null(), 0) },
        0
    );

    // Corrupt data returns 0
    let bad = b"corrupted bytes for checkpoint";
    assert_eq!(
        unsafe { prod_vt_restore(vt.as_ptr(), bad.as_ptr(), bad.len()) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_import(vt.as_ptr(), bad.as_ptr(), bad.len()) },
        0
    );

    // Verify terminal state remains intact (fail-intact contract)
    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt.as_ptr(), o, l)) }.unwrap();
    assert!(String::from_utf8(text).unwrap().contains("preserved text"));
}

/// Pins all status messages in `prod_vt_checkpoint_status_message` including unknown codes.
#[test]
fn test_checkpoint_status_messages_all_variants() {
    let cases = [
        (PROD_VT_OK, "ok"),
        (PROD_VT_ERR_NULL_ARGUMENT, "null argument"),
        (PROD_VT_ERR_BUFFER_TOO_SMALL, "buffer too small"),
        (
            PROD_VT_ERR_UNEXPECTED_EOF,
            "unexpected end of checkpoint buffer",
        ),
        (PROD_VT_ERR_INVALID_MAGIC, "invalid checkpoint magic"),
        (
            PROD_VT_ERR_UNSUPPORTED_VERSION,
            "unsupported checkpoint version",
        ),
        (PROD_VT_ERR_CHECKSUM_MISMATCH, "checkpoint CRC32 mismatch"),
        (PROD_VT_ERR_INVALID_PAYLOAD_LENGTH, "invalid payload length"),
        (PROD_VT_ERR_INVALID_DATA, "invalid checkpoint data"),
        (
            PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS,
            "terminal dimension out of bounds",
        ),
        (
            PROD_VT_ERR_ALLOCATION_LIMIT,
            "checkpoint memory limit exceeded",
        ),
        (PROD_VT_ERR_TOO_LARGE, "checkpoint exceeds the wire limit"),
        (-999, "unknown checkpoint status"),
        (42, "unknown checkpoint status"),
    ];

    for (status, expected) in cases {
        let ptr = unsafe { prod_vt_checkpoint_status_message(status) };
        assert!(!ptr.is_null());
        let cstr = unsafe { CStr::from_ptr(ptr) };
        assert_eq!(
            cstr.to_str().unwrap(),
            expected,
            "status {} message mismatch",
            status
        );
    }
}

// ---------------------------------------------------------------------------
// V2 Checkpoint API NULL & error paths (uncovered lines ~803, 838, 842, 849, 864, 892)
// ---------------------------------------------------------------------------
