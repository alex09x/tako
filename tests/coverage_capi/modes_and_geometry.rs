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

/// Pins error handling for `prod_vt_resize` and negative/positive scroll deltas.
#[test]
fn test_resize_and_scrolling_edge_cases() {
    let vt = TestVt::new(20, 5, 100);

    // NULL vt
    assert_eq!(unsafe { prod_vt_resize(null_mut(), 10, 10, 8, 16) }, 0);
    // Zero cols
    assert_eq!(unsafe { prod_vt_resize(vt.as_ptr(), 0, 5, 8, 16) }, 0);
    // Zero rows
    assert_eq!(unsafe { prod_vt_resize(vt.as_ptr(), 10, 0, 8, 16) }, 0);

    // Valid resize
    assert_eq!(unsafe { prod_vt_resize(vt.as_ptr(), 30, 8, 10, 20) }, 1);

    // Scroll delta on NULL vt is a safe no-op
    unsafe { prod_vt_scroll_delta(null_mut(), 5) };
    unsafe { prod_vt_scroll_delta(null_mut(), -5) };
    unsafe { prod_vt_scroll_bottom(null_mut()) };

    // Fill lines to create scrollback
    for i in 1..=20 {
        vt.write(format!("line {}\r\n", i).as_bytes());
    }

    // Scroll up (positive delta)
    unsafe { prod_vt_scroll_delta(vt.as_ptr(), 5) };
    let mut active: c_int = -1;
    assert_eq!(
        unsafe { prod_vt_viewport_active(vt.as_ptr(), &mut active) },
        1
    );
    assert_eq!(active, 0, "viewport must not be active when scrolled up");

    // Scroll down (negative delta)
    unsafe { prod_vt_scroll_delta(vt.as_ptr(), -2) };
    assert_eq!(
        unsafe { prod_vt_viewport_active(vt.as_ptr(), &mut active) },
        1
    );
    assert_eq!(active, 0);

    // Scroll delta with 0 is no-op
    unsafe { prod_vt_scroll_delta(vt.as_ptr(), 0) };

    // Scroll to bottom restores active viewport
    unsafe { prod_vt_scroll_bottom(vt.as_ptr()) };
    assert_eq!(
        unsafe { prod_vt_viewport_active(vt.as_ptr(), &mut active) },
        1
    );
    assert_eq!(active, 1, "viewport must be active when scrolled to bottom");
}

// ---------------------------------------------------------------------------
// prod_vt_mode comprehensive test (uncovered lines ~233-257)
// ---------------------------------------------------------------------------

/// Pins querying every supported mode constant in `prod_vt_mode`, plus unknown mode.
#[test]
fn test_prod_vt_mode_all_variants() {
    let vt = TestVt::new(80, 24, 100);

    let mut enabled: c_int = -1;
    // NULL checks
    assert_eq!(unsafe { prod_vt_mode(null_mut(), 1000, &mut enabled) }, 0);
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1000, null_mut()) }, 0);

    // Unknown mode returns 0
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 9999, &mut enabled) }, 0);

    // Mode 9: Mouse X10 / Normal
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 9, &mut enabled) }, 1);
    assert_eq!(enabled, 0);

    // Mode 1000: Mouse Normal
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1000, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?1000h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1000, &mut enabled) }, 1);
    assert_eq!(enabled, 1);
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 9, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1002: ButtonEvent
    vt.write(b"\x1b[?1002h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1002, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1003: AnyEvent
    vt.write(b"\x1b[?1003h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1003, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1006: mouse_sgr
    vt.write(b"\x1b[?1006h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1006, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1005: mouse_utf8
    vt.write(b"\x1b[?1005h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1005, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1007: alternate_scroll
    vt.write(b"\x1b[?1007h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1007, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 7: autowrap
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 7, &mut enabled) }, 1);
    assert_eq!(enabled, 1); // default on
    vt.write(b"\x1b[?7l");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 7, &mut enabled) }, 1);
    assert_eq!(enabled, 0);

    // Mode 6: origin_mode
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 6, &mut enabled) }, 1);
    assert_eq!(enabled, 0); // default off
    vt.write(b"\x1b[?6h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 6, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1: cursor_key_app_mode
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?1h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 2004: bracketed_paste
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 2004, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?2004h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 2004, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1004: focus_events
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1004, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?1004h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1004, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 25: cursor_visible
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 25, &mut enabled) }, 1);
    assert_eq!(enabled, 1); // default visible
    vt.write(b"\x1b[?25l");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 25, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
}

// ---------------------------------------------------------------------------
// Screen, viewport, cursor & scrollbar NULL checks (lines ~260-312)
// ---------------------------------------------------------------------------

/// Pins NULL safety for screen/viewport/cursor/scrollbar query APIs.
#[test]
fn test_state_queries_null_safety() {
    let vt = TestVt::new(40, 10, 100);
    let mut val: c_int = 0;
    let mut cursor = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
    let mut bar = ProdVtScrollbar {
        total: 0,
        offset: 0,
        len: 0,
    };

    // active screen
    assert_eq!(unsafe { prod_vt_active_screen(null_mut(), &mut val) }, 0);
    assert_eq!(unsafe { prod_vt_active_screen(vt.as_ptr(), null_mut()) }, 0);

    // viewport active
    assert_eq!(unsafe { prod_vt_viewport_active(null_mut(), &mut val) }, 0);
    assert_eq!(
        unsafe { prod_vt_viewport_active(vt.as_ptr(), null_mut()) },
        0
    );

    // cursor state
    assert_eq!(unsafe { prod_vt_cursor_state(null_mut(), &mut cursor) }, 0);
    assert_eq!(unsafe { prod_vt_cursor_state(vt.as_ptr(), null_mut()) }, 0);

    // scrollbar state
    assert_eq!(unsafe { prod_vt_scrollbar_state(null_mut(), &mut bar) }, 0);
    assert_eq!(
        unsafe { prod_vt_scrollbar_state(vt.as_ptr(), null_mut()) },
        0
    );
}

// ---------------------------------------------------------------------------
// Viewport & snapshot ANSI with multi-row and scrollback (lines ~315-382)
// ---------------------------------------------------------------------------
