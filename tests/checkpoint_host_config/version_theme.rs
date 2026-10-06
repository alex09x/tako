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
fn this_build_writes_version_6() {
    assert_eq!(CURRENT_VERSION, 6);
    assert_eq!(Terminal::checkpoint_version(), 6);
    let blob = themed_source().export_checkpoint().unwrap();
    assert_eq!(header_version(&blob), 6);
}

#[test]
fn a_theme_change_after_restore_reaches_what_the_theme_coloured() {
    let blob = themed_source().export_checkpoint().unwrap();
    let mut term = restored(&blob);

    // Before the destination says anything, the source's colours are on
    // screen, the program's among them.
    assert_eq!(term.palette().get(2), THEME_A_IDX2);
    assert_eq!(term.palette().get(1), PROGRAM_IDX1);
    assert_eq!(term.default_colors().0, Some(THEME_A_FG));

    term.set_base_colors(Some(THEME_B_FG), None, None, &[(2, THEME_B_IDX2)]);
    assert_eq!(
        term.palette().get(2),
        THEME_B_IDX2,
        "the theme's entry follows the new theme"
    );
    assert_eq!(
        term.default_colors().0,
        Some(THEME_B_FG),
        "so does the theme's foreground"
    );
    assert_eq!(
        term.palette().get(1),
        PROGRAM_IDX1,
        "the program's entry stays the program's"
    );

    // And a reset goes to the base the checkpoint carried, not the built-in.
    let mut again = restored(&blob);
    again.feed(b"\x1b]104\x07");
    assert_eq!(
        again.palette().get(1),
        tako_core::palette::Palette::new().get(1)
    );
    assert_eq!(again.palette().get(2), THEME_A_IDX2);
}

#[test]
fn a_v2_checkpoint_still_infers_what_it_does_not_carry() {
    let blob = themed_source().export_checkpoint_version(2, 0).unwrap();
    assert_eq!(header_version(&blob), 2);
    let mut term = restored(&blob);

    // Same screen...
    assert_eq!(term.palette().get(1), PROGRAM_IDX1);
    assert_eq!(term.palette().get(2), THEME_A_IDX2);
    // ...but no way to tell the theme's colour from a program's, so it is
    // kept as one: the behaviour v3 exists to fix, preserved for v2.
    term.set_base_colors(Some(THEME_B_FG), None, None, &[(2, THEME_B_IDX2)]);
    assert_eq!(term.palette().get(2), THEME_A_IDX2);
    assert_eq!(term.default_colors().0, Some(THEME_A_FG));
}

#[test]
fn the_default_cursor_style_travels_and_a_programs_style_stays_a_programs() {
    const BAR: CursorStyle = CursorStyle {
        shape: CursorShape::Bar,
        blinking: true,
    };
    const UNDERLINE: CursorStyle = CursorStyle {
        shape: CursorShape::Underline,
        blinking: false,
    };

    let mut host_styled = Terminal::new(20, 4);
    host_styled.set_default_cursor_style(BAR);
    let mut term = restored(&host_styled.export_checkpoint().unwrap());
    assert_eq!(term.cursor_style(), BAR);
    term.set_default_cursor_style(UNDERLINE);
    assert_eq!(
        term.cursor_style(),
        UNDERLINE,
        "the host's default follows the host"
    );

    let mut program_styled = Terminal::new(20, 4);
    program_styled.set_default_cursor_style(BAR);
    program_styled.feed(b"\x1b[4 q"); // DECSCUSR steady underline
    let mut term = restored(&program_styled.export_checkpoint().unwrap());
    term.set_default_cursor_style(BAR);
    assert_eq!(
        term.cursor_style(),
        UNDERLINE,
        "a program's choice outlives a host default"
    );
    // DECSCUSR 0 goes back to the default the checkpoint carried.
    let mut term = restored(&program_styled.export_checkpoint().unwrap());
    term.feed(b"\x1b[0 q");
    assert_eq!(term.cursor_style(), BAR);
}
