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

use super::snapshot::*;
use super::terminal::*;
use super::types::{ProdVtCursor, ProdVtScrollbar, guarded, term};

/// Round-trip a heap buffer the way the C caller does.
unsafe fn take(f: impl FnOnce(*mut *mut u8, *mut usize) -> c_int) -> Option<Vec<u8>> {
    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    if f(&mut ptr, &mut len) == 0 {
        return None;
    }
    let out = if ptr.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec()
    };
    prod_vt_buffer_free(ptr);
    Some(out)
}

/// A panic inside the closure must not escape `guarded`: it comes back
/// as the caller-supplied failure value, exactly as a documented ABI
/// failure would.
#[test]
fn guarded_returns_fail_value_on_panic() {
    let prev_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = guarded(42, || -> i32 { panic!("simulated engine bug") });
    std::panic::set_hook(prev_hook);
    assert_eq!(
        result, 42,
        "a panic must degrade to the fail value, not propagate"
    );
}

/// The ordinary path is unaffected: `guarded` is transparent when `f`
/// returns normally.
#[test]
fn guarded_returns_closure_value_when_no_panic() {
    assert_eq!(guarded(0, || 7), 7);
    assert_eq!(guarded(-1, || 0), 0);
}

#[test]
fn lifecycle_write_and_text() {
    let vt = prod_vt_new(20, 5, 1000);
    assert!(!vt.is_null());
    let data = b"hello\r\nworld";
    prod_vt_write(vt, data.as_ptr(), data.len());
    let text = unsafe { take(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(text).unwrap(), "hello\nworld");
    prod_vt_free(vt);
}

#[test]
fn null_handles_are_safe() {
    assert_eq!(prod_vt_resize(std::ptr::null_mut(), 10, 10, 0, 0), 0);
    prod_vt_write(std::ptr::null_mut(), b"x".as_ptr(), 1);
    prod_vt_discard_events(std::ptr::null_mut());
    prod_vt_scroll_bottom(std::ptr::null_mut());
    prod_vt_free(std::ptr::null_mut());
    prod_vt_buffer_free(std::ptr::null_mut());
    let mut flag: c_int = 0;
    assert_eq!(prod_vt_mode(std::ptr::null_mut(), 1000, &mut flag), 0);
}

#[test]
fn discard_events_drops_queued_events_and_preserves_state() {
    let vt = prod_vt_new(20, 5, 100);
    // Repeated discard on empty queue is safe.
    prod_vt_discard_events(vt);
    prod_vt_discard_events(vt);

    // Feed an OSC title and text
    let title_seq = b"\x1b]0;my new title\x07hello";
    prod_vt_write(vt, title_seq.as_ptr(), title_seq.len());

    let t = unsafe { term(vt) }.unwrap();
    assert!(!t.events.is_empty(), "events must be queued by OSC title");

    // Discard events
    prod_vt_discard_events(vt);

    let t = unsafe { term(vt) }.unwrap();
    assert!(t.events.is_empty(), "events must be drained by discard");

    // Repeated discard is safe
    prod_vt_discard_events(vt);

    // Title and grid text are preserved
    let title = unsafe { take(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(title).unwrap(), "my new title");

    let text = unsafe { take(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    assert!(String::from_utf8(text).unwrap().contains("hello"));

    prod_vt_free(vt);
}

#[test]
fn cursor_and_screen_state() {
    let vt = prod_vt_new(10, 4, 100);
    let seq = b"\x1b[2;3Hx";
    prod_vt_write(vt, seq.as_ptr(), seq.len());
    let mut cursor = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!((cursor.y, cursor.x), (1, 3));
    assert_eq!(cursor.visible, 1);

    let mut alt: c_int = -1;
    assert_eq!(prod_vt_active_screen(vt, &mut alt), 1);
    assert_eq!(alt, 0);
    let alt_on = b"\x1b[?1049h";
    prod_vt_write(vt, alt_on.as_ptr(), alt_on.len());
    assert_eq!(prod_vt_active_screen(vt, &mut alt), 1);
    assert_eq!(alt, 1);
    prod_vt_free(vt);
}

#[test]
fn mode_queries_track_the_terminal() {
    let vt = prod_vt_new(10, 4, 100);
    let mut on: c_int = -1;
    assert_eq!(prod_vt_mode(vt, 1000, &mut on), 1);
    assert_eq!(on, 0);
    let seq = b"\x1b[?1000h\x1b[?1006h";
    prod_vt_write(vt, seq.as_ptr(), seq.len());
    assert_eq!(prod_vt_mode(vt, 1000, &mut on), 1);
    assert_eq!(on, 1);
    assert_eq!(prod_vt_mode(vt, 1006, &mut on), 1);
    assert_eq!(on, 1);
    prod_vt_free(vt);
}

#[test]
fn scrollbar_and_viewport_scrolling() {
    let vt = prod_vt_new(10, 3, 1000);
    let data = b"a\r\nb\r\nc\r\nd\r\ne\r\nf";
    prod_vt_write(vt, data.as_ptr(), data.len());

    let mut bar = ProdVtScrollbar {
        total: 0,
        offset: 0,
        len: 0,
    };
    assert_eq!(prod_vt_scrollbar_state(vt, &mut bar), 1);
    assert_eq!(bar.len, 3);
    assert!(
        bar.total > 3,
        "history should have accumulated: {:?}",
        bar.total
    );
    let at_bottom = bar.offset;

    prod_vt_scroll_delta(vt, 2);
    let mut active: c_int = -1;
    assert_eq!(prod_vt_viewport_active(vt, &mut active), 1);
    assert_eq!(active, 0, "scrolled up, so no longer pinned to the bottom");
    assert_eq!(prod_vt_scrollbar_state(vt, &mut bar), 1);
    assert!(bar.offset < at_bottom);

    prod_vt_scroll_bottom(vt);
    assert_eq!(prod_vt_viewport_active(vt, &mut active), 1);
    assert_eq!(active, 1);
    prod_vt_free(vt);
}

#[test]
fn ansi_render_carries_styles() {
    let vt = prod_vt_new(10, 2, 100);
    let data = b"\x1b[1;31mRED\x1b[0m";
    prod_vt_write(vt, data.as_ptr(), data.len());
    let ansi = unsafe { take(|o, l| prod_vt_viewport_ansi(vt, o, l)) }.unwrap();
    let s = String::from_utf8(ansi).unwrap();
    assert!(s.contains("RED"), "{:?}", s);
    assert!(s.contains("\x1b["), "styles must be present: {:?}", s);
    assert!(s.contains("31"), "red foreground must survive: {:?}", s);
    prod_vt_free(vt);
}

#[test]
fn title_and_responses_drain() {
    let vt = prod_vt_new(10, 2, 100);
    let seq = b"\x1b]0;my title\x07\x1b[c";
    prod_vt_write(vt, seq.as_ptr(), seq.len());
    let title = unsafe { take(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(title).unwrap(), "my title");

    let resp = unsafe { take(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
    assert_eq!(resp, b"\x1b[?62;22c".to_vec());
    // Draining twice yields nothing.
    let again = unsafe { take(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
    assert!(again.is_empty());
    prod_vt_free(vt);
}

#[test]
fn wheel_encoding_respects_mouse_modes() {
    let vt = prod_vt_new(80, 24, 100);
    // No tracking: nothing to send.
    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    assert_eq!(prod_vt_encode_wheel(vt, 1, 5, 7, &mut ptr, &mut len), 0);

    let on = b"\x1b[?1000h\x1b[?1006h";
    prod_vt_write(vt, on.as_ptr(), on.len());
    let up = unsafe { take(|o, l| prod_vt_encode_wheel(vt, 1, 5, 7, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(up).unwrap(), "\x1b[<64;6;8M");
    let down = unsafe { take(|o, l| prod_vt_encode_wheel(vt, 0, 5, 7, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(down).unwrap(), "\x1b[<65;6;8M");
    prod_vt_free(vt);
}

#[test]
fn resize_reflows_and_reports() {
    let vt = prod_vt_new(10, 3, 100);
    let data = b"abcdefghij";
    prod_vt_write(vt, data.as_ptr(), data.len());
    assert_eq!(prod_vt_resize(vt, 5, 3, 9, 18), 1);
    let text = unsafe { take(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(text).unwrap(), "abcde\nfghij");
    assert_eq!(
        prod_vt_resize(vt, 0, 3, 0, 0),
        0,
        "zero dimensions rejected"
    );
    prod_vt_free(vt);
}

#[test]
fn snapshot_includes_scrollback() {
    let vt = prod_vt_new(5, 2, 100);
    let data = b"one\r\ntwo\r\nthree";
    prod_vt_write(vt, data.as_ptr(), data.len());
    let snap = unsafe { take(|o, l| prod_vt_snapshot_ansi(vt, o, l)) }.unwrap();
    let s = String::from_utf8(snap).unwrap();
    assert!(s.contains("one"), "scrollback must be included: {:?}", s);
    assert!(s.contains("three"), "{:?}", s);
    prod_vt_free(vt);
}
