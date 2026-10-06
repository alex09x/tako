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
fn cbt_left_beyond_first_column() {
    // CBT Left Beyond First Column
    check(
        10,
        1,
        &["\x1b[?W", "\x1b[10Z", "A"],
        &["A         "],
        (0, 1),
    );
}

#[test]
fn cbt_left_starting_after_tab_stop() {
    // CBT Left Starting After Tab Stop
    check(
        11,
        1,
        &["\x1b[?W", "\x1b[1;10H", "X", "\x1b[Z", "A"],
        &["        AX "],
        (0, 9),
    );
}

#[test]
fn cbt_left_starting_on_tabstop() {
    // CBT Left Starting on Tabstop
    check(
        10,
        1,
        &["\x1b[?W", "\x1b[1;9H", "X", "\x1b[1;9H", "\x1b[Z", "A"],
        &["A       X "],
        (0, 1),
    );
}

#[test]
fn cbt_left_margin_with_origin_mode() {
    // CBT Left Margin with Origin Mode
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?W",
            "\x1b[?6h",
            "\x1b[?69h",
            "\x1b[3;6s",
            "\x1b[1;2H",
            "X",
            "\x1b[Z",
            "A",
        ],
        &["  AX      "],
        (0, 3),
    );
}

#[test]
fn cht_right_beyond_last_column() {
    // CHT Right Beyond Last Column
    check(
        10,
        1,
        &["\x1b[?W", "\x1b[100I", "A"],
        &["         A"],
        (0, 9),
    );
}

#[test]
fn cht_right_from_before_tabstop() {
    // CHT Right From Before Tabstop
    check(
        10,
        1,
        &["\x1b[?W", "\x1b[1;2H", "A", "\x1b[I", "X"],
        &[" A      X "],
        (0, 9),
    );
}

#[test]
fn cht_right_margin() {
    // CHT Right Margin
    // The table puts the cursor one past the right margin. As in xterm, it
    // stays on the margin with a wrap pending.
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?W",
            "\x1b[?69h",
            "\x1b[3;6s",
            "\x1b[1;1H",
            "X",
            "\x1b[I",
            "A",
        ],
        &["X    A    "],
        (0, 5),
    );
}

#[test]
fn cr_pending_wrap_is_unset() {
    // CR Pending Wrap is Unset
    check(
        10,
        2,
        &["\x1b[10G", "A", "\x0d", "X"],
        &["X        A", "          "],
        (0, 1),
    );
}

#[test]
fn cr_left_margin() {
    // CR Left Margin
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[2;5s",
            "\x1b[4G",
            "A",
            "\x0d",
            "X",
        ],
        &[" X A      "],
        (0, 2),
    );
}

#[test]
fn cr_left_of_left_margin() {
    // CR Left of Left Margin
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?69h",
            "\x1b[2;5s",
            "\x1b[4G",
            "A",
            "\x1b[1G",
            "\x0d",
            "X",
        ],
        &["X  A      "],
        (0, 1),
    );
}

#[test]
fn cr_left_margin_with_origin_mode() {
    // CR Left Margin with Origin Mode
    check(
        10,
        1,
        &[
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[?6h",
            "\x1b[?69h",
            "\x1b[2;5s",
            "\x1b[4G",
            "A",
            "\x1b[1G",
            "\x0d",
            "X",
        ],
        &[" X A      "],
        (0, 2),
    );
}

#[test]
fn cub_pending_wrap_is_unset() {
    // CUB Pending Wrap is Unset
    check(
        10,
        2,
        &["\x1b[10G", "A", "\x1b[D", "XYZ"],
        &["        XY", "Z         "],
        (1, 1),
    );
}

#[test]
fn cub_leftmost_boundary_with_reverse_wrap_disabled() {
    // CUB Leftmost Boundary with Reverse Wrap Disabled
    check(
        10,
        2,
        &["\x1b[?45l", "A\x0a", "\x1b[10D", "B"],
        &["A         ", "B         "],
        (1, 1),
    );
}

#[test]
fn cub_reverse_wrap() {
    // CUB Reverse Wrap
    check(
        10,
        2,
        &[
            "\x1b[?7h",
            "\x1b[?45h",
            "\x1b[1;1H",
            "\x1b[2J",
            "\x1b[10G",
            "AB",
            "\x1b[D",
            "X",
        ],
        &["         A", "X         "],
        (1, 1),
    );
}
