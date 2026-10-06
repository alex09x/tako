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
fn ri_no_scroll_region_top_of_screen() {
    // RI No Scroll Region Top of Screen
    check(
        10,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "A\x0d\x0a",
            "B\x0d\x0a",
            "C\x0d\x0a",
            "\x1b[1;1H",
            "\x1bM",
            "X",
        ],
        &["X         ", "A         ", "B         ", "C         "],
        (0, 1),
    );
}

#[test]
fn ri_no_scroll_region_not_top_of_screen() {
    // RI No Scroll Region Not Top of Screen
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "A\x0d\x0a",
            "B\x0d\x0a",
            "C",
            "\x1b[2;1H",
            "\x1bM",
            "X",
        ],
        &["X         ", "B         ", "C         "],
        (0, 1),
    );
}

#[test]
fn ri_top_bottom_scroll_region() {
    // RI Top/Bottom Scroll Region
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "A\x0d\x0a",
            "B\x0d\x0a",
            "C",
            "\x1b[2;3r",
            "\x1b[2;1H",
            "\x1bM",
            "X",
        ],
        &["A         ", "X         ", "B         "],
        (1, 1),
    );
}

#[test]
fn ri_outside_of_top_bottom_scroll_region() {
    // RI Outside of Top/Bottom Scroll Region
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "A\x0d\x0a",
            "B\x0d\x0a",
            "C",
            "\x1b[2;3r",
            "\x1b[1;1H",
            "\x1bM",
        ],
        &["A         ", "B         ", "C         "],
        (0, 0),
    );
}

#[test]
fn ri_left_right_scroll_region() {
    // RI Left/Right Scroll Region
    check(
        10,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[?69h",
            "\x1b[2;3s",
            "\x1b[1;2H",
            "\x1bM",
        ],
        &["A         ", "DBC       ", "GEF       ", " HI       "],
        (0, 1),
    );
}

#[test]
fn ri_outside_left_right_scroll_region() {
    // RI Outside Left/Right Scroll Region
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[?69h",
            "\x1b[2;3s",
            "\x1b[2;1H",
            "\x1bM",
        ],
        &["ABC       ", "DEF       ", "GHI       "],
        (0, 0),
    );
}

#[test]
fn sd_outside_of_top_bottom_scroll_region() {
    // SD Outside of Top/Bottom Scroll Region
    check(
        10,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[3;4r",
            "\x1b[2;2H",
            "\x1b[T",
        ],
        &["ABC       ", "DEF       ", "          ", "GHI       "],
        (1, 1),
    );
}

#[test]
fn su_simple_usage() {
    // SU Simple Usage
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;2H",
            "\x1b[S",
        ],
        &["DEF       ", "GHI       ", "          "],
        (1, 1),
    );
}

#[test]
fn su_top_bottom_scroll_region() {
    // SU Top/Bottom Scroll Region
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "ABC\x0d\x0a",
            "DEF\x0d\x0a",
            "GHI",
            "\x1b[2;3r",
            "\x1b[1;1H",
            "\x1b[S",
        ],
        &["ABC       ", "GHI       ", "          "],
        (0, 0),
    );
}

#[test]
fn su_left_right_scroll_regions() {
    // SU Left/Right Scroll Regions
    check(
        10,
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
            "\x1b[S",
        ],
        &["AEF423    ", "DHI756    ", "G   89    "],
        (1, 1),
    );
}

#[test]
fn su_preserves_pending_wrap() {
    // SU Preserves Pending Wrap
    check(
        10,
        4,
        &[
            "\x1b[1;10H",
            "\x1b[2J",
            "A",
            "\x1b[2;10H",
            "B",
            "\x1b[3;10H",
            "C",
            "\x1b[S",
            "X",
        ],
        &["         B", "         C", "          ", "X         "],
        (3, 1),
    );
}

#[test]
fn su_scroll_full_top_bottom_scroll_region() {
    // SU Scroll Full Top/Bottom Scroll Region
    check(
        10,
        5,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "top",
            "\x1b[5;1H",
            "ABCDEF",
            "\x1b[2;5r",
            "\x1b[4S",
        ],
        &[
            "top       ",
            "          ",
            "          ",
            "          ",
            "          ",
        ],
        (0, 0),
    );
}

#[test]
fn tbc_clear_single_tab_stop() {
    // TBC Clear Single Tab Stop
    check(
        23,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?W",
            "\x09",
            "\x1b[g",
            "\x1b[1G",
            "\x09",
        ],
        &["                       "],
        (0, 16),
    );
}

#[test]
fn tbc_clear_all_tab_stops() {
    // TBC Clear All Tab Stops
    check(
        23,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?W",
            "\x1b[3g",
            "\x1b[1G",
            "\x09",
        ],
        &["                       "],
        (0, 22),
    );
}
