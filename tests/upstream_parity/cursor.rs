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
