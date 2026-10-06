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
fn osc_color_query_storm_does_not_crash() {
    let mut t = t(80, 24);
    for _ in 0..500 {
        feeds(&mut t, "\x1b]10;?\x07");
        feeds(&mut t, "\x1b]11;?\x07");
        let _ = t.take_output();
    }
}

/// Mode set/reset storm (what a buggy app might do).
#[test]
fn mode_toggle_storm_does_not_crash() {
    let mut t = t(80, 24);
    let modes = [
        "\x1b[?1h", // app cursor
        "\x1b[?1l",
        "\x1b[?7h", // wraparound
        "\x1b[?7l",
        "\x1b[?25h", // cursor visible
        "\x1b[?25l",
        "\x1b[?1000h", // mouse X10
        "\x1b[?1000l",
        "\x1b[?1049h", // alt screen
        "\x1b[?1049l",
        "\x1b[?2004h", // bracketed paste
        "\x1b[?2004l",
    ];
    for _ in 0..100 {
        for m in &modes {
            feeds(&mut t, m.as_bytes());
        }
    }
}

/// Cursor save/restore around a resize — a common source of out-of-bounds.
#[test]
fn cursor_save_restore_across_resize_does_not_crash() {
    let mut t = t(80, 24);
    for _ in 0..50 {
        feeds(&mut t, "\x1b[12;40H"); // move cursor
        feeds(&mut t, "\x1b7"); // save (DEC)
        t.resize(40, 12);
        feeds(&mut t, "\x1b8"); // restore — must clamp to new size
        feeds(&mut t, "X");
        t.resize(80, 24);
        feeds(&mut t, "\x1b[s\x1b[u"); // ANSI save/restore
    }
}

/// Origin mode + margins: DECSTBM + cursor addressing.
#[test]
fn scroll_region_with_origin_mode_does_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "\x1b[5;20r"); // set scroll region rows 5-20
    feeds(&mut t, "\x1b[?6h"); // origin mode on
    for i in 1..=16u32 {
        feeds(&mut t, format!("\x1b[{i};1H\x1b[K  line {i}"));
    }
    feeds(&mut t, "\x1b[?6l"); // origin mode off
    feeds(&mut t, "\x1b[r"); // reset scroll region
}

/// Protected cells (DECSCA) should survive erase operations.
#[test]
fn protected_cells_do_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "\x1b[1\"q"); // DECSCA protect
    feeds(&mut t, "PROTECTED");
    feeds(&mut t, "\x1b[0\"q"); // DECSCA unprotect
    feeds(&mut t, "\x1b[?2K"); // selective erase
    feeds(&mut t, "\x1b[?1J"); // selective erase above
    feeds(&mut t, "\x1b[?2J"); // selective erase display
}

/// Kitty keyboard protocol: push / pop stack depth.
#[test]
fn kitty_keyboard_stack_does_not_crash() {
    let mut t = t(80, 24);
    // push 9 frames (max is 8; 9th drops the oldest)
    for flags in 0..9u8 {
        feeds(&mut t, format!("\x1b[={flags}u"));
    }
    // pop more than stack depth — should clamp gracefully
    feeds(&mut t, "\x1b[20;1u");
    // query
    feeds(&mut t, "\x1b[?u");
    let _ = t.take_output();
}

/// Hyperlinks (OSC 8) with nested and empty parameters.
#[test]
fn osc8_hyperlinks_do_not_crash() {
    let mut t = t(80, 24);
    // open a hyperlink
    feeds(&mut t, "\x1b]8;id=1;https://example.com\x07");
    feeds(&mut t, "click here");
    // close
    feeds(&mut t, "\x1b]8;;\x07");
    // empty URI
    feeds(&mut t, "\x1b]8;;\x07\x1b]8;;\x07");
    // very long URI (> 256 chars)
    let long_url = format!("\x1b]8;;https://example.com/{}\x07", "a".repeat(300));
    feeds(&mut t, long_url.as_bytes());
    feeds(&mut t, "text\x1b]8;;\x07\r\n");
}

/// Scrollback accumulation: fill scrollback past capacity without crashing.
#[test]
fn scrollback_overflow_does_not_crash() {
    let mut t = t(80, 24);
    // 12 000 lines > DEFAULT_SCROLLBACK_CAPACITY (10 000); oldest lines evict.
    for i in 0..12_000u32 {
        feeds(&mut t, format!("line {i:05}\r\n"));
    }
    // only verify the visible grid height, not that we panicked
    let visible = t.plain_string();
    assert!(visible.lines().count() <= 24);
}

/// Simultaneous resize + scrollback stress.
#[test]
fn resize_with_full_scrollback_does_not_crash() {
    let mut t = t(80, 24);
    for i in 0..500u32 {
        feeds(&mut t, format!("content line {i:03}\r\n"));
    }
    // reflow across a range of widths
    for cols in [40usize, 60, 80, 100, 120, 60, 40, 80] {
        t.resize(cols, 24);
    }
}

/// Extreme terminal sizes should not panic.
#[test]
fn extreme_sizes_do_not_crash() {
    for (cols, rows) in [(1, 1), (1, 200), (200, 1), (500, 200), (1, 1)] {
        let mut term = Terminal::new(cols, rows);
        feeds(&mut term, b"hello\r\nworld\r\n");
        feeds(&mut term, b"\x1b[2J\x1b[H");
        for _ in 0..10 {
            feeds(&mut term, b"\x1b[1;1H\x1b[K");
        }
    }
}
