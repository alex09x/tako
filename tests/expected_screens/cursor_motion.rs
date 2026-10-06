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
fn cud_cursor_down() {
    // CUD Cursor Down
    check(
        10,
        3,
        &["A", "\x1b[2B", "X"],
        &["A         ", "          ", " X        "],
        (2, 2),
    );
}

#[test]
fn cud_cursor_down_above_bottom_margin() {
    // CUD Cursor Down Above Bottom Margin
    check(
        10,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x0a\x0a\x0a\x0a",
            "\x1b[1;3r",
            "A",
            "\x1b[5B",
            "X",
        ],
        &["A         ", "          ", " X        ", "          "],
        (2, 2),
    );
}

#[test]
fn cud_cursor_down_below_bottom_margin() {
    // CUD Cursor Down Below Bottom Margin
    check(
        10,
        5,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x0a\x0a\x0a\x0a\x0a",
            "\x1b[1;3r",
            "A",
            "\x1b[4;1H",
            "\x1b[5B",
            "X",
        ],
        &[
            "A         ",
            "          ",
            "          ",
            "          ",
            "X         ",
        ],
        (4, 1),
    );
}

#[test]
fn cup_normal_usage() {
    // CUP Normal Usage
    check(
        10,
        2,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[2;3H", "A"],
        &["          ", "  A       "],
        (1, 3),
    );
}

#[test]
fn cup_off_the_screen() {
    // CUP Off the Screen
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[500;500H", "A"],
        &["          ", "          ", "         A"],
        (2, 9),
    );
}

#[test]
fn cup_relative_to_origin() {
    // CUP Relative to Origin
    // The table accepts a one-line scrolling region (bottom clamped to the
    // screen). xterm refuses a region of fewer than two lines whole, so the
    // command changes nothing.
    check(
        10,
        2,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[2;3r",
            "\x1b[?6h",
            "\x1b[1;1H",
            "X",
        ],
        &["X         ", "          "],
        (0, 1),
    );
}

#[test]
fn cup_relative_to_origin_with_margins() {
    // CUP Relative to Origin with Margins
    // The table accepts a one-line scrolling region (bottom clamped to the
    // screen). xterm refuses a region of fewer than two lines whole, so the
    // command changes nothing.
    check(
        10,
        2,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[3;5s",
            "\x1b[2;3r",
            "\x1b[?6h",
            "\x1b[1;1H",
            "X",
        ],
        &["  X       ", "          "],
        (0, 3),
    );
}

#[test]
fn cup_limits_with_scroll_region_and_origin_mode() {
    // CUP Limits with Scroll Region and Origin Mode
    // The table puts the cursor one past the right margin. As in xterm, it
    // stays on the margin with a wrap pending.
    check(
        10,
        3,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[3;5s",
            "\x1b[2;3r",
            "\x1b[?6h",
            "\x1b[500;500H",
            "X",
        ],
        &["          ", "          ", "    X     "],
        (2, 4),
    );
}

#[test]
fn cup_pending_wrap_is_unset() {
    // CUP Pending Wrap is Unset
    check(
        10,
        1,
        &["\x1b[10G", "A", "\x1b[1;1H", "X"],
        &["X        A"],
        (0, 1),
    );
}

#[test]
fn cuf_pending_wrap_is_unset() {
    // CUF Pending Wrap is Unset
    check(
        10,
        2,
        &["\x1b[10G", "A", "\x1b[C", "XYZ"],
        &["         X", "YZ        "],
        (1, 2),
    );
}

#[test]
fn cuf_rightmost_boundary() {
    // CUF Rightmost Boundary
    check(10, 1, &["A", "\x1b[500C", "B"], &["A        B"], (0, 9));
}

#[test]
fn cuf_left_of_right_margin() {
    // CUF Left of Right Margin
    // The table puts the cursor one past the right margin. As in xterm, it
    // stays on the margin with a wrap pending.
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[3;5s",
            "\x1b[1G",
            "\x1b[500C",
            "X",
        ],
        &["    X     "],
        (0, 4),
    );
}

#[test]
fn cuf_right_of_right_margin() {
    // CUF Right of Right Margin
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[3;5s",
            "\x1b[6G",
            "\x1b[500C",
            "X",
        ],
        &["         X"],
        (0, 9),
    );
}

#[test]
fn cuu_normal_usage() {
    // CUU Normal Usage
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[3;1H", "A", "\x1b[2A", "X"],
        &[" X        ", "          ", "A         "],
        (0, 2),
    );
}

#[test]
fn cuu_below_top_margin() {
    // CUU Below Top Margin
    check(
        10,
        4,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[2;4r",
            "\x1b[3;1H",
            "A",
            "\x1b[5A",
            "X",
        ],
        &["          ", " X        ", "A         ", "          "],
        (1, 2),
    );
}

#[test]
fn cuu_above_top_margin() {
    // CUU Above Top Margin
    check(
        10,
        5,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[3;5r",
            "\x1b[3;1H",
            "A",
            "\x1b[2;1H",
            "\x1b[5A",
            "X",
        ],
        &[
            "X         ",
            "          ",
            "A         ",
            "          ",
            "          ",
        ],
        (0, 1),
    );
}
