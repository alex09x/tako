//! A curated set of test cases translated 1:1 (input bytes + expected
//! observable state) from the upstream terminal core's test suite
//! into this crate's own `Terminal` API. Scoped to behavior this port actually
//! implements (no left/right margins, pending-wrap state machine, grapheme
//! clustering, or refcounted styles -- those are upstream features this
//! port deliberately does not have).
//!
//! Each test names the exact upstream test it was translated from so a
//! divergence can be traced back to the source of truth.

use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: cursorUp basic"
#[test]
fn cursor_up_basic() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;1HA"); // row 3, col 1 (1-based) -> (2,0); print 'A' -> cursor (2,1)
    term.feed(b"\x1b[10A"); // CUU clamps to screen top (no scroll region set)
    term.feed(b"X"); // column is untouched by CUU, so X lands at (0,1)
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, 'X');
    assert_eq!(term.active_grid().get(2, 0).unwrap().char, 'A');
    assert_eq!(term.cursor(), (0, 2));
}

/// Upstream test: "Terminal: cursorUp below top scroll margin"
#[test]
fn cursor_up_clamps_to_scroll_region_top_when_cursor_starts_inside_it() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[2;4r"); // DECSTBM rows 2..4 (1-based) -> 0-based rows 1..3
    term.feed(b"\x1b[3;1HA"); // row 3 -> (2,0), inside the region; print 'A' -> cursor (2,1)
    term.feed(b"\x1b[5A"); // CUU(5) clamps to the region's top row (1), not the screen top (0)
    term.feed(b"X");
    assert_eq!(term.active_grid().get(1, 1).unwrap().char, 'X');
    assert_eq!(term.cursor(), (1, 2));
}

/// Upstream test: "Terminal: cursorUp above top scroll margin"
#[test]
fn cursor_up_ignores_scroll_region_when_cursor_starts_above_it() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;5r"); // region rows 3..5 (1-based) -> 0-based rows 2..4
    term.feed(b"\x1b[3;1HA"); // (2,0), inside region
    term.feed(b"\x1b[2;1H"); // move to (1,0), ABOVE the region
    term.feed(b"\x1b[10A"); // cursor started outside the region -> clamps to the screen top, not the margin
    term.feed(b"X");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'X');
}

/// Upstream test: "Terminal: cursorDown basic"
#[test]
fn cursor_down_basic() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"A"); // (0,0) -> cursor (0,1)
    term.feed(b"\x1b[10B"); // CUD clamps to screen bottom (row 4)
    term.feed(b"X");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'A');
    assert_eq!(term.active_grid().get(4, 1).unwrap().char, 'X');
}

/// Upstream test: "Terminal: cursorDown above bottom scroll margin"
#[test]
fn cursor_down_clamps_to_scroll_region_bottom_when_cursor_starts_inside_it() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;3r"); // region rows 1..3 (1-based) -> 0-based rows 0..2
    term.feed(b"A"); // (0,0), inside region
    term.feed(b"\x1b[10B"); // clamps to region bottom (row 2), not screen bottom
    term.feed(b"X");
    assert_eq!(term.active_grid().get(2, 1).unwrap().char, 'X');
}

/// Upstream test: "Terminal: cursorDown below bottom scroll margin"
#[test]
fn cursor_down_ignores_scroll_region_when_cursor_starts_below_it() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;3r"); // region rows 0..2 (0-based)
    term.feed(b"A");
    term.feed(b"\x1b[4;1H"); // move to row 3 (0-based), BELOW the region
    term.feed(b"\x1b[10B"); // outside the region -> clamps to screen bottom (row 4)
    term.feed(b"X");
    assert_eq!(term.active_grid().get(4, 0).unwrap().char, 'X');
}

/// Upstream test: "Terminal: setCursorPos (original test)" -- clamping + origin-mode subset
/// (translated at a smaller grid; upstream uses 80x80).
#[test]
fn cup_clamps_to_grid_and_zero_param_means_row_col_one() {
    let mut term = Terminal::new(10, 10);
    assert_eq!(term.cursor(), (0, 0));
    term.feed(b"\x1b[0;0H"); // explicit 0 means "1" (same as omitted) per xterm convention
    assert_eq!(term.cursor(), (0, 0));
    term.feed(b"\x1b[81;81H"); // clamps to the grid's last row/col
    assert_eq!(term.cursor(), (9, 9));
}

/// Upstream test: "Terminal: cursorPos relative to origin"
#[test]
fn cup_is_relative_to_scroll_region_top_in_origin_mode() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[3;4r"); // region rows 3..4 (1-based) -> 0-based rows 2..3
    term.feed(b"\x1b[?6h"); // DECOM: origin mode on
    term.feed(b"\x1b[1;1H"); // (1,1) relative to the region's top-left -> absolute (2,0)
    term.feed(b"X");
    assert_eq!(term.active_grid().get(2, 0).unwrap().char, 'X');
}

/// Upstream test: "Terminal: saveCursor" -- attrs + charset + origin mode all round-trip.
#[test]
fn save_restore_cursor_round_trips_attrs_charset_and_origin_mode() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1m"); // bold
    term.feed(b"\x1b)0"); // G1 = DEC Special Graphics
    term.feed(b"\x0e"); // SO: shift out to G1
    term.feed(b"\x1b[?6h"); // origin mode on
    term.feed(b"\x1b7"); // DECSC: save cursor (ESC 7 form)
    term.feed(b"\x1b)B"); // change G1 back to ASCII
    term.feed(b"\x0f"); // SI: shift back to G0
    term.feed(b"\x1b[?6l"); // origin mode off
    term.feed(b"\x1b[0m"); // reset attrs
    term.feed(b"\x1b8"); // DECRC: restore cursor
    // The restored state must still be bold, G1-shifted DEC Special Graphics, and origin mode on.
    term.feed(b"q"); // 'q' under DEC Special Graphics -> horizontal line
    let cell = term.active_grid().get(0, 0).unwrap();
    assert_eq!(cell.char, '\u{2500}');
    assert!(cell.attrs.contains(tako_core::grid::CellAttrs::BOLD));
    assert!(term.modes().origin_mode);
}

/// Upstream test: "Terminal: saveCursor position"
#[test]
fn save_restore_cursor_round_trips_position() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b[1;5HA"); // row 1, col 5 (1-based) -> (0,4); print 'A' -> cursor (0,5)
    term.feed(b"\x1b[s"); // CSI s: save cursor
    term.feed(b"\x1b[1;1HB"); // move away and print 'B'
    term.feed(b"\x1b[u"); // CSI u: restore cursor
    term.feed(b"X");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'B');
    assert_eq!(term.active_grid().get(0, 4).unwrap().char, 'A');
    assert_eq!(term.active_grid().get(0, 5).unwrap().char, 'X');
}

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
    let row: String = (0..4).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row, "`\u{25C6}\u{25C6}`");
}

/// Upstream test: "Terminal: linefeed and carriage return"
#[test]
fn linefeed_and_carriage_return() {
    let mut term = Terminal::new(80, 80);
    term.feed(b"hello\r\nworld");
    assert_eq!(term.cursor(), (1, 5));
    let row0: String = (0..5).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    let row1: String = (0..5).map(|c| term.active_grid().get(1, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
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
    let row1: String = (0..3).map(|c| term.active_grid().get(1, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row1, "   "); // the new blank line lands exactly at the cursor's row
    let row2: String = (0..3).map(|c| term.active_grid().get(2, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row2, "DEF"); // pushed down by one
    let row3: String = (0..3).map(|c| term.active_grid().get(3, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
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
    let row1: String = (0..3).map(|c| term.active_grid().get(1, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row1, "GHI"); // shifted up into the deleted row's place
    let row2: String = (0..3).map(|c| term.active_grid().get(2, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row2, "   "); // a blank line appears at the bottom of the region
}

/// Upstream test: "Terminal: deleteChars simple operation"
#[test]
fn delete_chars_removes_at_cursor_and_shifts_line_left() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC123");
    term.feed(b"\x1b[1;3H"); // row 1, col 3 (1-based) -> (0,2), on the first '3'... actually on 'C'
    term.feed(b"\x1b[2P"); // DCH: delete 2 characters at the cursor ('C','1'), shifting "23" left
    let row: String = (0..6).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row, "AB23  ");
}

/// Upstream test: "Terminal: setCursorPos (original test)" -- the pending-wrap
/// portion: printing in the last column parks the cursor there; the wrap is
/// deferred to the next printable.
#[test]
fn printing_last_column_sets_pending_wrap_instead_of_wrapping_immediately() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert_eq!(term.cursor(), (0, 4)); // parked, NOT already on row 1
    assert!(!term.active_grid().is_line_wrapped(0)); // no wrap recorded yet
    term.feed(b"F");
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'F');
    // The continuation marker belongs to the destination row. This keeps
    // logical-line extraction and scrollback reflow aligned on one meaning:
    // `wrapped(row)` says that `row` continues the row immediately above it.
    assert!(!term.active_grid().is_line_wrapped(0));
    assert!(term.active_grid().is_line_wrapped(1));
}

/// Upstream test: "Terminal: carriage return unsets pending wrap"
#[test]
fn carriage_return_unsets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\rX");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, 'X');
    assert_eq!(term.cursor(), (0, 1)); // still on row 0: the wrap never fired
}

/// Upstream test: "Terminal: linefeed unsets pending wrap"
#[test]
fn linefeed_unsets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\nX");
    // LF moved to row 1 keeping the column; X prints there, no double-advance.
    assert_eq!(term.active_grid().get(1, 4).unwrap().char, 'X');
    assert_eq!(term.cursor(), (1, 4)); // parked again after printing in the last column
}

/// Upstream test: "Terminal: cursorUp resets wrap"
#[test]
fn cursor_up_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[AX");
    let row: String = (0..5).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row, "ABCDX");
}

/// Upstream test: "Terminal: cursorDown resets wrap"
#[test]
fn cursor_down_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[BX");
    assert_eq!(term.active_grid().get(1, 4).unwrap().char, 'X');
    let row0: String = (0..5).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row0, "ABCDE");
}

/// Upstream test: "Terminal: cursorRight resets wrap"
#[test]
fn cursor_right_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[CX");
    let row: String = (0..5).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row, "ABCDX");
}

/// Upstream test: "Terminal: eraseLine resets pending wrap"
#[test]
fn erase_line_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE\x1b[KX");
    let row: String = (0..5).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row, "ABCDX");
}

/// Upstream test: "Terminal: saveCursor pending wrap state"
#[test]
fn save_restore_cursor_round_trips_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"\x1b[1;5HA"); // print in the last column -> pending wrap set
    term.feed(b"\x1b7"); // DECSC saves it
    term.feed(b"\x1b[1;1H"); // movement clears it
    term.feed(b"\x1b8"); // DECRC restores it
    term.feed(b"B"); // so this print wraps to row 1
    assert_eq!(term.active_grid().get(0, 4).unwrap().char, 'A');
    assert_eq!(term.active_grid().get(1, 0).unwrap().char, 'B');
}

/// Upstream test: "Terminal: eraseChars simple operation"
#[test]
fn erase_chars_simple_operation() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC\x1b[1;1H\x1b[2X");
    let row: String = (0..3).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row, "  C");
}

/// Upstream test: "Terminal: eraseChars minimum one"
#[test]
fn erase_chars_minimum_one() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"ABC\x1b[1;1H\x1b[X");
    let row: String = (0..3).map(|c| term.active_grid().get(0, c).unwrap().char).map(|ch| if ch == '\0' { ' ' } else { ch }).collect();
    assert_eq!(row, " BC");
}
