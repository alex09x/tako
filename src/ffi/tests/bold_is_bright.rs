/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! `bold-is-bright` through the FFI: both cell paths the host draws from
//! (`get_cell` and the packed viewport) resolve the same colours.

use crate::ffi::core::TakoCore;
use crate::ffi::types::{DEFAULT_FG, FfiPaletteEntry, FfiRgb, PACKED_CELL_SIZE};
use crate::palette::Palette;

/// Column by column: bold red, plain red, bold bright red, bold 256-colour
/// 3, bold 256-colour 100, bold RGB, bold default foreground.
const LINE: &[u8] = b"\x1b[1;31mA\x1b[22;31mB\x1b[1;91mC\x1b[1;38;5;3mD\
\x1b[1;38;5;100mE\x1b[1;38;2;1;2;3mF\x1b[0;1mG\x1b[0m";

fn entry(index: u8) -> (u8, u8, u8) {
    Palette::new().get(index)
}

/// The foreground of row 0, `col`, read from both cell paths, which must agree.
fn fg(core: &TakoCore, col: u32) -> (u8, u8, u8) {
    let cell = core.get_cell(0, col).expect("cell in range");
    let packed = core.viewport_packed();
    let at = col as usize * PACKED_CELL_SIZE + 4;
    let from_packed = (packed[at], packed[at + 1], packed[at + 2]);
    let from_cell = (cell.fg_r, cell.fg_g, cell.fg_b);
    assert_eq!(from_cell, from_packed, "cell paths disagree at col {col}");
    from_cell
}

fn core_with_line(bold_is_bright: bool) -> TakoCore {
    let core = TakoCore::new(20, 3);
    core.set_bold_is_bright(bold_is_bright);
    core.feed(LINE.to_vec());
    core
}

#[test]
fn off_by_default_draws_bold_in_the_colour_it_names() {
    let core = TakoCore::new(20, 3);
    core.feed(LINE.to_vec());
    assert_eq!(fg(&core, 0), entry(1));
    assert_eq!(fg(&core, 1), entry(1));
    assert_eq!(fg(&core, 2), entry(9));
    assert_eq!(fg(&core, 3), entry(3));
    assert_eq!(fg(&core, 4), entry(100));
    assert_eq!(fg(&core, 5), (1, 2, 3));
    assert_eq!(fg(&core, 6), DEFAULT_FG);
}

#[test]
fn on_draws_bold_basic_colours_bright_and_nothing_else() {
    let core = core_with_line(true);
    assert_eq!(fg(&core, 0), entry(9), "bold red becomes bright red");
    assert_eq!(fg(&core, 1), entry(1), "plain red stays red");
    assert_eq!(fg(&core, 2), entry(9), "bold bright red stays bright red");
    assert_eq!(fg(&core, 3), entry(11), "bold 256-colour 3 becomes 11");
    assert_eq!(
        fg(&core, 4),
        entry(100),
        "256-colour 100 is not a basic colour"
    );
    assert_eq!(fg(&core, 5), (1, 2, 3), "RGB is drawn as given");
    assert_eq!(fg(&core, 6), DEFAULT_FG, "default foreground is unchanged");
    assert!(core.get_cell(0, 0).unwrap().bold, "the cell stays bold");
}

#[test]
fn the_bright_colour_comes_from_the_theme_and_from_a_program() {
    let core = core_with_line(true);
    let themed = FfiRgb {
        r: 10,
        g: 20,
        b: 30,
    };
    core.set_base_colors(
        None,
        None,
        None,
        vec![FfiPaletteEntry {
            index: 9,
            color: themed,
        }],
    );
    assert_eq!(fg(&core, 0), (10, 20, 30), "the theme's palette 9");

    core.feed(b"\x1b]4;9;rgb:aa/bb/cc\x1b\\".to_vec());
    assert_eq!(fg(&core, 0), (0xAA, 0xBB, 0xCC), "a program's OSC 4 for 9");
    assert_eq!(fg(&core, 1), entry(1));
}

#[test]
fn turning_it_on_or_off_redraws_every_row_once() {
    let core = core_with_line(false);
    core.take_damage();
    core.set_bold_is_bright(true);
    assert_eq!(core.take_damage().len(), 3);
    core.set_bold_is_bright(true);
    assert!(
        core.take_damage().is_empty(),
        "an unchanged setting redraws nothing"
    );
    core.set_bold_is_bright(false);
    assert_eq!(core.take_damage().len(), 3);
    assert_eq!(fg(&core, 0), entry(1));
}

/// A host that caches rows across `render_frame_delta` calls: the primary
/// screen is cached, the program enters the alternate screen, the setting
/// changes there, and the program leaves before the next frame. The primary
/// rows the host still holds were drawn with the old setting.
#[test]
fn a_toggle_on_the_alternate_screen_repaints_the_cached_primary() {
    let core = core_with_line(false);
    let cached = core.render_frame_delta(0);
    assert_eq!(fg(&core, 0), entry(1));

    core.feed(b"\x1b[?1049h".to_vec());
    core.set_bold_is_bright(true);
    core.feed(b"\x1b[?1049l".to_vec());

    let frame = core.render_frame_delta(cached.frame_version);
    let at = frame
        .row_indices
        .iter()
        .position(|&row| row == 0)
        .expect("the primary's row 0 is sent again");
    let offset = at * frame.row_stride as usize + 4;
    let sent = (
        frame.packed_cells[offset],
        frame.packed_cells[offset + 1],
        frame.packed_cells[offset + 2],
    );
    assert_eq!(sent, entry(9), "row 0 is sent with the new colour");
}

#[test]
fn a_reset_keeps_the_host_setting() {
    let core = core_with_line(true);
    core.reset();
    core.feed(LINE.to_vec());
    assert_eq!(fg(&core, 0), entry(9));
}

#[test]
fn a_restored_checkpoint_keeps_the_host_setting() {
    let off = core_with_line(false);
    let saved_off = off.checkpoint();
    let on = core_with_line(true);
    let saved_on = on.checkpoint();

    let host_on = TakoCore::new(20, 3);
    host_on.set_bold_is_bright(true);
    assert!(host_on.restore(saved_off));
    assert_eq!(
        fg(&host_on, 0),
        entry(9),
        "the restoring host's setting wins"
    );

    let host_off = TakoCore::new(20, 3);
    assert!(host_off.restore(saved_on));
    assert_eq!(fg(&host_off, 0), entry(1), "a checkpoint does not carry it");
}
