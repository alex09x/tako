// Cursor movement, editing and scrolling against a table of expected
// screens. Each case feeds its input to a fresh terminal of the given size,
// then compares every row, padded to the width, and the cursor. The table
// is adapted from an MIT-licensed terminal emulator's test suite (see
// NOTICE.md); each test keeps the case's name in a comment.

use tako_core::terminal::Terminal;

/// Feeds `input` to a `cols` x `rows` terminal and checks the screen and the
/// cursor, as (row, column).
#[track_caller]
fn check(cols: usize, rows: usize, input: &[&str], want: &[&str], cursor: (usize, usize)) {
    let mut term = Terminal::new(cols, rows);
    for part in input {
        term.feed(part.as_bytes());
    }
    let screen: Vec<String> = (0..rows)
        .map(|r| {
            term.viewport_row(r)
                .iter()
                .filter(|c| !c.is_wide_spacer)
                .map(|c| if c.char == '\0' { ' ' } else { c.char })
                .collect()
        })
        .collect();
    let want: Vec<String> = want.iter().map(|s| s.to_string()).collect();
    assert_eq!(screen, want, "screen");
    assert_eq!(term.cursor(), cursor, "cursor (row, column)");
}

#[test]
fn cbt_left_beyond_first_column() {
    // CBT Left Beyond First Column
    check(
        10,
        1,
        &["\x1b[?W", "\x1b[10Z", "A"],
        &[
            "A         ",
        ],
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
        &[
            "        AX ",
        ],
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
        &[
            "A       X ",
        ],
        (0, 1),
    );
}

#[test]
fn cbt_left_margin_with_origin_mode() {
    // CBT Left Margin with Origin Mode
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?W", "\x1b[?6h", "\x1b[?69h", "\x1b[3;6s", "\x1b[1;2H", "X", "\x1b[Z", "A"],
        &[
            "  AX      ",
        ],
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
        &[
            "         A",
        ],
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
        &[
            " A      X ",
        ],
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
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?W", "\x1b[?69h", "\x1b[3;6s", "\x1b[1;1H", "X", "\x1b[I", "A"],
        &[
            "X    A    ",
        ],
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
        &[
            "X        A",
            "          ",
        ],
        (0, 1),
    );
}

#[test]
fn cr_left_margin() {
    // CR Left Margin
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[2;5s", "\x1b[4G", "A", "\x0d", "X"],
        &[
            " X A      ",
        ],
        (0, 2),
    );
}

#[test]
fn cr_left_of_left_margin() {
    // CR Left of Left Margin
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[2;5s", "\x1b[4G", "A", "\x1b[1G", "\x0d", "X"],
        &[
            "X  A      ",
        ],
        (0, 1),
    );
}

#[test]
fn cr_left_margin_with_origin_mode() {
    // CR Left Margin with Origin Mode
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?6h", "\x1b[?69h", "\x1b[2;5s", "\x1b[4G", "A", "\x1b[1G", "\x0d", "X"],
        &[
            " X A      ",
        ],
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
        &[
            "        XY",
            "Z         ",
        ],
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
        &[
            "A         ",
            "B         ",
        ],
        (1, 1),
    );
}

#[test]
fn cub_reverse_wrap() {
    // CUB Reverse Wrap
    check(
        10,
        2,
        &["\x1b[?7h", "\x1b[?45h", "\x1b[1;1H", "\x1b[2J", "\x1b[10G", "AB", "\x1b[D", "X"],
        &[
            "         A",
            "X         ",
        ],
        (1, 1),
    );
}

#[test]
fn cud_cursor_down() {
    // CUD Cursor Down
    check(
        10,
        3,
        &["A", "\x1b[2B", "X"],
        &[
            "A         ",
            "          ",
            " X        ",
        ],
        (2, 2),
    );
}

#[test]
fn cud_cursor_down_above_bottom_margin() {
    // CUD Cursor Down Above Bottom Margin
    check(
        10,
        4,
        &["\x1b[1;1H", "\x1b[2J", "\x0a\x0a\x0a\x0a", "\x1b[1;3r", "A", "\x1b[5B", "X"],
        &[
            "A         ",
            "          ",
            " X        ",
            "          ",
        ],
        (2, 2),
    );
}

#[test]
fn cud_cursor_down_below_bottom_margin() {
    // CUD Cursor Down Below Bottom Margin
    check(
        10,
        5,
        &["\x1b[1;1H", "\x1b[2J", "\x0a\x0a\x0a\x0a\x0a", "\x1b[1;3r", "A", "\x1b[4;1H", "\x1b[5B", "X"],
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
        &[
            "          ",
            "  A       ",
        ],
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
        &[
            "          ",
            "          ",
            "         A",
        ],
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
        &["\x1b[1;1H", "\x1b[2J", "\x1b[2;3r", "\x1b[?6h", "\x1b[1;1H", "X"],
        &[
            "X         ",
            "          ",
        ],
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
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[3;5s", "\x1b[2;3r", "\x1b[?6h", "\x1b[1;1H", "X"],
        &[
            "  X       ",
            "          ",
        ],
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
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[3;5s", "\x1b[2;3r", "\x1b[?6h", "\x1b[500;500H", "X"],
        &[
            "          ",
            "          ",
            "    X     ",
        ],
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
        &[
            "X        A",
        ],
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
        &[
            "         X",
            "YZ        ",
        ],
        (1, 2),
    );
}

#[test]
fn cuf_rightmost_boundary() {
    // CUF Rightmost Boundary
    check(
        10,
        1,
        &["A", "\x1b[500C", "B"],
        &[
            "A        B",
        ],
        (0, 9),
    );
}

#[test]
fn cuf_left_of_right_margin() {
    // CUF Left of Right Margin
    // The table puts the cursor one past the right margin. As in xterm, it
    // stays on the margin with a wrap pending.
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[3;5s", "\x1b[1G", "\x1b[500C", "X"],
        &[
            "    X     ",
        ],
        (0, 4),
    );
}

#[test]
fn cuf_right_of_right_margin() {
    // CUF Right of Right Margin
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[3;5s", "\x1b[6G", "\x1b[500C", "X"],
        &[
            "         X",
        ],
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
        &[
            " X        ",
            "          ",
            "A         ",
        ],
        (0, 2),
    );
}

#[test]
fn cuu_below_top_margin() {
    // CUU Below Top Margin
    check(
        10,
        4,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[2;4r", "\x1b[3;1H", "A", "\x1b[5A", "X"],
        &[
            "          ",
            " X        ",
            "A         ",
            "          ",
        ],
        (1, 2),
    );
}

#[test]
fn cuu_above_top_margin() {
    // CUU Above Top Margin
    check(
        10,
        5,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[3;5r", "\x1b[3;1H", "A", "\x1b[2;1H", "\x1b[5A", "X"],
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

#[test]
fn dl_simple_delete_line() {
    // DL Simple Delete Line
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2H", "\x1b[M"],
        &[
            "ABC     ",
            "GHI     ",
            "        ",
        ],
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
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[3;4r", "\x1b[2;2H", "\x1b[M"],
        &[
            "ABC     ",
            "GHI     ",
            "        ",
        ],
        (1, 0),
    );
}

#[test]
fn dl_with_top_bottom_scroll_regions() {
    // DL With Top/Bottom Scroll Regions
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI\x0d\x0a", "123", "\x1b[1;3r", "\x1b[2;2H", "\x1b[M"],
        &[
            "ABC     ",
            "GHI     ",
            "        ",
            "123     ",
        ],
        (1, 0),
    );
}

#[test]
fn dl_with_left_right_scroll_regions() {
    // DL With Left/Right Scroll Regions
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC123\x0d\x0a", "DEF456\x0d\x0a", "GHI789", "\x1b[?69h", "\x1b[2;4s", "\x1b[2;2H", "\x1b[M"],
        &[
            "ABC123  ",
            "DHI756  ",
            "G   89  ",
        ],
        (1, 1),
    );
}

#[test]
fn il_simple_insert_line() {
    // IL Simple Insert Line
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2H", "\x1b[L"],
        &[
            "ABC     ",
            "        ",
            "DEF     ",
            "GHI     ",
        ],
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
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[3;4r", "\x1b[2;2H", "\x1b[L"],
        &[
            "ABC     ",
            "        ",
            "DEF     ",
        ],
        (1, 0),
    );
}

#[test]
fn il_with_top_bottom_scroll_regions() {
    // IL With Top/Bottom Scroll Regions
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI\x0d\x0a", "123", "\x1b[1;3r", "\x1b[2;2H", "\x1b[L"],
        &[
            "ABC     ",
            "        ",
            "DEF     ",
            "123     ",
        ],
        (1, 0),
    );
}

#[test]
fn il_with_left_right_scroll_regions() {
    // IL With Left/Right Scroll Regions
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC123\x0d\x0a", "DEF456\x0d\x0a", "GHI789", "\x1b[?69h", "\x1b[2;4s", "\x1b[2;2H", "\x1b[L"],
        &[
            "ABC123  ",
            "D   56  ",
            "GEF489  ",
            " HI7    ",
        ],
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
        &[
            "AB23    ",
        ],
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
        &[
            "AB23    ",
        ],
        (0, 2),
    );
}

#[test]
fn dch_outside_left_right_scroll_region() {
    // DCH Outside Left/Right Scroll Region
    check(
        8,
        1,
        &["\x1b[1;1H", "\x1b[2J", "ABC123", "\x1b[?69h", "\x1b[3;5s", "\x1b[2G", "\x1b[P"],
        &[
            "ABC123  ",
        ],
        (0, 1),
    );
}

#[test]
fn dch_inside_left_right_scroll_region() {
    // DCH Inside Left/Right Scroll Region
    check(
        8,
        1,
        &["\x1b[1;1H", "\x1b[2J", "ABC123", "\x1b[?69h", "\x1b[3;5s", "\x1b[4G", "\x1b[P"],
        &[
            "ABC2 3  ",
        ],
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
        &[
            "A 123     ",
        ],
        (0, 2),
    );
}

#[test]
fn decstbm_full_screen_scroll_up() {
    // DECSTBM Full Screen Scroll Up
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[r", "\x1b[T"],
        &[
            "        ",
            "ABC     ",
            "DEF     ",
            "GHI     ",
        ],
        (0, 0),
    );
}

#[test]
fn decstbm_top_only_scroll_up() {
    // DECSTBM Top Only Scroll Up
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2r", "\x1b[T"],
        &[
            "ABC     ",
            "        ",
            "DEF     ",
            "GHI     ",
        ],
        (0, 0),
    );
}

#[test]
fn decstbm_top_and_bottom_scroll_up() {
    // DECSTBM Top and Bottom Scroll Up
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[1;2r", "\x1b[T"],
        &[
            "        ",
            "ABC     ",
            "GHI     ",
            "        ",
        ],
        (0, 0),
    );
}

#[test]
fn decstbm_top_equal_bottom_scroll_up() {
    // DECSTBM Top Equal Bottom Scroll Up
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2r", "\x1b[T"],
        &[
            "        ",
            "ABC     ",
            "DEF     ",
            "GHI     ",
        ],
        (2, 3),
    );
}

#[test]
fn decslrm_full_screen() {
    // DECSLRM Full Screen
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[?69h", "\x1b[s", "\x1b[X"],
        &[
            " BC     ",
            "DEF     ",
            "GHI     ",
        ],
        (0, 0),
    );
}

#[test]
fn decslrm_left_only() {
    // DECSLRM Left Only
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[?69h", "\x1b[2s", "\x1b[2G", "\x1b[L"],
        &[
            "A       ",
            "DBC     ",
            "GEF     ",
            " HI     ",
        ],
        (0, 1),
    );
}

#[test]
fn decslrm_left_and_right() {
    // DECSLRM Left And Right
    check(
        8,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[?69h", "\x1b[1;2s", "\x1b[2G", "\x1b[L"],
        &[
            "  C     ",
            "ABF     ",
            "DEI     ",
            "GH      ",
        ],
        (0, 0),
    );
}

#[test]
fn decslrm_left_equal_to_right() {
    // DECSLRM Left Equal to Right
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[?69h", "\x1b[2;2s", "\x1b[X"],
        &[
            "ABC     ",
            "DEF     ",
            "GHI     ",
        ],
        (2, 3),
    );
}

#[test]
fn ech_simple_operation() {
    // ECH Simple Operation
    check(
        8,
        1,
        &["ABC", "\x1b[1G", "\x1b[2X"],
        &[
            "  C     ",
        ],
        (0, 0),
    );
}

#[test]
fn ech_erasing_beyond_edge_of_screen() {
    // ECH Erasing Beyond Edge of Screen
    check(
        8,
        1,
        &["\x1b[8G", "\x1b[2D", "ABC", "\x1b[D", "\x1b[10X"],
        &[
            "     A  ",
        ],
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
        &[
            "       X",
        ],
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
        &[
            "  C     ",
        ],
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
        &[
            "X BC    ",
        ],
        (0, 1),
    );
}

#[test]
fn ech_left_right_scroll_region_ignored() {
    // ECH Left/Right Scroll Region Ignored
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[1;3s", "\x1b[4G", "ABC", "\x1b[1G", "\x1b[4X"],
        &[
            "    BC    ",
        ],
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
        &[
            "AB      ",
        ],
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
        &[
            "       X",
        ],
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
        &[
            "A       ",
        ],
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
        &[
            "AB      ",
        ],
        (0, 3),
    );
}

#[test]
fn el_erase_right_with_left_right_margins() {
    // EL Erase Right with Left/Right Margins
    check(
        10,
        1,
        &["\x1b[1;1H", "\x1b[2J", "ABCDE", "\x1b[?69h", "\x1b[1;3s", "\x1b[2G", "\x1b[0K"],
        &[
            "A         ",
        ],
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
        &[
            "   DE   ",
        ],
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
        &[
            "  C     ",
        ],
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
        &[
            "    DE  ",
        ],
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
        &[
            "        ",
        ],
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
        &[
            "        ",
        ],
        (0, 1),
    );
}

#[test]
fn ind_no_scroll_region_top_of_screen() {
    // IND No Scroll Region Top of Screen
    check(
        10,
        2,
        &["\x1b[1;1H", "\x1b[2J", "A", "\x1bD", "X"],
        &[
            "A         ",
            " X        ",
        ],
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
        &[
            "A         ",
            " X        ",
        ],
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
        &[
            "A         ",
            " X        ",
        ],
        (1, 2),
    );
}

#[test]
fn ind_bottom_of_scroll_region() {
    // IND Bottom of Scroll Region
    check(
        10,
        4,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[1;3r", "\x1b[4;1H", "B", "\x1b[3;1H", "A", "\x1bD", "X"],
        &[
            "          ",
            "A         ",
            " X        ",
            "B         ",
        ],
        (2, 2),
    );
}

#[test]
fn ind_bottom_of_primary_screen_with_scroll_region() {
    // IND Bottom of Primary Screen with Scroll Region
    check(
        10,
        5,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[1;3r", "\x1b[3;1H", "A", "\x1b[5;1H", "\x1bD", "X"],
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
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?69h", "\x1b[1;3r", "\x1b[3;5s", "\x1b[3;3H", "A", "\x1b[3;1H", "\x1bD", "X"],
        &[
            "          ",
            "          ",
            "X A       ",
        ],
        (2, 1),
    );
}

#[test]
fn ind_inside_of_left_right_scroll_region() {
    // IND Inside of Left/Right Scroll Region
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "AAAAAA\x0d\x0a", "AAAAAA\x0d\x0a", "AAAAAA", "\x1b[?69h", "\x1b[1;3s", "\x1b[1;3r", "\x1b[3;1H", "\x1bD"],
        &[
            "AAAAAA    ",
            "AAAAAA    ",
            "   AAA    ",
        ],
        (2, 0),
    );
}

#[test]
fn ed_simple_erase_below() {
    // ED Simple Erase Below
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2H", "\x1b[0J"],
        &[
            "ABC     ",
            "D       ",
            "        ",
        ],
        (1, 1),
    );
}

#[test]
fn ed_erase_below_with_sgr_state() {
    // ED Erase Below with SGR State
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[0J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2H", "\x1b[41m", "\x1b[0J"],
        &[
            "ABC     ",
            "D       ",
            "        ",
        ],
        (1, 1),
    );
}

#[test]
fn ed_erase_below_with_multi_cell_character() {
    // ED Erase Below with Multi-Cell Character
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[2J", "AB橋C\x0d\x0a", "DE橋F\x0d\x0a", "GH橋I", "\x1b[2;3H", "\x1b[0J"],
        &[
            "AB橋C   ",
            "DE      ",
            "        ",
        ],
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
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2H", "\x1b[1J"],
        &[
            "        ",
            "  F     ",
            "GHI     ",
        ],
        (1, 1),
    );
}

#[test]
fn ed_simple_erase_complete() {
    // ED Simple Erase Complete
    check(
        8,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2H", "\x1b[2J"],
        &[
            "        ",
            "        ",
            "        ",
        ],
        (1, 1),
    );
}

#[test]
fn ri_no_scroll_region_top_of_screen() {
    // RI No Scroll Region Top of Screen
    check(
        10,
        4,
        &["\x1b[1;1H", "\x1b[2J", "A\x0d\x0a", "B\x0d\x0a", "C\x0d\x0a", "\x1b[1;1H", "\x1bM", "X"],
        &[
            "X         ",
            "A         ",
            "B         ",
            "C         ",
        ],
        (0, 1),
    );
}

#[test]
fn ri_no_scroll_region_not_top_of_screen() {
    // RI No Scroll Region Not Top of Screen
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "A\x0d\x0a", "B\x0d\x0a", "C", "\x1b[2;1H", "\x1bM", "X"],
        &[
            "X         ",
            "B         ",
            "C         ",
        ],
        (0, 1),
    );
}

#[test]
fn ri_top_bottom_scroll_region() {
    // RI Top/Bottom Scroll Region
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "A\x0d\x0a", "B\x0d\x0a", "C", "\x1b[2;3r", "\x1b[2;1H", "\x1bM", "X"],
        &[
            "A         ",
            "X         ",
            "B         ",
        ],
        (1, 1),
    );
}

#[test]
fn ri_outside_of_top_bottom_scroll_region() {
    // RI Outside of Top/Bottom Scroll Region
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "A\x0d\x0a", "B\x0d\x0a", "C", "\x1b[2;3r", "\x1b[1;1H", "\x1bM"],
        &[
            "A         ",
            "B         ",
            "C         ",
        ],
        (0, 0),
    );
}

#[test]
fn ri_left_right_scroll_region() {
    // RI Left/Right Scroll Region
    check(
        10,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[?69h", "\x1b[2;3s", "\x1b[1;2H", "\x1bM"],
        &[
            "A         ",
            "DBC       ",
            "GEF       ",
            " HI       ",
        ],
        (0, 1),
    );
}

#[test]
fn ri_outside_left_right_scroll_region() {
    // RI Outside Left/Right Scroll Region
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[?69h", "\x1b[2;3s", "\x1b[2;1H", "\x1bM"],
        &[
            "ABC       ",
            "DEF       ",
            "GHI       ",
        ],
        (0, 0),
    );
}

#[test]
fn sd_outside_of_top_bottom_scroll_region() {
    // SD Outside of Top/Bottom Scroll Region
    check(
        10,
        4,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[3;4r", "\x1b[2;2H", "\x1b[T"],
        &[
            "ABC       ",
            "DEF       ",
            "          ",
            "GHI       ",
        ],
        (1, 1),
    );
}

#[test]
fn su_simple_usage() {
    // SU Simple Usage
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;2H", "\x1b[S"],
        &[
            "DEF       ",
            "GHI       ",
            "          ",
        ],
        (1, 1),
    );
}

#[test]
fn su_top_bottom_scroll_region() {
    // SU Top/Bottom Scroll Region
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC\x0d\x0a", "DEF\x0d\x0a", "GHI", "\x1b[2;3r", "\x1b[1;1H", "\x1b[S"],
        &[
            "ABC       ",
            "GHI       ",
            "          ",
        ],
        (0, 0),
    );
}

#[test]
fn su_left_right_scroll_regions() {
    // SU Left/Right Scroll Regions
    check(
        10,
        3,
        &["\x1b[1;1H", "\x1b[2J", "ABC123\x0d\x0a", "DEF456\x0d\x0a", "GHI789", "\x1b[?69h", "\x1b[2;4s", "\x1b[2;2H", "\x1b[S"],
        &[
            "AEF423    ",
            "DHI756    ",
            "G   89    ",
        ],
        (1, 1),
    );
}

#[test]
fn su_preserves_pending_wrap() {
    // SU Preserves Pending Wrap
    check(
        10,
        4,
        &["\x1b[1;10H", "\x1b[2J", "A", "\x1b[2;10H", "B", "\x1b[3;10H", "C", "\x1b[S", "X"],
        &[
            "         B",
            "         C",
            "          ",
            "X         ",
        ],
        (3, 1),
    );
}

#[test]
fn su_scroll_full_top_bottom_scroll_region() {
    // SU Scroll Full Top/Bottom Scroll Region
    check(
        10,
        5,
        &["\x1b[1;1H", "\x1b[2J", "top", "\x1b[5;1H", "ABCDEF", "\x1b[2;5r", "\x1b[4S"],
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
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?W", "\x09", "\x1b[g", "\x1b[1G", "\x09"],
        &[
            "                       ",
        ],
        (0, 16),
    );
}

#[test]
fn tbc_clear_all_tab_stops() {
    // TBC Clear All Tab Stops
    check(
        23,
        1,
        &["\x1b[1;1H", "\x1b[2J", "\x1b[?W", "\x1b[3g", "\x1b[1G", "\x09"],
        &[
            "                       ",
        ],
        (0, 22),
    );
}
