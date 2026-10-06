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
fn dl_simple_delete_line() {
    // DL Simple Delete Line
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
            "\x1b[M",
        ],
        &["ABC     ", "GHI     ", "        "],
        (1, 0),
    );
}

#[test]
fn dl_cursor_outside_scroll_region() {
    // DL Cursor Outside Scroll Region
    // The table accepts a one-line scrolling region (bottom clamped to the
    // screen). xterm refuses a region of fewer than two lines whole, so the
    // command changes nothing and the delete reaches the whole screen,
    // leaving the cursor in the first column as line edits do.
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[3;4r",
            "\x1b[2;2H",
            "\x1b[M",
        ],
        &["ABC     ", "GHI     ", "        "],
        (1, 0),
    );
}

#[test]
fn dl_with_top_bottom_scroll_regions() {
    // DL With Top/Bottom Scroll Regions
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI\x0d\x0a",
            "123",
            "\x1b[1;3r",
            "\x1b[2;2H",
            "\x1b[M",
        ],
        &["ABC     ", "GHI     ", "        ", "123     "],
        (1, 0),
    );
}

#[test]
fn dl_with_left_right_scroll_regions() {
    // DL With Left/Right Scroll Regions
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC123\x0d\x0a",
            "DEF456\x0d\x0a",
            "GHI789",
            "\x1b[?69h",
            "\x1b[2;4s",
            "\x1b[2;2H",
            "\x1b[M",
        ],
        &["ABC123  ", "DHI756  ", "G   89  "],
        (1, 1),
    );
}

#[test]
fn il_simple_insert_line() {
    // IL Simple Insert Line
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;2H",
            "\x1b[L",
        ],
        &["ABC     ", "        ", "DEF     ", "GHI     "],
        (1, 0),
    );
}

#[test]
fn il_cursor_outside_scroll_region() {
    // IL Cursor Outside Scroll Region
    // The table accepts a one-line scrolling region (bottom clamped to the
    // screen). xterm refuses a region of fewer than two lines whole, so the
    // command changes nothing and the insert reaches the whole screen,
    // leaving the cursor in the first column as line edits do.
    check(
        8,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[3;4r",
            "\x1b[2;2H",
            "\x1b[L",
        ],
        &["ABC     ", "        ", "DEF     "],
        (1, 0),
    );
}

#[test]
fn il_with_top_bottom_scroll_regions() {
    // IL With Top/Bottom Scroll Regions
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI\x0d\x0a",
            "123",
            "\x1b[1;3r",
            "\x1b[2;2H",
            "\x1b[L",
        ],
        &["ABC     ", "        ", "DEF     ", "123     "],
        (1, 0),
    );
}

#[test]
fn il_with_left_right_scroll_regions() {
    // IL With Left/Right Scroll Regions
    check(
        8,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC123\x0d\x0a",
            "DEF456\x0d\x0a",
            "GHI789",
            "\x1b[?69h",
            "\x1b[2;4s",
            "\x1b[2;2H",
            "\x1b[L",
        ],
        &["ABC123  ", "D   56  ", "GEF489  ", " HI7    "],
        (1, 1),
    );
}

#[test]
fn dch_simple_delete_character() {
    // DCH Simple Delete Character
    check(
        8,
        1,
        &["ABC123", "\x1b[3G", "\x1b[2P"],
        &["AB23    "],
        (0, 2),
    );
}

#[test]
fn dch_with_sgr_state() {
    // DCH with SGR State
    check(
        8,
        1,
        &["ABC123", "\x1b[3G", "\x1b[41m", "\x1b[2P"],
        &["AB23    "],
        (0, 2),
    );
}

#[test]
fn dch_outside_left_right_scroll_region() {
    // DCH Outside Left/Right Scroll Region
    check(
        8,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC123",
            "\x1b[?69h",
            "\x1b[3;5s",
            "\x1b[2G",
            "\x1b[P",
        ],
        &["ABC123  "],
        (0, 1),
    );
}

#[test]
fn dch_inside_left_right_scroll_region() {
    // DCH Inside Left/Right Scroll Region
    check(
        8,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC123",
            "\x1b[?69h",
            "\x1b[3;5s",
            "\x1b[4G",
            "\x1b[P",
        ],
        &["ABC2 3  "],
        (0, 3),
    );
}

#[test]
fn dch_split_wide_character() {
    // DCH Split Wide Character
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "A橋123", "\x1b[3G", "\x1b[P"],
        &["A 123     "],
        (0, 2),
    );
}
