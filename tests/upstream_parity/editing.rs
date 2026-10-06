/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: eraseLine simple erase right"
#[test]
fn erase_line_right_clears_from_cursor_to_end_of_line() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;3H"); // row 1, col 3 (1-based) -> (0,2)
    term.feed(b"\x1b[K"); // EL with default param 0 = erase to the right
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'A');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, 'B');
    assert_eq!(term.active_grid().get(0, 2).unwrap().char, '\0');
    assert_eq!(term.active_grid().get(0, 4).unwrap().char, '\0');
}

/// Upstream test: "Terminal: print charset" -- DEC Special Graphics maps backtick to a diamond,
/// ASCII/other charsets pass it through unchanged.
#[test]
fn print_charset_backtick_mapping_matches_upstream() {
    let mut term = Terminal::new(10, 2);
    term.feed(b"\x1b(0`"); // G0 = DEC Special Graphics, print '`'
    term.feed(b"\x1b(B`"); // G0 = ASCII, print '`'
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\u{25C6}');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, '`');
}

/// Upstream test: "Terminal: print invoke charset" -- SO/SI shift between G0/G1 without
/// redesignating either, and can be toggled back and forth repeatedly.
#[test]
fn shift_out_in_toggles_between_g0_and_g1_repeatedly() {
    let mut term = Terminal::new(10, 2);
    term.feed(b"\x1b)0"); // G1 = DEC Special Graphics (G0 stays ASCII)
    term.feed(b"`"); // G0 active -> literal backtick
    term.feed(b"\x0e"); // SO: shift to G1
    term.feed(b"``"); // G1 active -> two diamonds
    term.feed(b"\x0f"); // SI: shift back to G0
    term.feed(b"`"); // literal backtick again
    let row: String = (0..4)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row, "`\u{25C6}\u{25C6}`");
}

/// Upstream test: "Terminal: linefeed and carriage return"
#[test]
fn linefeed_and_carriage_return() {
    let mut term = Terminal::new(80, 80);
    term.feed(b"hello\r\nworld");
    assert_eq!(term.cursor(), (1, 5));
    let row0: String = (0..5)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    let row1: String = (0..5)
        .map(|c| term.active_grid().get(1, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row0, "hello");
    assert_eq!(row1, "world");
}

/// Upstream test: "Terminal: reverseIndex" -- RI at a row inside the scroll region
/// (but not at its top) just moves the cursor up one row, no scrolling.
#[test]
fn reverse_index_moves_up_without_scrolling_mid_region() {
    let mut term = Terminal::new(2, 5);
    term.feed(b"A\r\nB\r\nC");
    term.feed(b"\x1bMD"); // ESC M (RI) then print 'D'
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'B');
    assert_eq!(term.active_grid().get(1, 1).unwrap().char, 'D');
    assert_eq!(term.active_grid().get(2, 0).unwrap().char, 'C');
}

/// Upstream test: "Terminal: reverseIndex from the top" -- RI at row 0 scrolls the
/// screen down, inserting a blank row at the top rather than moving above it.
#[test]
fn reverse_index_at_screen_top_scrolls_down() {
    let mut term = Terminal::new(2, 5);
    term.feed(b"A\r\nB\r\n\r\n"); // "A" row0, "B" row1, cursor now on row3
    term.feed(b"\x1b[1;1H"); // cursor to (0,0)
    term.feed(b"\x1bMD"); // RI at the top scrolls everything down by one row, then print 'D'
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'D');
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'A');
    assert_eq!(term.active_grid().get(2, 0).unwrap().char, 'B');
}

/// Upstream test: "Terminal: eraseDisplay simple erase below"
#[test]
fn erase_display_below_clears_cursor_row_from_cursor_and_all_rows_after() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H"); // row 2, col 2 (1-based) -> (1,1), inside the "DEF" row
    term.feed(b"\x1b[J"); // ED with default param 0 = erase below (cursor row from cursor, plus everything after)
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'A');
    assert_eq!(term.active_grid().get(0, 2).unwrap().char, 'C');
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'D'); // before the cursor column: untouched
    assert_eq!(term.active_grid().get(1, 1).unwrap().char, '\0'); // at/after the cursor column: cleared
    assert_eq!(term.active_grid().get(1, 2).unwrap().char, '\0');
    assert_eq!(term.active_grid().get(2, 0).unwrap().char, '\0'); // the whole row below: cleared
}

/// Upstream test: "Terminal: insertLines simple"
#[test]
fn insert_lines_shifts_cursor_row_and_below_down_within_the_region() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H"); // (1,1), on the "DEF" row
    term.feed(b"\x1b[1L"); // IL: insert 1 blank line at the cursor's row
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'A'); // untouched, above the insertion
    let row1: String = (0..3)
        .map(|c| term.active_grid().get(1, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row1, "   "); // the new blank line lands exactly at the cursor's row
    let row2: String = (0..3)
        .map(|c| term.active_grid().get(2, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row2, "DEF"); // pushed down by one
    let row3: String = (0..3)
        .map(|c| term.active_grid().get(3, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row3, "GHI");
}

/// Upstream test: "Terminal: deleteLines simple"
#[test]
fn delete_lines_removes_cursor_row_and_shifts_below_up() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC\r\nDEF\r\nGHI");
    term.feed(b"\x1b[2;2H"); // (1,1), on the "DEF" row
    term.feed(b"\x1b[1M"); // DL: delete 1 line at the cursor's row
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'A'); // untouched
    let row1: String = (0..3)
        .map(|c| term.active_grid().get(1, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row1, "GHI"); // shifted up into the deleted row's place
    let row2: String = (0..3)
        .map(|c| term.active_grid().get(2, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row2, "   "); // a blank line appears at the bottom of the region
}

/// Upstream test: "Terminal: deleteChars simple operation"
#[test]
fn delete_chars_removes_at_cursor_and_shifts_line_left() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123");
    term.feed(b"\x1b[1;3H"); // row 1, col 3 (1-based) -> (0,2), on the first '3'... actually on 'C'
    term.feed(b"\x1b[2P"); // DCH: delete 2 characters at the cursor ('C','1'), shifting "23" left
    let row: String = (0..6)
        .map(|c| term.active_grid().get(0, c).unwrap().char)
        .map(|ch| if ch == '\0' { ' ' } else { ch })
        .collect();
    assert_eq!(row, "AB23  ");
}
