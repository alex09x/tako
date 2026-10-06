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
fn test_exported_symbols_present() {
    let addrs = exported_symbol_addresses();
    assert_eq!(addrs.len(), 10);
    assert!(addrs.iter().all(|p| !p.is_null()));
}

#[test]
fn test_discard_events_null_safety() {
    unsafe {
        prod_vt_discard_events(std::ptr::null_mut());
    }
}

#[test]
fn test_discard_events_repeated_calls_are_safe() {
    let vt = unsafe { prod_vt_new(80, 24, 100) };
    assert!(!vt.is_null());

    // Multiple discards on clean instance
    unsafe {
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
    }

    // Queue events
    let seq = b"\x1b]0;Title\x07\x07\x1b]52;c;dGVzdA==\x07";
    unsafe { write_seq(vt, seq) };

    // Multiple discards after events
    unsafe {
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
    }

    // Still operational
    let post = b"text";
    unsafe { write_seq(vt, post) };
    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    assert!(String::from_utf8_lossy(&text).contains("text"));

    unsafe { prod_vt_free(vt) };
}

#[test]
fn test_regression_control_retains_queued_payloads_without_discard() {
    // Demonstrates the defect: repeated large OSC title writes queue TerminalEvent
    // instances that are never drained by prod_vt_write, retaining memory on the heap.
    const UPDATES: usize = 10;
    const SIZE: usize = 1 << 20; // 1 MiB each -> ~10 MiB payload
    let expected_min_bytes = (UPDATES * SIZE) as i64;

    let payload = {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(vec![b'A'; SIZE])
    };

    let vt = unsafe { prod_vt_new(80, 24, 100) };

    arm_counter();

    for _ in 0..UPDATES {
        let mut osc = Vec::with_capacity(payload.len() + 16);
        osc.extend_from_slice(b"\x1b]52;c;");
        osc.extend_from_slice(payload.as_bytes());
        osc.push(0x07);
        unsafe { write_seq(vt, &osc) };
        drop(osc);
    }

    let retained_without_discard = live_bytes();
    disarm_counter();

    assert!(
        retained_without_discard >= expected_min_bytes,
        "regression control: without discard, {UPDATES} x 1 MiB OSC payloads must retain at least {expected_min_bytes} bytes, got {retained_without_discard}"
    );

    unsafe { prod_vt_free(vt) };
}

#[test]
fn test_queued_payload_storage_actually_released_by_discard() {
    const UPDATES: usize = 10;
    const SIZE: usize = 1 << 20; // 1 MiB each -> ~10 MiB payload
    let expected_min_bytes = (UPDATES * SIZE) as i64;

    let payload = {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(vec![b'A'; SIZE])
    };

    let vt = unsafe { prod_vt_new(80, 24, 100) };

    arm_counter();

    for _ in 0..UPDATES {
        let mut osc = Vec::with_capacity(payload.len() + 16);
        osc.extend_from_slice(b"\x1b]52;c;");
        osc.extend_from_slice(payload.as_bytes());
        osc.push(0x07);
        unsafe { write_seq(vt, &osc) };
        drop(osc);
    }

    let live_before = live_bytes();
    assert!(
        live_before >= expected_min_bytes,
        "pre-discard: expected at least {expected_min_bytes} bytes, got {live_before}"
    );

    // Call discard
    unsafe { prod_vt_discard_events(vt) };

    let live_after = live_bytes();
    disarm_counter();

    let released = live_before - live_after;
    assert!(
        released >= expected_min_bytes,
        "prod_vt_discard_events must release queued event payloads: released {released} bytes, expected at least {expected_min_bytes}"
    );

    unsafe { prod_vt_free(vt) };
}
