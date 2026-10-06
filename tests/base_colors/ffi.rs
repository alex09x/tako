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
fn ffi_set_base_colors_resolves_into_rendered_cells() {
    let core = TakoCore::new(10, 3);
    core.set_base_colors(
        Some(rgb(BASE_FG.0, BASE_FG.1, BASE_FG.2)),
        Some(rgb(BASE_BG.0, BASE_BG.1, BASE_BG.2)),
        None,
        vec![FfiPaletteEntry {
            index: 1,
            color: rgb(BASE_IDX1.0, BASE_IDX1.1, BASE_IDX1.2),
        }],
    );

    // A plain glyph uses Color::Default, which must resolve to the host's
    // base -- not the FFI layer's brand fallback colors.
    core.feed(b"X".to_vec());
    let cell = core.get_cell(0, 0).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), BASE_FG);
    assert_eq!((cell.bg_r, cell.bg_g, cell.bg_b), BASE_BG);

    // An indexed color uses the base palette entry.
    core.feed(b"\x1b[38;5;1mY".to_vec());
    let cell = core.get_cell(0, 1).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), BASE_IDX1);

    // A program override wins over the base...
    core.feed(osc4_set(1, (9, 9, 9)));
    core.feed(b"\x1b[38;5;1mZ".to_vec());
    let cell = core.get_cell(0, 2).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), (9, 9, 9));

    // ...until OSC 104 resets it back to base, not the engine's built-in.
    core.feed(b"\x1b]104\x07".to_vec());
    core.feed(b"\x1b[38;5;1mW".to_vec());
    let cell = core.get_cell(0, 3).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), BASE_IDX1);
    assert_ne!((cell.fg_r, cell.fg_g, cell.fg_b), BUILTIN_IDX1);
}

#[test]
fn ffi_theme_change_updates_non_overridden_palette_entries_only() {
    let core = TakoCore::new(10, 3);
    core.set_base_colors(
        None,
        None,
        None,
        vec![
            FfiPaletteEntry {
                index: 1,
                color: rgb(BASE_IDX1.0, BASE_IDX1.1, BASE_IDX1.2),
            },
            FfiPaletteEntry {
                index: 2,
                color: rgb(BASE_IDX2.0, BASE_IDX2.1, BASE_IDX2.2),
            },
        ],
    );
    // Cell A references index 1 (left alone); cell B references index 2
    // (the program is about to override it).
    core.feed(b"\x1b[38;5;1mA\x1b[38;5;2mB".to_vec());

    let overridden_idx2 = (9, 9, 9);
    core.feed(osc4_set(2, overridden_idx2));

    // Host pushes a new theme touching both indices.
    let new_base_idx1 = (77, 88, 99);
    let new_base_idx2 = (55, 44, 33);
    core.set_base_colors(
        None,
        None,
        None,
        vec![
            FfiPaletteEntry {
                index: 1,
                color: rgb(new_base_idx1.0, new_base_idx1.1, new_base_idx1.2),
            },
            FfiPaletteEntry {
                index: 2,
                color: rgb(new_base_idx2.0, new_base_idx2.1, new_base_idx2.2),
            },
        ],
    );

    // The non-overridden index follows the new theme immediately...
    let cell_a = core.get_cell(0, 0).unwrap();
    assert_eq!((cell_a.fg_r, cell_a.fg_g, cell_a.fg_b), new_base_idx1);
    // ...but the program's explicit override is not clobbered.
    let cell_b = core.get_cell(0, 1).unwrap();
    assert_eq!((cell_b.fg_r, cell_b.fg_g, cell_b.fg_b), overridden_idx2);
}

/// The host's own "reset terminal" rebuilds the engine. It used to build a
/// bare one, so after a reset the default colors and every themed palette
/// entry fell back to the built-ins until the host thought to reapply them.
#[test]
fn ffi_reset_keeps_the_host_base_colors_and_drops_program_overrides() {
    let core = TakoCore::new(10, 3);
    core.set_base_colors(
        Some(rgb(BASE_FG.0, BASE_FG.1, BASE_FG.2)),
        Some(rgb(BASE_BG.0, BASE_BG.1, BASE_BG.2)),
        Some(rgb(BASE_CURSOR.0, BASE_CURSOR.1, BASE_CURSOR.2)),
        vec![FfiPaletteEntry {
            index: 1,
            color: rgb(BASE_IDX1.0, BASE_IDX1.1, BASE_IDX1.2),
        }],
    );
    core.feed(b"\x1b]10;#090909\x07".to_vec());
    core.feed(osc4_set(1, (9, 9, 9)));
    core.feed(b"old".to_vec());

    core.reset();

    core.feed(b"X\x1b[38;5;1mY".to_vec());
    let plain = core.get_cell(0, 0).unwrap();
    assert_eq!((plain.fg_r, plain.fg_g, plain.fg_b), BASE_FG);
    assert_eq!((plain.bg_r, plain.bg_g, plain.bg_b), BASE_BG);
    let indexed = core.get_cell(0, 1).unwrap();
    assert_eq!((indexed.fg_r, indexed.fg_g, indexed.fg_b), BASE_IDX1);

    // Still a reset: the old content and the program's override are gone.
    assert!(!core.buffer_text().contains("old"));
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(
        Some(BASE_FG),
        Some(BASE_BG),
        Some(BASE_CURSOR),
        &[(1, BASE_IDX1)],
    );
    term.feed(b"\x1b]10;#090909\x07");
    let fresh = term.fresh_keeping_host_config();
    assert_eq!(
        fresh.base_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );
    assert_eq!(
        fresh.default_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );
    assert_eq!(fresh.palette().get(1), BASE_IDX1);
    assert_eq!(fresh.palette().get(2), term.palette().base(2));
}
