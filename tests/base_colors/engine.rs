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
fn set_base_colors_applies_immediately_when_nothing_overridden() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(
        Some(BASE_FG),
        Some(BASE_BG),
        Some(BASE_CURSOR),
        &[(1, BASE_IDX1), (2, BASE_IDX2)],
    );

    assert_eq!(
        term.default_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );
    assert_eq!(
        term.base_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );
    assert_eq!(term.palette().get(1), BASE_IDX1);
    assert_eq!(term.palette().get(2), BASE_IDX2);
    assert_eq!(term.palette().base(1), BASE_IDX1);

    // An index the host never mentioned keeps the built-in default.
    assert_eq!(
        term.palette().get(3),
        tako_core::palette::Palette::new().get(3)
    );
}

#[test]
fn program_override_via_osc_wins_until_reset() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), None, None, &[(1, BASE_IDX1)]);

    // Program takes over fg and palette index 1.
    let program_fg = (200, 201, 202);
    let program_idx1 = (203, 204, 205);
    term.feed(b"\x1b]10;#c8c9ca\x07"); // 200,201,202
    term.feed(&osc4_set(1, program_idx1));

    assert_eq!(term.default_colors().0, Some(program_fg));
    assert_eq!(term.palette().get(1), program_idx1);

    // Host pushes a theme change while the program's overrides are live:
    // the live values must NOT move, only the recorded base does.
    let new_base_fg = (11, 22, 33);
    let new_base_idx1 = (44, 55, 66);
    term.set_base_colors(Some(new_base_fg), None, None, &[(1, new_base_idx1)]);

    assert_eq!(
        term.default_colors().0,
        Some(program_fg),
        "program's fg override got clobbered"
    );
    assert_eq!(
        term.palette().get(1),
        program_idx1,
        "program's palette override got clobbered"
    );
    assert_eq!(term.base_colors().0, Some(new_base_fg));
    assert_eq!(term.palette().base(1), new_base_idx1);
}

#[test]
fn theme_change_updates_non_overridden_entries_immediately() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(
        Some(BASE_FG),
        Some(BASE_BG),
        None,
        &[(1, BASE_IDX1), (2, BASE_IDX2)],
    );

    // Program only overrides index 2, leaves fg/bg/index1 alone.
    term.feed(&osc4_set(2, (9, 9, 9)));

    let new_fg = (7, 8, 9);
    let new_idx1 = (12, 13, 14);
    term.set_base_colors(
        Some(new_fg),
        Some(BASE_BG),
        None,
        &[(1, new_idx1), (2, (250, 250, 250))],
    );

    // Non-overridden entries follow the new base immediately.
    assert_eq!(term.default_colors().0, Some(new_fg));
    assert_eq!(term.palette().get(1), new_idx1);
    // The overridden entry stays put even though the host tried to move it.
    assert_eq!(term.palette().get(2), (9, 9, 9));
}

#[test]
fn osc104_all_and_by_index_restore_to_base_not_builtin() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(None, None, None, &[(1, BASE_IDX1), (2, BASE_IDX2)]);
    term.feed(&osc4_set(1, (1, 1, 1)));
    term.feed(&osc4_set(2, (2, 2, 2)));

    // Reset a single index.
    term.feed(b"\x1b]104;1\x07");
    assert_eq!(term.palette().get(1), BASE_IDX1);
    assert_ne!(term.palette().get(1), BUILTIN_IDX1);
    assert_eq!(
        term.palette().get(2),
        (2, 2, 2),
        "untouched index must stay overridden"
    );

    // Reset everything.
    term.feed(b"\x1b]104\x07");
    assert_eq!(term.palette().get(2), BASE_IDX2);
    assert_ne!(term.palette().get(2), BUILTIN_IDX2);
}

#[test]
fn osc110_111_112_restore_default_colors_to_base() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR), &[]);
    term.feed(b"\x1b]10;#010101\x07");
    term.feed(b"\x1b]11;#020202\x07");
    term.feed(b"\x1b]12;#030303\x07");
    assert_ne!(
        term.default_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );

    term.feed(b"\x1b]110\x07\x1b]111\x07\x1b]112\x07");
    assert_eq!(
        term.default_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );
}

#[test]
fn ris_restores_everything_to_base() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(
        Some(BASE_FG),
        Some(BASE_BG),
        Some(BASE_CURSOR),
        &[(1, BASE_IDX1)],
    );
    term.feed(b"\x1b]10;#010101\x07");
    term.feed(b"\x1b]11;#020202\x07");
    term.feed(b"\x1b]12;#030303\x07");
    term.feed(&osc4_set(1, (9, 9, 9)));

    term.feed(b"\x1bc"); // RIS

    assert_eq!(
        term.default_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );
    assert_eq!(term.palette().get(1), BASE_IDX1);
    assert_ne!(term.palette().get(1), BUILTIN_IDX1);
    // The host's base configuration itself survives RIS.
    assert_eq!(
        term.base_colors(),
        (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR))
    );
}

#[test]
fn ris_without_a_configured_base_clears_overrides_to_unconfigured() {
    // No set_base_colors call at all -- a program's OSC 10/11/12 overrides
    // must not survive a full reset either.
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]10;#010101\x07\x1b]11;#020202\x07");
    assert_eq!(
        term.default_colors(),
        (Some((1, 1, 1)), Some((2, 2, 2)), None)
    );

    term.feed(b"\x1bc"); // RIS
    assert_eq!(term.default_colors(), (None, None, None));
}
