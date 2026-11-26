/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! A palette change made while the alternate screen is shown reaches the
//! primary screen's rows a host cached from an earlier delta frame.

use crate::ffi::core::TakoCore;
use crate::ffi::types::{FfiPaletteEntry, FfiRgb};

const NEW: (u8, u8, u8) = (10, 20, 30);

/// Row 0's first foreground in a delta frame, or None when row 0 is not sent.
fn row0_fg(core: &TakoCore, since: u64) -> Option<(u8, u8, u8)> {
    let frame = core.render_frame_delta(since);
    let at = frame.row_indices.iter().position(|&row| row == 0)?;
    let offset = at * frame.row_stride as usize + 4;
    let cells = &frame.packed_cells;
    Some((cells[offset], cells[offset + 1], cells[offset + 2]))
}

/// Primary cached with red text, then `change` runs on the alternate screen
/// and the program leaves it before the next frame.
fn after_change_on_alternate(change: impl FnOnce(&TakoCore)) -> Option<(u8, u8, u8)> {
    let core = TakoCore::new(20, 3);
    core.feed(b"\x1b[31mA\x1b[0m".to_vec());
    let cached = core.render_frame_delta(0);
    core.feed(b"\x1b[?1049h".to_vec());
    change(&core);
    core.feed(b"\x1b[?1049l".to_vec());
    row0_fg(&core, cached.frame_version)
}

#[test]
fn a_theme_palette_change_on_the_alternate_screen_repaints_the_cached_primary() {
    let sent = after_change_on_alternate(|core| {
        let color = FfiRgb {
            r: NEW.0,
            g: NEW.1,
            b: NEW.2,
        };
        core.set_base_colors(None, None, None, vec![FfiPaletteEntry { index: 1, color }]);
    });
    assert_eq!(sent, Some(NEW));
}

#[test]
fn a_program_palette_change_repaints_the_rows_already_sent() {
    let core = TakoCore::new(20, 3);
    core.feed(b"\x1b[31mA\x1b[0m".to_vec());
    let cached = core.render_frame_delta(0);
    core.feed(b"\x1b]4;1;rgb:0a/14/1e\x1b\\".to_vec());
    assert_eq!(row0_fg(&core, cached.frame_version), Some(NEW));
}

#[test]
fn a_program_default_foreground_change_repaints_the_rows_already_sent() {
    let core = TakoCore::new(20, 3);
    core.feed(b"A".to_vec());
    let cached = core.render_frame_delta(0);
    core.feed(b"\x1b]10;rgb:0a/14/1e\x1b\\".to_vec());
    assert_eq!(row0_fg(&core, cached.frame_version), Some(NEW));
}

#[test]
fn a_colour_query_or_cursor_colour_repaints_nothing() {
    let core = TakoCore::new(20, 3);
    core.feed(b"\x1b[31mA\x1b[0m".to_vec());
    core.take_damage();
    core.feed(b"\x1b]4;1;?\x1b\\\x1b]10;?\x1b\\\x1b]12;rgb:0a/14/1e\x1b\\".to_vec());
    assert!(core.take_damage().is_empty());
}

#[test]
fn a_change_to_the_same_colour_or_a_bad_index_repaints_nothing() {
    let core = TakoCore::new(20, 3);
    core.feed(b"\x1b]4;1;rgb:0a/14/1e\x1b\\\x1b]10;rgb:0a/14/1e\x1b\\".to_vec());
    core.take_damage();
    core.feed(b"\x1b]4;1;rgb:0a/14/1e\x1b\\\x1b]10;rgb:0a/14/1e\x1b\\\x1b]104;x\x1b\\".to_vec());
    assert!(core.take_damage().is_empty());
}

#[test]
fn a_program_palette_change_on_the_alternate_screen_repaints_the_cached_primary() {
    let sent = after_change_on_alternate(|core| {
        core.feed(b"\x1b]4;1;rgb:0a/14/1e\x1b\\".to_vec());
    });
    assert_eq!(sent, Some(NEW));
}
