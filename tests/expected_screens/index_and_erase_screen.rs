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
fn ind_no_scroll_region_top_of_screen() {
    // IND No Scroll Region Top of Screen
    check(
        10,
        2,
        &["\x1b[1;1H", "\x1b[2J", "A", "\x1bD", "X"],
        &["A         ", " X        "],
        (1, 2),
    );
}

#[test]
fn ind_bottom_of_primary_screen() {
    // IND Bottom of Primary Screen
    check(
        10,
        2,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[2;1H", "A", "\x1bD", "X"],
        &["A         ", " X        "],
        (1, 2),
    );
}

#[test]
fn ind_inside_scroll_region() {
    // IND Inside Scroll Region
    check(
        10,
        2,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[1;3r", "A", "\x1bD", "X"],
        &["A         ", " X        "],
        (1, 2),
    );
}

#[test]
fn ind_bottom_of_scroll_region() {
    // IND Bottom of Scroll Region
    check(
        10,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[1;3r",
            "\x1b[4;1H",
            "B",
            "\x1b[3;1H",
            "A",
            "\x1bD",
            "X",
        ],
        &["          ", "A         ", " X        ", "B         "],
        (2, 2),
    );
}

#[test]
fn ind_bottom_of_primary_screen_with_scroll_region() {
    // IND Bottom of Primary Screen with Scroll Region
    check(
        10,
        5,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[1;3r",
            "\x1b[3;1H",
            "A",
            "\x1b[5;1H",
            "\x1bD",
            "X",
        ],
        &[
            "          ",
            "          ",
            "A         ",
            "          ",
            "X         ",
        ],
        (4, 1),
    );
}

#[test]
fn ind_outside_of_left_right_scroll_region() {
    // IND Outside of Left/Right Scroll Region
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[1;3r",
            "\x1b[3;5s",
            "\x1b[3;3H",
            "A",
            "\x1b[3;1H",
            "\x1bD",
            "X",
        ],
        &["          ", "          ", "X A       "],
        (2, 1),
    );
}

#[test]
fn ind_inside_of_left_right_scroll_region() {
    // IND Inside of Left/Right Scroll Region
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "AAAAAA\x0d\x0a",
            "AAAAAA\x0d\x0a",
            "AAAAAA",
            "\x1b[?69h",
            "\x1b[1;3s",
            "\x1b[1;3r",
            "\x1b[3;1H",
            "\x1bD",
        ],
        &["AAAAAA    ", "AAAAAA    ", "   AAA    "],
        (2, 0),
    );
}

#[test]
fn ed_simple_erase_below() {
    // ED Simple Erase Below
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;2H",
            "\x1b[0J",
        ],
        &["ABC     ", "D       ", "        "],
        (1, 1),
    );
}

#[test]
fn ed_erase_below_with_sgr_state() {
    // ED Erase Below with SGR State
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[0J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;2H",
            "\x1b[41m",
            "\x1b[0J",
        ],
        &["ABC     ", "D       ", "        "],
        (1, 1),
    );
}

#[test]
fn ed_erase_below_with_multi_cell_character() {
    // ED Erase Below with Multi-Cell Character
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "AB橋C\x0d\x0a",
            "DE橋F\x0d\x0a",
            "GH橋I",
            "\x1b[2;3H",
            "\x1b[0J",
        ],
        &["AB橋C   ", "DE      ", "        "],
        (1, 2),
    );
}

#[test]
fn ed_simple_erase_above() {
    // ED Simple Erase Above
    // The table blanks the whole cursor line. Erase above ends at the
    // cursor, inclusive (ECMA-48, xterm), so the rest of the line stays.
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;2H",
            "\x1b[1J",
        ],
        &["        ", "  F     ", "GHI     "],
        (1, 1),
    );
}

#[test]
fn ed_simple_erase_complete() {
    // ED Simple Erase Complete
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;2H",
            "\x1b[2J",
        ],
        &["        ", "        ", "        "],
        (1, 1),
    );
}
