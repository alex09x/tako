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
fn bash_prompt_does_not_crash() {
    let mut t = t(80, 24);
    // typical PS1 with colors, bold, reset
    for _ in 0..10 {
        feeds(
            &mut t,
            "\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/projects\x1b[00m$ ",
        );
        feeds(&mut t, "ls -la\r\n");
        feeds(&mut t, "\x1b[01;34mtotal 42\x1b[m\r\n");
        feeds(&mut t, "drwxr-xr-x  5 user group  160 Aug  7 14:00 .\r\n");
        feeds(&mut t, "drwxr-xr-x 42 user group 1344 Aug  6 09:12 ..\r\n");
    }
}

#[test]
fn zsh_prompt_with_unicode_does_not_crash() {
    let mut t = t(80, 24);
    // zsh with Powerline-style prompt using Unicode glyphs
    for _ in 0..5 {
        feeds(
            &mut t,
            "\x1b[34;42m ~/proj \x1b[42;33m\u{e0b0}\x1b[30;43m main \x1b[43;0m\u{e0b0}\x1b[m ",
        );
        feeds(&mut t, "cargo test\r\n");
        feeds(&mut t, "\x1b[32mrunning 243 tests\x1b[m\r\n");
        feeds(
            &mut t,
            "test result: \x1b[32mok\x1b[m. 243 passed; 0 failed\r\n",
        );
    }
}

// ---------------------------------------------------------------------------
// Crash regression: sequences from actual crash logs
// ---------------------------------------------------------------------------

/// The TabBarView SIGABRT was triggered by mouse events during normal use.
/// On the Rust side: rapid alternate-screen toggles stress the grid switch
/// code path that is the underlying state the tab bar reads.
#[test]
fn rapid_alternate_screen_toggle_does_not_crash() {
    let mut t = t(80, 24);
    for _ in 0..200 {
        feeds(&mut t, "\x1b[?1049h");
        feeds(&mut t, "content in alt screen");
        feeds(&mut t, "\x1b[?1049l");
        feeds(&mut t, "content in main screen");
    }
}

/// Resize while the alternate screen is active (GlyphAtlas was called right
/// after resize with stale metrics).
#[test]
fn resize_during_alternate_screen_does_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "\x1b[?1049h\x1b[2J");
    for _ in 0..20 {
        t.resize(160, 48);
        feeds(&mut t, "\x1b[1;1H\x1b[32mHello\x1b[m");
        t.resize(40, 12);
        feeds(&mut t, "\x1b[1;1H\x1b[K");
        t.resize(80, 24);
    }
    feeds(&mut t, "\x1b[?1049l");
}

// ---------------------------------------------------------------------------
// Edge cases: malformed / truncated / adversarial sequences
// ---------------------------------------------------------------------------

/// Unterminated OSC strings should not hang or panic.
#[test]
fn unterminated_osc_does_not_crash() {
    let mut t = t(80, 24);
    // OSC without BEL or ST terminator — parser should absorb until limit
    feeds(&mut t, "\x1b]0;title that never ends");
    feeds(&mut t, "more data after unterminated osc\r\n");
    // then a proper sequence
    feeds(&mut t, "\x1b]0;properly terminated\x07");
    feeds(&mut t, "normal text\r\n");
}

/// DCS (Device Control String) passthrough fragments.
#[test]
fn dcs_passthrough_does_not_crash() {
    let mut t = t(80, 24);
    // Sixel-style DCS
    feeds(&mut t, "\x1bPq#0;2;0;0;0#1;2;100;0;0#2;2;0;0;100");
    feeds(&mut t, "AAAAAAAAAA\x1b\\");
    // tmux DCS wrapping
    feeds(&mut t, "\x1bP\x1b[?1049h\x1b\\");
    feeds(&mut t, "\x1bP\x1b[2J\x1b[H\x1b\\");
}

/// APC sequences (used by Kitty graphics protocol and iTerm2 inline images).
#[test]
fn apc_sequences_do_not_crash() {
    let mut t = t(80, 24);
    // Kitty graphics: transmit a tiny 1×1 red pixel (RGB, base64)
    feeds(&mut t, "\x1b_Ga=T,f=24,s=1,v=1,m=0;/9j/\x1b\\");
    // malformed APC (no ST terminator before more data)
    feeds(&mut t, "\x1b_garbage");
    feeds(&mut t, "normal text after\r\n");
}

/// Mixing right-to-left Unicode (Arabic/Hebrew) with LTR text.
#[test]
fn mixed_rtl_ltr_text_does_not_crash() {
    let mut t = t(80, 24);
    feeds(
        &mut t,
        "Hello \u{0645}\u{0631}\u{062d}\u{0628}\u{0627} World\r\n",
    );
    feeds(
        &mut t,
        "\u{05E9}\u{05DC}\u{05D5}\u{05DD} mixed with ascii\r\n",
    );
    feeds(&mut t, "Normal line\r\n");
}

/// Extremely long lines that wrap many times.
#[test]
fn very_long_line_does_not_crash() {
    let mut t = t(80, 24);
    // 10 000 chars — wraps 125 times
    let long = "X".repeat(10_000);
    feeds(&mut t, long.as_bytes());
    feeds(&mut t, b"\r\n");
    // then scrollback
    feeds(&mut t, "after long line\r\n");
}

/// Wide characters (CJK) at column boundaries.
#[test]
fn wide_chars_at_column_boundary_do_not_crash() {
    let mut t = t(10, 5);
    // 日 is 2-wide; at col 9 it should create a spacer head at col 9 and
    // place the glyph on the next row's col 0.
    feeds(&mut t, "123456789日本語テスト");
    feeds(&mut t, "\r\n");
    // back to back wide chars filling the row
    for _ in 0..10 {
        feeds(&mut t, "日");
    }
}

/// Combining characters stacked on a single cell.
#[test]
fn combining_chars_do_not_crash() {
    let mut t = t(80, 24);
    // Stack many combining marks on the same base char
    let base = 'a';
    let combining = [
        '\u{0300}', // combining grave
        '\u{0301}', // combining acute
        '\u{0302}', // combining circumflex
        '\u{0308}', // combining umlaut
        '\u{0327}', // combining cedilla
    ];
    let s: String = std::iter::once(base)
        .chain(combining.iter().copied())
        .collect();
    for _ in 0..80 {
        feeds(&mut t, s.as_bytes());
    }
}

/// Zero-width joiner sequences (emoji families, flags).
#[test]
fn zwj_emoji_sequences_do_not_crash() {
    let mut t = t(80, 10);
    // family: man+woman+girl+boy ZWJ sequence
    feeds(
        &mut t,
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\r\n",
    );
    // flag (regional indicator letters): 🇺🇸
    feeds(&mut t, "\u{1F1FA}\u{1F1F8} flag\r\n");
    // skin tone modifier
    feeds(&mut t, "\u{1F44D}\u{1F3FB} thumbs up light\r\n");
    // keycap sequence: 1️⃣
    feeds(&mut t, "1\u{FE0F}\u{20E3} keycap\r\n");
}
