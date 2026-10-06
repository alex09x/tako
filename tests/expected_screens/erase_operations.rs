/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::check;

#[test]
fn ech_simple_operation() {
    // ECH Simple Operation
    check(8, 1, &["ABC", "\x1b[1G", "\x1b[2X"], &["  C     "], (0, 0));
}

#[test]
fn ech_erasing_beyond_edge_of_screen() {
    // ECH Erasing Beyond Edge of Screen
    check(
        8,
        1,
        &["\x1b[8G", "\x1b[2D", "ABC", "\x1b[D", "\x1b[10X"],
        &["     A  "],
        (0, 6),
    );
}

#[test]
fn ech_reset_pending_wrap_state() {
    // ECH Reset Pending Wrap State
    check(
        8,
        1,
        &["\x1b[8G", "A", "\x1b[X", "X"],
        &["       X"],
        (0, 7),
    );
}

#[test]
fn ech_with_sgr_state() {
    // ECH with SGR State
    check(
        8,
        1,
        &["ABC", "\x1b[1G", "\x1b[41m", "\x1b[2X"],
        &["  C     "],
        (0, 0),
    );
}

#[test]
fn ech_multi_cell_character() {
    // ECH Multi-cell Character
    check(
        8,
        1,
        &["橋BC", "\x1b[1G", "\x1b[X", "X"],
        &["X BC    "],
        (0, 1),
    );
}

#[test]
fn ech_left_right_scroll_region_ignored() {
    // ECH Left/Right Scroll Region Ignored
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[1;3s",
            "\x1b[4G",
            "ABC",
            "\x1b[1G",
            "\x1b[4X",
        ],
        &["    BC    "],
        (0, 0),
    );
}

#[test]
fn el_simple_erase_right() {
    // EL Simple Erase Right
    check(
        8,
        1,
        &["ABCDE", "\x1b[3G", "\x1b[0K"],
        &["AB      "],
        (0, 2),
    );
}

#[test]
fn el_erase_right_resets_pending_wrap() {
    // EL Erase Right Resets Pending Wrap
    check(
        8,
        1,
        &["\x1b[8G", "A", "\x1b[0K", "X"],
        &["       X"],
        (0, 7),
    );
}

#[test]
fn el_erase_right_with_sgr_state() {
    // EL Erase Right with SGR State
    check(
        8,
        1,
        &["ABC", "\x1b[2G", "\x1b[41m", "\x1b[0K"],
        &["A       "],
        (0, 1),
    );
}

#[test]
fn el_erase_right_multi_cell_character() {
    // EL Erase Right Multi-cell Character
    check(
        8,
        1,
        &["AB橋DE", "\x1b[4G", "\x1b[0K"],
        &["AB      "],
        (0, 3),
    );
}

#[test]
fn el_erase_right_with_left_right_margins() {
    // EL Erase Right with Left/Right Margins
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABCDE",
            "\x1b[?69h",
            "\x1b[1;3s",
            "\x1b[2G",
            "\x1b[0K",
        ],
        &["A         "],
        (0, 1),
    );
}

#[test]
fn el_simple_erase_left() {
    // EL Simple Erase Left
    check(
        8,
        1,
        &["ABCDE", "\x1b[3G", "\x1b[1K"],
        &["   DE   "],
        (0, 2),
    );
}

#[test]
fn el_erase_left_with_sgr_state() {
    // EL Erase Left with SGR State
    check(
        8,
        1,
        &["ABC", "\x1b[2G", "\x1b[41m", "\x1b[1K"],
        &["  C     "],
        (0, 1),
    );
}

#[test]
fn el_erase_left_multi_cell_character() {
    // EL Erase Left Multi-cell Character
    check(
        8,
        1,
        &["AB橋DE", "\x1b[3G", "\x1b[1K"],
        &["    DE  "],
        (0, 2),
    );
}

#[test]
fn el_simple_erase_complete_line() {
    // EL Simple Erase Complete Line
    check(
        8,
        1,
        &["ABCDE", "\x1b[3G", "\x1b[2K"],
        &["        "],
        (0, 2),
    );
}

#[test]
fn el_erase_complete_with_sgr_state() {
    // EL Erase Complete with SGR State
    check(
        8,
        1,
        &["ABC", "\x1b[2G", "\x1b[41m", "\x1b[2K"],
        &["        "],
        (0, 1),
    );
}
