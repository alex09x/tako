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
fn test_all_c_abi_symbols_linkable() {
    let addrs = exported_symbol_addresses();
    assert_eq!(addrs.len(), 36);
    assert!(addrs.iter().all(|p| !p.is_null()));
}

// ---------------------------------------------------------------------------
// copy_bytes & NULL argument safety (uncovered line ~49)
// ---------------------------------------------------------------------------

/// Pins NULL safety for output buffer pointers in all buffer-producing C ABI fns.
#[test]
fn test_null_out_params_return_zero() {
    let vt = TestVt::new(80, 24, 100);
    vt.write(b"hello world");

    let mut ptr: *mut u8 = null_mut();
    let mut len: usize = 0;

    // prod_vt_viewport_text
    assert_eq!(
        unsafe { prod_vt_viewport_text(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_viewport_text(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_viewport_text(vt.as_ptr(), null_mut(), null_mut()) },
        0
    );

    // prod_vt_viewport_ansi
    assert_eq!(
        unsafe { prod_vt_viewport_ansi(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_viewport_ansi(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );

    // prod_vt_snapshot_ansi
    assert_eq!(
        unsafe { prod_vt_snapshot_ansi(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_snapshot_ansi(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );

    // prod_vt_snapshot_ansi_v2
    assert_eq!(
        unsafe { prod_vt_snapshot_ansi_v2(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_snapshot_ansi_v2(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );

    // prod_vt_title
    assert_eq!(
        unsafe { prod_vt_title(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_title(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );

    // prod_vt_drain_responses
    assert_eq!(
        unsafe { prod_vt_drain_responses(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_drain_responses(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );

    // prod_vt_checkpoint
    assert_eq!(
        unsafe { prod_vt_checkpoint(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );

    // prod_vt_checkpoint_export
    assert_eq!(
        unsafe { prod_vt_checkpoint_export(vt.as_ptr(), null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_export(vt.as_ptr(), &mut ptr, null_mut()) },
        0
    );

    // prod_vt_checkpoint_export_limited
    assert_eq!(
        unsafe { prod_vt_checkpoint_export_limited(vt.as_ptr(), 1024, null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_export_limited(vt.as_ptr(), 1024, &mut ptr, null_mut()) },
        0
    );
}

// ---------------------------------------------------------------------------
// Wide characters & SGR color/attr combinations (uncovered lines ~89, 120-152)
// ---------------------------------------------------------------------------

/// Pins ANSI rendering of wide characters (spacer cell skip) and all cell attributes.
/// Wide characters occupy 2 cells with second cell marked as spacer.
#[test]
fn test_row_ansi_wide_characters_and_all_text_attributes() {
    let vt = TestVt::new(40, 10, 100);
    // Write wide char (CJK / emoji) followed by various SGR styling combinations:
    // 1=bold, 2=dim, 3=italic, 4=underline, 5=blink, 7=reverse, 8=hidden, 9=strikethrough
    let sgr_data = b"\xe4\xbd\xa0\xe5\xa5\xbd \x1b[1mB\x1b[2mD\x1b[3mI\x1b[4mU\x1b[5mK\x1b[7mR\x1b[8mH\x1b[9mS\x1b[0m";
    vt.write(sgr_data);

    let ansi_bytes = unsafe { take_buffer(|o, l| prod_vt_viewport_ansi(vt.as_ptr(), o, l)) }
        .expect("prod_vt_viewport_ansi must succeed");
    let ansi_str = String::from_utf8(ansi_bytes).expect("viewport ansi must be valid UTF-8");

    // The text must contain the wide characters and the styled letters
    assert!(ansi_str.contains("你好"), "must contain wide characters");
    assert!(ansi_str.contains("\x1b["), "must emit ANSI SGR escapes");
    assert!(
        ansi_str.contains(";1") || ansi_str.contains("\x1b[0;1"),
        "bold attr emitted"
    );
    assert!(ansi_str.contains(";2"), "dim attr emitted");
    assert!(ansi_str.contains(";3"), "italic attr emitted");
    assert!(ansi_str.contains(";4"), "underline attr emitted");
    assert!(ansi_str.contains(";5"), "blink attr emitted");
    assert!(ansi_str.contains(";7"), "reverse attr emitted");
    assert!(ansi_str.contains(";8"), "hidden attr emitted");
    assert!(ansi_str.contains(";9"), "strikethrough attr emitted");
}

/// Pins ANSI rendering of all foreground and background color formats:
/// standard (30-37, 40-47), bright (90-97, 100-107), 256-color (38;5, 48;5), and RGB (38;2, 48;2).
#[test]
fn test_row_ansi_all_color_variations() {
    let vt = TestVt::new(80, 10, 100);
    // Standard FG 0..7 and BG 0..7
    vt.write(b"\x1b[31;42mstd\x1b[0m\r\n");
    // Bright FG 8..15 and BG 8..15
    vt.write(b"\x1b[91;102mbright\x1b[0m\r\n");
    // 256-color FG and BG
    vt.write(b"\x1b[38;5;123;48;5;200m256\x1b[0m\r\n");
    // RGB truecolor FG and BG
    vt.write(b"\x1b[38;2;12;34;56;48;2;78;90;12mrgb\x1b[0m");

    let ansi_bytes = unsafe { take_buffer(|o, l| prod_vt_viewport_ansi(vt.as_ptr(), o, l)) }
        .expect("viewport ansi must succeed");
    let s = String::from_utf8(ansi_bytes).unwrap();

    assert!(s.contains(";31"), "standard red fg 31");
    assert!(s.contains(";42"), "standard green bg 42");
    assert!(s.contains(";91"), "bright red fg 91");
    assert!(s.contains(";102"), "bright green bg 102");
    assert!(s.contains("38;5;123"), "256 color fg 123");
    assert!(s.contains("48;5;200"), "256 color bg 200");
    assert!(s.contains("38;2;12;34;56"), "rgb color fg 12;34;56");
    assert!(s.contains("48;2;78;90;12"), "rgb color bg 78;90;12");
}

// ---------------------------------------------------------------------------
// prod_vt_write & prod_vt_discard_events (uncovered line ~174)
// ---------------------------------------------------------------------------

/// Pins zero-length and null data handling in `prod_vt_write`, plus `prod_vt_discard_events`.
#[test]
fn test_write_and_discard_events_safe() {
    let vt = TestVt::new(20, 5, 10);
    // Writing 0 len with valid ptr
    unsafe { prod_vt_write(vt.as_ptr(), b"test".as_ptr(), 0) };
    // Writing with null ptr
    unsafe { prod_vt_write(vt.as_ptr(), null(), 10) };
    // Writing on null vt
    unsafe { prod_vt_write(null_mut(), b"test".as_ptr(), 4) };

    // Discard events on null vt and valid vt
    unsafe { prod_vt_discard_events(null_mut()) };
    unsafe { prod_vt_discard_events(vt.as_ptr()) };

    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt.as_ptr(), o, l)) }.unwrap();
    assert_eq!(
        String::from_utf8(text).unwrap().trim(),
        "",
        "nothing should have been written"
    );
}

// ---------------------------------------------------------------------------
// prod_vt_resize & scrolling NULL / edge cases (uncovered lines ~199-232)
// ---------------------------------------------------------------------------
