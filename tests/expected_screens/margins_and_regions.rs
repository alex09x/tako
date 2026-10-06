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
fn decstbm_full_screen_scroll_up() {
    // DECSTBM Full Screen Scroll Up
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[r",
            "\x1b[T",
        ],
        &["        ", "ABC     ", "DEF     ", "GHI     "],
        (0, 0),
    );
}

#[test]
fn decstbm_top_only_scroll_up() {
    // DECSTBM Top Only Scroll Up
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2r",
            "\x1b[T",
        ],
        &["ABC     ", "        ", "DEF     ", "GHI     "],
        (0, 0),
    );
}

#[test]
fn decstbm_top_and_bottom_scroll_up() {
    // DECSTBM Top and Bottom Scroll Up
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[1;2r",
            "\x1b[T",
        ],
        &["        ", "ABC     ", "GHI     ", "        "],
        (0, 0),
    );
}

#[test]
fn decstbm_top_equal_bottom_scroll_up() {
    // DECSTBM Top Equal Bottom Scroll Up
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;2r",
            "\x1b[T",
        ],
        &["        ", "ABC     ", "DEF     ", "GHI     "],
        (2, 3),
    );
}

#[test]
fn decslrm_full_screen() {
    // DECSLRM Full Screen
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[?69h",
            "\x1b[s",
            "\x1b[X",
        ],
        &[" BC     ", "DEF     ", "GHI     "],
        (0, 0),
    );
}

#[test]
fn decslrm_left_only() {
    // DECSLRM Left Only
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[?69h",
            "\x1b[2s",
            "\x1b[2G",
            "\x1b[L",
        ],
        &["A       ", "DBC     ", "GEF     ", " HI     "],
        (0, 1),
    );
}

#[test]
fn decslrm_left_and_right() {
    // DECSLRM Left And Right
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[?69h",
            "\x1b[1;2s",
            "\x1b[2G",
            "\x1b[L",
        ],
        &["  C     ", "ABF     ", "DEI     ", "GH      "],
        (0, 0),
    );
}

#[test]
fn decslrm_left_equal_to_right() {
    // DECSLRM Left Equal to Right
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[?69h",
            "\x1b[2;2s",
            "\x1b[X",
        ],
        &["ABC     ", "DEF     ", "GHI     "],
        (2, 3),
    );
}
