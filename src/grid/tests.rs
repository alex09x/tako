use crate::grid::*;

#[test]
fn test_new_grid_is_blank_and_correctly_sized() {
    let g = Grid::new(10, 5);
    assert_eq!(g.cols(), 10);
    assert_eq!(g.rows(), 5);
    assert_eq!(g.scrollback_len(), 0);
    for row in 0..5 {
        for col in 0..10 {
            let cell = g.get(row, col).unwrap();
            assert_eq!(cell, &Cell::default());
            assert_eq!(cell.char, '\0');
            assert_eq!(cell.fg, Color::Default);
            assert_eq!(cell.bg, Color::Default);
            assert!(cell.attrs.is_empty());
        }
    }
}

#[test]
fn test_out_of_bounds_get_returns_none() {
    let g = Grid::new(4, 4);
    assert!(g.get(4, 0).is_none());
    assert!(g.get(0, 4).is_none());
    assert!(g.get(100, 100).is_none());
}

#[test]
fn test_set_and_get() {
    let mut g = Grid::new(4, 4);
    let cell = Cell {
        char: 'x',
        fg: Color::Indexed(1),
        bg: Color::Rgb(10, 20, 30),
        attrs: CellAttrs::BOLD | CellAttrs::UNDERLINE,
        hyperlink: None,
        ..Cell::default()
    };
    g.set(2, 3, cell);
    let got = g.get(2, 3).unwrap();
    assert_eq!(got.char, 'x');
    assert_eq!(got.fg, Color::Indexed(1));
    assert_eq!(got.bg, Color::Rgb(10, 20, 30));
    assert!(got.attrs.contains(CellAttrs::BOLD));
    assert!(got.attrs.contains(CellAttrs::UNDERLINE));
    assert!(!got.attrs.contains(CellAttrs::ITALIC));

    // Neighboring cells untouched.
    assert_eq!(g.get(2, 2).unwrap(), &Cell::default());

    // set() out of bounds should not panic.
    g.set(999, 999, cell);
}

#[test]
fn test_get_mut_modifies_cell() {
    let mut g = Grid::new(3, 3);
    if let Some(cell) = g.get_mut(1, 1) {
        cell.char = 'z';
    }
    assert_eq!(g.get(1, 1).unwrap().char, 'z');
}

#[test]
fn test_scroll_up_pushes_scrollback_and_shifts_rows() {
    let mut g = Grid::new(3, 3);
    // Row 0: 'a', Row 1: 'b', Row 2: 'c'
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        for col in 0..3 {
            g.set(row, col, Cell { char: ch, ..Cell::default() });
        }
    }

    g.scroll_up(1);

    assert_eq!(g.scrollback_len(), 1);
    // The scrolled-off row ('a') should be readable from scrollback,
    // nearest the bottom (index 0 from bottom).
    let line = g.scrollback_line(0).unwrap();
    assert_eq!(line[0].char, 'a');

    // Remaining rows shifted up: row 0 now has 'b', row 1 has 'c'.
    assert_eq!(g.get(0, 0).unwrap().char, 'b');
    assert_eq!(g.get(1, 0).unwrap().char, 'c');
    // New blank row at bottom.
    assert_eq!(g.get(2, 0).unwrap(), &Cell::default());
}

#[test]
fn test_scroll_up_multiple_lines_and_capacity() {
    let mut g = Grid::with_scrollback_capacity(2, 2, 3);
    // Push more lines than capacity to verify oldest get dropped.
    for i in 0..5u8 {
        for col in 0..2 {
            g.set(0, col, Cell { char: (b'0' + i) as char, ..Cell::default() });
        }
        g.scroll_up(1);
    }
    assert_eq!(g.scrollback_len(), 3);
    // Oldest retained should be '2' (since '0' and '1' were evicted).
    // scrollback_line(2) is the oldest (furthest from bottom).
    let oldest = g.scrollback_line(2).unwrap();
    assert_eq!(oldest[0].char, '2');
    let newest = g.scrollback_line(0).unwrap();
    assert_eq!(newest[0].char, '4');
}

#[test]
fn test_scroll_up_zero_is_noop() {
    let mut g = Grid::new(3, 3);
    g.set(0, 0, Cell { char: 'a', ..Cell::default() });
    g.scroll_up(0);
    assert_eq!(g.scrollback_len(), 0);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
}

#[test]
fn test_clear_line_from_col() {
    let mut g = Grid::new(5, 1);
    for col in 0..5 {
        g.set(0, col, Cell { char: 'x', ..Cell::default() });
    }
    g.clear_line(0, 2);
    assert_eq!(g.get(0, 0).unwrap().char, 'x');
    assert_eq!(g.get(0, 1).unwrap().char, 'x');
    assert_eq!(g.get(0, 2).unwrap().char, '\0');
    assert_eq!(g.get(0, 3).unwrap().char, '\0');
    assert_eq!(g.get(0, 4).unwrap().char, '\0');
}

#[test]
fn test_clear_line_to_col() {
    let mut g = Grid::new(5, 1);
    for col in 0..5 {
        g.set(0, col, Cell { char: 'x', ..Cell::default() });
    }
    g.clear_line_to(0, 2);
    assert_eq!(g.get(0, 0).unwrap().char, '\0');
    assert_eq!(g.get(0, 1).unwrap().char, '\0');
    assert_eq!(g.get(0, 2).unwrap().char, '\0');
    assert_eq!(g.get(0, 3).unwrap().char, 'x');
    assert_eq!(g.get(0, 4).unwrap().char, 'x');
}

#[test]
fn test_clear_line_full() {
    let mut g = Grid::new(5, 1);
    for col in 0..5 {
        g.set(0, col, Cell { char: 'x', ..Cell::default() });
    }
    g.set_line_wrapped(0, true);
    g.clear_line_full(0);
    for col in 0..5 {
        assert_eq!(g.get(0, col).unwrap(), &Cell::default());
    }
    assert!(!g.is_line_wrapped(0));
}

#[test]
fn test_clear_all() {
    let mut g = Grid::new(3, 3);
    for row in 0..3 {
        for col in 0..3 {
            g.set(row, col, Cell { char: 'x', ..Cell::default() });
        }
    }
    g.clear_all();
    for row in 0..3 {
        for col in 0..3 {
            assert_eq!(g.get(row, col).unwrap(), &Cell::default());
        }
    }
}

#[test]
fn test_resize_grow_rows() {
    let mut g = Grid::new(3, 2);
    g.set(0, 0, Cell { char: 'a', ..Cell::default() });
    g.set(1, 0, Cell { char: 'b', ..Cell::default() });
    g.resize(3, 4);
    assert_eq!(g.rows(), 4);
    assert_eq!(g.cols(), 3);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(1, 0).unwrap().char, 'b');
    assert_eq!(g.get(2, 0).unwrap(), &Cell::default());
    assert_eq!(g.get(3, 0).unwrap(), &Cell::default());
    assert_eq!(g.scrollback_len(), 0);
}

#[test]
fn test_resize_shrink_rows_pushes_scrollback() {
    let mut g = Grid::new(3, 4);
    for row in 0..4 {
        g.set(row, 0, Cell { char: (b'a' + row as u8) as char, ..Cell::default() });
    }
    g.resize(3, 2);
    assert_eq!(g.rows(), 2);
    // Top two rows ('a','b') should have been pushed to scrollback.
    assert_eq!(g.scrollback_len(), 2);
    // Remaining visible rows should be 'c' and 'd'.
    assert_eq!(g.get(0, 0).unwrap().char, 'c');
    assert_eq!(g.get(1, 0).unwrap().char, 'd');
    // Scrollback nearest bottom should be 'b' (most recently pushed off).
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'b');
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'a');
}

#[test]
fn test_resize_shrink_trims_blank_bottom_before_scrollback() {
    let mut g = Grid::new(3, 5);
    g.set(0, 0, Cell { char: 'a', ..Cell::default() });
    g.set(1, 0, Cell { char: 'b', ..Cell::default() });

    g.resize(3, 3);

    assert_eq!(g.rows(), 3);
    assert_eq!(g.scrollback_len(), 0);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(1, 0).unwrap().char, 'b');
    assert_eq!(g.get(2, 0).unwrap(), &Cell::default());
}

#[test]
fn test_resize_shrink_does_not_trim_the_cursor_row() {
    let mut g = Grid::new(3, 5);
    g.set(0, 0, Cell { char: 'a', ..Cell::default() });

    g.resize_with_cursor(3, 2, Some((3, 0)));

    // Row 4 is disposable padding, but the blank cursor row 3 is meaningful.
    // Two additional rows therefore leave through the top so the cursor stays
    // visible at the bottom of the smaller grid.
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(g.get(1, 0).unwrap(), &Cell::default());
}

#[test]
fn test_resize_grow_pulls_adjacent_history_when_cursor_was_at_bottom() {
    let mut g = Grid::new(3, 4);
    for (row, ch) in ['a', 'b', 'c', 'd'].into_iter().enumerate() {
        g.set(row, 0, Cell { char: ch, ..Cell::default() });
    }

    g.resize_with_cursor(3, 2, Some((3, 0)));
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(row_chars(&g, 0), "c\0\0");
    assert_eq!(row_chars(&g, 1), "d\0\0");

    let cursor_pos = g.resize_with_cursor(3, 4, Some((1, 0)));
    assert_eq!(cursor_pos, Some((3, 0)));
    assert_eq!(g.scrollback_len(), 0);
    assert_eq!(row_chars(&g, 0), "a\0\0");
    assert_eq!(row_chars(&g, 1), "b\0\0");
    assert_eq!(row_chars(&g, 2), "c\0\0");
    assert_eq!(row_chars(&g, 3), "d\0\0");
}

#[test]
fn test_resize_grow_keeps_history_when_cursor_was_above_bottom() {
    let mut g = Grid::new(3, 4);
    for (row, ch) in ['a', 'b', 'c', 'd'].into_iter().enumerate() {
        g.set(row, 0, Cell { char: ch, ..Cell::default() });
    }
    g.resize_with_cursor(3, 2, Some((3, 0)));

    let cursor_pos = g.resize_with_cursor(3, 4, Some((0, 0)));
    assert_eq!(cursor_pos, Some((0, 0)));
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(row_chars(&g, 0), "c\0\0");
    assert_eq!(row_chars(&g, 1), "d\0\0");
    assert_eq!(row_chars(&g, 2), "\0\0\0");
    assert_eq!(row_chars(&g, 3), "\0\0\0");
}

#[test]
fn test_resize_grow_keeps_history_when_grid_has_no_active_cursor() {
    let mut g = Grid::new(3, 4);
    for (row, ch) in ['a', 'b', 'c', 'd'].into_iter().enumerate() {
        g.set(row, 0, Cell { char: ch, ..Cell::default() });
    }
    g.resize_with_cursor(3, 2, Some((3, 0)));

    // Terminal::resize passes None for the inactive primary/alternate grid.
    // Without evidence that its own cursor was at the bottom, growing that
    // grid must append blanks rather than silently changing its viewport.
    let cursor_pos = g.resize_with_cursor(3, 4, None);
    assert_eq!(cursor_pos, None);
    assert_eq!(g.scrollback_len(), 2);
    assert_eq!(row_chars(&g, 0), "c\0\0");
    assert_eq!(row_chars(&g, 1), "d\0\0");
    assert_eq!(row_chars(&g, 2), "\0\0\0");
    assert_eq!(row_chars(&g, 3), "\0\0\0");
}

#[test]
fn test_resize_grow_cols_preserves_content() {
    let mut g = Grid::new(3, 2);
    g.set(0, 0, Cell { char: 'a', ..Cell::default() });
    g.set(0, 1, Cell { char: 'b', ..Cell::default() });
    g.set(0, 2, Cell { char: 'c', ..Cell::default() });
    g.resize(6, 2);
    assert_eq!(g.cols(), 6);
    assert_eq!(g.rows(), 2);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(0, 1).unwrap().char, 'b');
    assert_eq!(g.get(0, 2).unwrap().char, 'c');
    assert_eq!(g.get(0, 3).unwrap(), &Cell::default());
}

#[test]
fn test_resize_shrink_cols_rewraps_line() {
    let mut g = Grid::new(6, 2);
    // Single hard line "abcdef" on row 0 (row 1 stays blank/hard).
    for (i, ch) in "abcdef".chars().enumerate() {
        g.set(0, i, Cell { char: ch, ..Cell::default() });
    }
    g.resize(3, 4);
    assert_eq!(g.cols(), 3);
    assert_eq!(g.rows(), 4);
    // "abcdef" should now be wrapped across two rows of width 3: "abc","def"
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(0, 1).unwrap().char, 'b');
    assert_eq!(g.get(0, 2).unwrap().char, 'c');
    assert_eq!(g.get(1, 0).unwrap().char, 'd');
    assert_eq!(g.get(1, 1).unwrap().char, 'e');
    assert_eq!(g.get(1, 2).unwrap().char, 'f');
    assert!(g.is_line_wrapped(1));
    assert!(!g.is_line_wrapped(0));
}

#[test]
fn test_resize_does_not_panic_on_various_sizes() {
    let mut g = Grid::new(10, 10);
    g.resize(1, 1);
    assert_eq!(g.cols(), 1);
    assert_eq!(g.rows(), 1);
    g.resize(80, 24);
    assert_eq!(g.cols(), 80);
    assert_eq!(g.rows(), 24);
    // Resizing to 0 should clamp to 1 rather than panic/produce empty grid.
    g.resize(0, 0);
    assert_eq!(g.cols(), 1);
    assert_eq!(g.rows(), 1);
}

#[test]
fn test_scrollback_iter_oldest_first() {
    let mut g = Grid::new(2, 1);
    for i in 0..3u8 {
        g.set(0, 0, Cell { char: (b'a' + i) as char, ..Cell::default() });
        g.scroll_up(1);
    }
    let chars: Vec<char> = g.scrollback_iter().map(|line| line[0].char).collect();
    assert_eq!(chars, vec!['a', 'b', 'c']);
}

fn wide(ch: char) -> Cell {
    Cell {
        char: ch,
        fg: Color::Indexed(3),
        bg: Color::Rgb(1, 2, 3),
        attrs: CellAttrs::BOLD,
        hyperlink: Some(7),
        ..Cell::default()
    }
}

/// Assert no row of `line` has a spacer without a wide cell in front of
/// it, and no non-default cell is a wide half whose spacer went missing.
fn assert_no_orphans(line: &[Cell]) {
    for (i, cell) in line.iter().enumerate() {
        if cell.is_wide_spacer {
            assert!(i > 0, "spacer at column 0 has no wide half");
            assert!(
                !line[i - 1].is_wide_spacer,
                "spacer at column {i} follows another spacer"
            );
        }
    }
}

#[test]
fn test_set_wide_writes_pair_and_returns_true() {
    let mut g = Grid::new(4, 2);
    let cell = wide('あ');
    assert!(g.set_wide(1, 1, cell));

    let head = *g.get(1, 1).unwrap();
    assert_eq!(head, cell);
    assert!(!head.is_wide_spacer);

    let spacer = *g.get(1, 2).unwrap();
    assert_eq!(spacer.char, ' ');
    assert!(spacer.is_wide_spacer);
    assert_eq!(spacer.fg, cell.fg);
    assert_eq!(spacer.bg, cell.bg);
    assert_eq!(spacer.attrs, cell.attrs);
    assert_eq!(spacer.hyperlink, cell.hyperlink);

    // Neighbors untouched.
    assert_eq!(g.get(1, 0).unwrap(), &Cell::default());
    assert_eq!(g.get(1, 3).unwrap(), &Cell::default());
}

#[test]
fn test_set_wide_at_last_column_returns_false_and_writes_nothing() {
    let mut g = Grid::new(4, 1);
    assert!(!g.set_wide(0, 3, wide('あ')));
    for col in 0..4 {
        assert_eq!(g.get(0, col).unwrap(), &Cell::default());
    }
    // Out-of-range rows are rejected too.
    assert!(!g.set_wide(9, 0, wide('あ')));
}

#[test]
fn test_clear_line_full_clears_whole_pair() {
    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    g.clear_line_full(0);
    for col in 0..4 {
        assert_eq!(g.get(0, col).unwrap(), &Cell::default());
    }
}

#[test]
fn test_clear_all_clears_whole_pair() {
    let mut g = Grid::new(4, 2);
    assert!(g.set_wide(1, 2, wide('あ')));
    g.clear_all();
    for row in 0..2 {
        for col in 0..4 {
            assert_eq!(g.get(row, col).unwrap(), &Cell::default());
        }
    }
}

#[test]
fn test_clearing_wide_half_also_clears_spacer() {
    // clear_line starts at the wide cell; the spacer to its right is in
    // range anyway, but clear_line_to must reach forward to it.
    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    g.clear_line_to(0, 1);
    assert_eq!(g.get(0, 1).unwrap(), &Cell::default());
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());
    assert_no_orphans(&(0..4).map(|c| *g.get(0, c).unwrap()).collect::<Vec<_>>());
}

#[test]
fn test_clearing_spacer_half_also_clears_wide_cell() {
    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    // Range starts at the spacer: must reach back to the wide half.
    g.clear_line(0, 2);
    assert_eq!(g.get(0, 1).unwrap(), &Cell::default());
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());
    assert_no_orphans(&(0..4).map(|c| *g.get(0, c).unwrap()).collect::<Vec<_>>());

    let mut g = Grid::new(4, 1);
    assert!(g.set_wide(0, 1, wide('あ')));
    g.clear_line_full(0);
    assert!(g.set_wide(0, 1, wide('い')));
    g.clear_line_to(0, 2);
    assert_eq!(g.get(0, 1).unwrap(), &Cell::default());
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());
}

#[test]
fn test_scroll_up_preserves_wide_pair_in_scrollback() {
    let mut g = Grid::new(4, 2);
    assert!(g.set_wide(0, 0, wide('あ')));
    g.scroll_up(1);

    let line = g.scrollback_line(0).unwrap();
    assert_eq!(line[0].char, 'あ');
    assert!(!line[0].is_wide_spacer);
    assert!(line[1].is_wide_spacer);
    assert_eq!(line[1].bg, Color::Rgb(1, 2, 3));
    assert_no_orphans(line);

    // The vacated row is blank.
    assert_eq!(g.get(1, 0).unwrap(), &Cell::default());
}

#[test]
fn test_reflow_never_splits_wide_pair() {
    let mut g = Grid::new(6, 2);
    g.set(0, 0, Cell { char: 'a', ..Cell::default() });
    g.set(0, 1, Cell { char: 'b', ..Cell::default() });
    assert!(g.set_wide(0, 2, wide('あ')));
    g.set(0, 4, Cell { char: 'c', ..Cell::default() });
    g.set(0, 5, Cell { char: 'd', ..Cell::default() });

    // Width 3 would put the wide cell in the last column of row 0 and its
    // spacer at the start of row 1; the pair must move down together.
    g.resize(3, 6);
    assert_eq!(g.cols(), 3);

    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(0, 1).unwrap().char, 'b');
    assert_eq!(g.get(0, 2).unwrap(), &Cell::default());

    assert_eq!(g.get(1, 0).unwrap().char, 'あ');
    assert!(g.get(1, 1).unwrap().is_wide_spacer);
    assert_eq!(g.get(1, 2).unwrap().char, 'c');
    assert_eq!(g.get(2, 0).unwrap().char, 'd');
    assert!(g.is_line_wrapped(1));

    for row in 0..g.rows() {
        let line: Vec<Cell> = (0..g.cols()).map(|c| *g.get(row, c).unwrap()).collect();
        assert_no_orphans(&line);
        // A wide cell must never end a line: its spacer would have to live
        // on the next row.
        let last = line[g.cols() - 1];
        assert!(
            last.is_wide_spacer || last.char != 'あ',
            "wide cell orphaned in the last column of row {row}"
        );
    }
    assert_eq!(g.scrollback_len(), 0);
}

#[test]
fn test_reflow_grow_keeps_pair_together() {
    let mut g = Grid::new(3, 3);
    assert!(g.set_wide(0, 0, wide('あ')));
    g.set(0, 2, Cell { char: 'x', ..Cell::default() });
    g.set_line_wrapped(1, true);
    assert!(g.set_wide(1, 0, wide('い')));

    g.resize(5, 3);
    let line: Vec<Cell> = (0..5).map(|c| *g.get(0, c).unwrap()).collect();
    assert_no_orphans(&line);
    assert_eq!(line[0].char, 'あ');
    assert!(line[1].is_wide_spacer);
    assert_eq!(line[2].char, 'x');
    assert_eq!(line[3].char, 'い');
    assert!(line[4].is_wide_spacer);
}

// ---------------------------------------------------------------------
// Row-circular storage: the visible grid is addressed logically while the
// backing rows rotate, so every accessor has to survive wraparound.
// ---------------------------------------------------------------------

fn fill_row(g: &mut Grid, row: usize, ch: char) {
    for col in 0..g.cols() {
        g.set(row, col, Cell { char: ch, ..Cell::default() });
    }
}

fn row_chars(g: &Grid, row: usize) -> String {
    (0..g.cols()).map(|c| g.get(row, c).unwrap().char).collect()
}

/// Scroll far enough that the physical row origin laps the buffer several
/// times, checking the visible window and scrollback at every step.
#[test]
fn test_scroll_up_across_many_wraparounds() {
    const ROWS: usize = 3;
    let mut g = Grid::with_scrollback_capacity(2, ROWS, 100);
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    let labels: Vec<char> = "defghijklm".chars().collect();
    let mut history: Vec<char> = vec!['a', 'b', 'c'];
    for (i, &ch) in labels.iter().enumerate() {
        g.scroll_up(1);
        fill_row(&mut g, ROWS - 1, ch);
        history.push(ch);

        // The visible window is always the last ROWS labels written.
        for (row, &expected) in history[history.len() - ROWS..].iter().enumerate() {
            assert_eq!(
                row_chars(&g, row),
                expected.to_string().repeat(2),
                "row {row} after scroll {i}"
            );
        }
        assert_eq!(g.scrollback_len(), i + 1);
        assert_eq!(
            g.scrollback_line(0).unwrap()[0].char,
            history[history.len() - ROWS - 1],
            "newest scrollback line after scroll {i}"
        );
    }

    // Scrollback keeps every evicted row in oldest-first order.
    let sb: Vec<char> = g.scrollback_iter().map(|line| line[0].char).collect();
    assert_eq!(sb, history[..history.len() - ROWS].to_vec());
}

#[test]
fn test_scroll_up_with_blank_uses_template_across_wraparound() {
    let mut g = Grid::new(3, 2);
    let blank = Cell {
        char: ' ',
        bg: Color::Rgb(9, 8, 7),
        attrs: CellAttrs::REVERSE,
        protected: true,
        ..Cell::default()
    };

    for i in 0..7 {
        g.scroll_up_with_blank(1, blank);
        for col in 0..3 {
            assert_eq!(g.get(1, col).unwrap(), &blank, "iteration {i}");
        }
    }

    // Mark the top row so a full-height scroll has something to overwrite.
    fill_row(&mut g, 0, 'k');
    g.scroll_up_with_blank(2, blank);
    for row in 0..2 {
        for col in 0..3 {
            assert_eq!(g.get(row, col).unwrap(), &blank, "row {row} col {col}");
        }
    }
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'k');
}

#[test]
fn test_line_wrapped_and_semantic_follow_rows_across_wraparound() {
    let mut g = Grid::new(2, 3);
    for i in 0..7 {
        g.scroll_up(1);
        // The row scrolled in at the bottom is always hard and unmarked.
        assert!(!g.is_line_wrapped(2), "iteration {i}");
        assert_eq!(g.row_semantic_prompt(2), SemanticPrompt::Unset, "iteration {i}");
        g.set_line_wrapped(2, true);
        g.set_row_semantic_prompt(2, SemanticPrompt::Prompt);
    }

    // Every visible row was marked on one of the last three iterations.
    for row in 0..3 {
        assert!(g.is_line_wrapped(row), "row {row}");
        assert_eq!(g.row_semantic_prompt(row), SemanticPrompt::Prompt, "row {row}");
    }

    g.scroll_up(1);
    assert!(g.is_line_wrapped(0));
    assert!(g.is_line_wrapped(1));
    assert!(!g.is_line_wrapped(2));
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(2), SemanticPrompt::Unset);
    // The wrapped flag rode into scrollback with its row.
    assert!(g.scrollback_line_wrapped(0));
}

#[test]
fn test_mutations_target_correct_rows_after_wraparound() {
    let mut g = Grid::new(4, 3);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    g.get_mut(1, 0).unwrap().char = 'B';
    assert_eq!(row_chars(&g, 0), "aaaa");
    assert_eq!(row_chars(&g, 1), "Bbbb");
    assert_eq!(row_chars(&g, 2), "cccc");

    g.clear_line(0, 2);
    assert_eq!(row_chars(&g, 0), "aa\0\0");
    assert_eq!(row_chars(&g, 1), "Bbbb");

    g.fill_cells(2, 1, 3, Cell { char: '-', ..Cell::default() });
    assert_eq!(row_chars(&g, 2), "c--c");

    // A wide pair still lands inside a single row.
    assert!(g.set_wide(1, 2, wide('あ')));
    assert_eq!(g.get(1, 2).unwrap().char, 'あ');
    assert!(g.get(1, 3).unwrap().is_wide_spacer);
    assert_eq!(row_chars(&g, 0), "aa\0\0");
    assert_eq!(row_chars(&g, 2), "c--c");

    g.clear_line_full(1);
    assert_eq!(row_chars(&g, 1), "\0\0\0\0");
    assert_eq!(row_chars(&g, 2), "c--c");

    // Out-of-range writes stay no-ops rather than wrapping onto a live row.
    g.set(3, 0, Cell { char: '!', ..Cell::default() });
    g.set(5, 0, Cell { char: '!', ..Cell::default() });
    assert_eq!(row_chars(&g, 0), "aa\0\0");
    assert_eq!(row_chars(&g, 2), "c--c");
    assert!(g.get(3, 0).is_none());
}

#[test]
fn test_dirty_flags_follow_logical_rows_after_wraparound() {
    let mut g = Grid::new(2, 3);
    for _ in 0..4 {
        g.scroll_up(1);
    }
    g.clear_dirty();
    for row in 0..3 {
        assert!(!g.is_dirty(row), "row {row}");
    }

    g.set(1, 0, Cell { char: 'x', ..Cell::default() });
    assert!(!g.is_dirty(0));
    assert!(g.is_dirty(1));
    assert!(!g.is_dirty(2));

    g.clear_dirty();
    g.mark_dirty(2);
    assert!(!g.is_dirty(0));
    assert!(!g.is_dirty(1));
    assert!(g.is_dirty(2));

    // Out-of-range rows must not alias onto a live row.
    g.clear_dirty();
    g.mark_dirty(3);
    g.mark_dirty(5);
    for row in 0..3 {
        assert!(!g.is_dirty(row), "row {row}");
    }
    assert!(!g.is_dirty(3));

    // Scrolling damages the whole screen.
    g.scroll_up(1);
    for row in 0..3 {
        assert!(g.is_dirty(row), "row {row}");
    }
}

#[test]
fn test_full_height_scroll_after_wraparound() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for _ in 0..4 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    // n == rows, and n > rows, both blank the screen wholesale.
    g.scroll_up(3);
    assert_eq!(g.scrollback_line(2).unwrap()[0].char, 'a');
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'b');
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'c');
    for row in 0..3 {
        assert_eq!(row_chars(&g, row), "\0\0", "row {row}");
    }

    fill_row(&mut g, 1, 'z');
    assert_eq!(row_chars(&g, 0), "\0\0");
    assert_eq!(row_chars(&g, 1), "zz");
    assert_eq!(row_chars(&g, 2), "\0\0");

    let before = g.scrollback_len();
    g.scroll_up(9);
    assert_eq!(g.scrollback_len(), before + 3);
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'z');
    for row in 0..3 {
        assert_eq!(row_chars(&g, row), "\0\0", "row {row}");
    }
}

#[test]
fn test_stash_top_rows_after_wraparound() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for _ in 0..4 {
        g.scroll_up(1);
    }
    let before = g.scrollback_len();
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }
    g.set_line_wrapped(1, true);

    g.stash_top_rows(2);
    assert_eq!(g.scrollback_len(), before + 2);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'b');
    assert!(g.scrollback_line_wrapped(0));
    assert_eq!(g.scrollback_line(1).unwrap()[0].char, 'a');
    assert!(!g.scrollback_line_wrapped(1));

    // Nothing on screen moved.
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert_eq!(row_chars(&g, 2), "cc");
}

#[test]
fn test_clear_all_after_wraparound() {
    let mut g = Grid::new(3, 3);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for row in 0..3 {
        fill_row(&mut g, row, 'x');
    }
    g.set_line_wrapped(1, true);

    g.clear_all();
    for row in 0..3 {
        assert_eq!(row_chars(&g, row), "\0\0\0", "row {row}");
        assert!(!g.is_line_wrapped(row), "row {row}");
    }
}

#[test]
fn test_resize_rows_after_wraparound() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }
    g.set_line_wrapped(2, true);
    g.set_row_semantic_prompt(1, SemanticPrompt::Prompt);

    // Grow: content stays anchored at the top, blanks appended below.
    g.resize(2, 5);
    assert_eq!(g.rows(), 5);
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert_eq!(row_chars(&g, 2), "cc");
    assert_eq!(row_chars(&g, 3), "\0\0");
    assert_eq!(row_chars(&g, 4), "\0\0");
    assert!(g.is_line_wrapped(2));
    assert!(!g.is_line_wrapped(3));
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Unset);

    // Shrink: blank padding is trimmed first, then only the remaining top row
    // goes to scrollback.
    let before = g.scrollback_len();
    g.resize(2, 2);
    assert_eq!(g.rows(), 2);
    assert_eq!(g.scrollback_len(), before + 1);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'a');
    assert_eq!(row_chars(&g, 0), "bb");
    assert_eq!(row_chars(&g, 1), "cc");
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::Unset);

    // And it still scrolls correctly once the ring has been rebuilt.
    fill_row(&mut g, 1, 'q');
    g.scroll_up(1);
    assert_eq!(row_chars(&g, 0), "qq");
    assert_eq!(row_chars(&g, 1), "\0\0");
}

#[test]
fn test_reflow_after_wraparound_reads_logical_rows() {
    let mut g = Grid::with_scrollback_capacity(6, 3, 100);
    for _ in 0..7 {
        g.scroll_up(1);
    }
    for (i, ch) in "abcdef".chars().enumerate() {
        g.set(0, i, Cell { char: ch, ..Cell::default() });
    }
    for (i, ch) in "ghi".chars().enumerate() {
        g.set(1, i, Cell { char: ch, ..Cell::default() });
    }
    let scrollback_before = g.scrollback_len();

    g.resize(3, 4);
    assert_eq!(g.cols(), 3);
    assert_eq!(g.rows(), 4);
    assert_eq!(row_chars(&g, 0), "abc");
    assert_eq!(row_chars(&g, 1), "def");
    assert_eq!(row_chars(&g, 2), "ghi");
    assert_eq!(row_chars(&g, 3), "\0\0\0");
    assert!(!g.is_line_wrapped(0));
    assert!(g.is_line_wrapped(1));
    assert!(!g.is_line_wrapped(2));
    // Reflow of the visible screen must not disturb scrollback.
    assert_eq!(g.scrollback_len(), scrollback_before);

    // Scrolling still works against the rebuilt storage.
    g.scroll_up(1);
    assert_eq!(row_chars(&g, 0), "def");
    assert_eq!(row_chars(&g, 1), "ghi");
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'a');
}

#[test]
fn test_resize_no_reflow_after_wraparound() {
    let mut g = Grid::new(4, 3);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }
    g.set_line_wrapped(1, true);
    g.set_row_semantic_prompt(1, SemanticPrompt::PromptContinuation);

    g.resize_no_reflow(2, 2);
    assert_eq!(g.cols(), 2);
    assert_eq!(g.rows(), 2);
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert!(!g.is_line_wrapped(0));
    assert!(g.is_line_wrapped(1));
    assert_eq!(g.row_semantic_prompt(0), SemanticPrompt::Unset);
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::PromptContinuation);

    g.scroll_up(1);
    assert_eq!(row_chars(&g, 0), "bb");
    assert_eq!(row_chars(&g, 1), "\0\0");
}

#[test]
fn test_resize_no_reflow_after_wraparound_trims_orphan_wide_cell() {
    let mut g = Grid::new(4, 2);
    for _ in 0..3 {
        g.scroll_up(1);
    }
    assert!(g.set_wide(0, 1, wide('あ')));
    // Truncating to 2 columns would keep the wide half but drop its spacer.
    g.resize_no_reflow(2, 2);
    assert_eq!(g.cols(), 2);
    let line: Vec<Cell> = (0..2).map(|c| *g.get(0, c).unwrap()).collect();
    assert_eq!(line[1], Cell::default());
    assert_no_orphans(&line);
}

/// Two grids with identical logical content must format identically even
/// when their physical row origins differ.
#[test]
fn test_debug_is_independent_of_physical_rotation() {
    let mut rotated = Grid::with_scrollback_capacity(3, 3, 0);
    for _ in 0..4 {
        rotated.scroll_up(1);
    }
    let mut fresh = Grid::with_scrollback_capacity(3, 3, 0);

    for g in [&mut rotated, &mut fresh] {
        for row in 0..3 {
            fill_row(g, row, 'q');
        }
        g.set_line_wrapped(2, true);
        g.set_row_semantic_prompt(0, SemanticPrompt::Prompt);
    }

    assert_eq!(rotated.scrollback_len(), 0);
    assert_eq!(format!("{rotated:?}"), format!("{fresh:?}"));

    // A clone of a rotated grid behaves (and formats) like its source.
    let cloned = rotated.clone();
    assert_eq!(format!("{cloned:?}"), format!("{rotated:?}"));
    for row in 0..3 {
        assert_eq!(row_chars(&cloned, row), row_chars(&rotated, row));
    }
}

#[test]
fn test_clone_after_wraparound_scrolls_independently() {
    let mut g = Grid::with_scrollback_capacity(2, 3, 100);
    for _ in 0..5 {
        g.scroll_up(1);
    }
    for (row, ch) in [(0, 'a'), (1, 'b'), (2, 'c')] {
        fill_row(&mut g, row, ch);
    }

    let mut cloned = g.clone();
    cloned.scroll_up(1);
    fill_row(&mut cloned, 2, 'd');

    assert_eq!(row_chars(&cloned, 0), "bb");
    assert_eq!(row_chars(&cloned, 1), "cc");
    assert_eq!(row_chars(&cloned, 2), "dd");
    // The original is untouched.
    assert_eq!(row_chars(&g, 0), "aa");
    assert_eq!(row_chars(&g, 1), "bb");
    assert_eq!(row_chars(&g, 2), "cc");
    assert_eq!(cloned.scrollback_len(), g.scrollback_len() + 1);
}

#[test]
fn test_scroll_region_up_rotates_only_region_after_global_wraparound() {
    let mut g = Grid::with_scrollback_capacity(2, 5, 0);
    for (row, ch) in ['A', 'B', 'C', 'D', 'E'].into_iter().enumerate() {
        fill_row(&mut g, row, ch);
    }

    // Put the global circular origin in the middle of the physical buffer,
    // then repopulate the newly-exposed bottom row.
    g.scroll_up(1);
    fill_row(&mut g, 4, 'F');
    g.set_line_wrapped(1, true);
    g.set_line_wrapped(2, false);
    g.set_row_semantic_prompt(1, SemanticPrompt::Prompt);
    g.set_row_semantic_prompt(2, SemanticPrompt::PromptContinuation);
    g.set_row_semantic_prompt(3, SemanticPrompt::Prompt);
    g.clear_dirty();

    let blank = Cell { char: '#', ..Cell::default() };
    g.scroll_region_up_with_blank(1, 3, 1, blank);

    assert_eq!(row_chars(&g, 0), "BB");
    assert_eq!(row_chars(&g, 1), "DD");
    assert_eq!(row_chars(&g, 2), "EE");
    assert_eq!(row_chars(&g, 3), "##");
    assert_eq!(row_chars(&g, 4), "FF");
    assert!(!g.is_line_wrapped(1));
    assert_eq!(g.row_semantic_prompt(1), SemanticPrompt::PromptContinuation);
    assert_eq!(g.row_semantic_prompt(2), SemanticPrompt::Prompt);
    assert_eq!(g.row_semantic_prompt(3), SemanticPrompt::Unset);
    assert!(!g.is_dirty(0));
    assert!(g.is_dirty(1));
    assert!(g.is_dirty(2));
    assert!(g.is_dirty(3));
    assert!(!g.is_dirty(4));
    assert_eq!(g.scrollback_len(), 0);
}

#[test]
fn test_region_rotation_normalizes_for_resize_and_composes_with_full_scroll() {
    let mut g = Grid::with_scrollback_capacity(1, 5, 10);
    for (row, ch) in ['A', 'B', 'C', 'D', 'E'].into_iter().enumerate() {
        fill_row(&mut g, row, ch);
    }

    g.scroll_region_up_with_blank(1, 3, 1, Cell::default());
    g.resize(1, 6);
    assert_eq!(
        (0..6).map(|row| row_chars(&g, row)).collect::<Vec<_>>(),
        vec!["A", "C", "D", "\0", "E", "\0"]
    );

    g.scroll_up(1);
    assert_eq!(
        (0..6).map(|row| row_chars(&g, row)).collect::<Vec<_>>(),
        vec!["C", "D", "\0", "E", "\0", "\0"]
    );
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'A');
}

#[test]
fn test_wide_row_hint_follows_rotations_and_full_clears() {
    let mut g = Grid::with_scrollback_capacity(4, 4, 0);
    assert!((0..4).all(|row| !g.row_may_have_wide(row)));

    assert!(g.set_wide(1, 1, Cell { char: '界', ..Cell::default() }));
    assert!(g.row_may_have_wide(1));
    assert!(!g.row_may_have_wide(0));
    assert!(!g.row_may_have_wide(2));

    g.scroll_up(1);
    assert!(g.row_may_have_wide(0));
    assert!(!g.row_may_have_wide(3));

    g.scroll_region_up_with_blank(0, 2, 1, Cell::default());
    assert!(!g.row_may_have_wide(0));
    assert!(!g.row_may_have_wide(2));

    assert!(g.set_wide(3, 0, Cell { char: '界', ..Cell::default() }));
    g.clear_line_full(3);
    assert!(!g.row_may_have_wide(3));
}

#[test]
fn test_full_scroll_moves_and_recycles_row_buffers() {
    let mut g = Grid::with_scrollback_capacity(4, 2, 1);
    g.set(0, 0, Cell { char: 'A', ..Cell::default() });
    g.set(1, 0, Cell { char: 'B', ..Cell::default() });

    let first_row_buffer = g.row_slice(0).as_ptr();
    g.scroll_up(1);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'A');
    assert_eq!(g.scrollback_line(0).unwrap().as_ptr(), first_row_buffer);

    g.scroll_up(1);
    assert_eq!(g.scrollback_line(0).unwrap()[0].char, 'B');
    assert_eq!(g.row_slice(1).as_ptr(), first_row_buffer);
    assert!(g.row_slice(1).iter().all(|cell| *cell == Cell::default()));
}

#[test]
fn test_recycled_scrollback_row_adopts_current_width() {
    let mut g = Grid::with_scrollback_capacity(2, 2, 1);
    g.set(0, 0, Cell { char: 'A', ..Cell::default() });
    g.scroll_up(1);

    g.resize(4, 2);
    g.scroll_up(1);

    assert_eq!(g.row_slice(1).len(), 4);
    assert!(g.row_slice(1).iter().all(|cell| *cell == Cell::default()));
}

#[test]
fn test_portrait_landscape_portrait_terminal_stale_suffix_regression() {
    use crate::terminal::Terminal;

    let mut term = Terminal::with_scrollback(53, 26, 1000);
    for i in 1..26 {
        term.feed(format!("line {}\r\n", i).as_bytes());
    }
    term.feed(b"prompt$ ");
    assert_eq!(term.cursor(), (25, 8));

    // Rotate to landscape (101 x 11)
    term.resize(101, 11);
    assert_eq!(term.cursor(), (10, 8));

    // Run command in landscape
    term.feed(b"stty size\r\n11 101\r\nRESTORED_11 101\r\nprompt$ ");
    assert_eq!(term.cursor(), (10, 8));

    // Rotate back to portrait (53 x 26)
    term.resize(53, 26);
    assert_eq!(term.cursor(), (25, 8));

    // Run shorter subsequent command in portrait
    term.feed(b"stty size\r\n26 53\r\nRESTORED_26 53\r\n");

    // Scan all rows to verify exact lines: no stale "01" suffix and no "stty sizesize"
    let mut found_exact_restored = false;
    for r in 0..term.active_grid().rows() {
        let line_chars = row_chars(term.active_grid(), r);
        let trimmed = line_chars.trim_end_matches('\0').trim();
        assert!(
            !trimmed.contains("RESTORED_26 5301"),
            "row {r} has corrupted stale suffix: {trimmed:?}"
        );
        assert!(
            !trimmed.contains("stty sizesize"),
            "row {r} has duplicated command text: {trimmed:?}"
        );
        if trimmed == "RESTORED_26 53" {
            found_exact_restored = true;
        }
    }
    assert!(
        found_exact_restored,
        "must contain the clean exact line RESTORED_26 53"
    );
}

#[test]
fn test_grid_portrait_landscape_portrait_cursor_and_reflow() {
    let mut g = Grid::with_scrollback_capacity(53, 26, 1000);
    for i in 0..25 {
        for (col, ch) in format!("item {}", i).chars().enumerate() {
            g.set(i, col, Cell { char: ch, ..Cell::default() });
        }
        g.set_line_wrapped(i, false);
    }
    for (col, ch) in "prompt$ ".chars().enumerate() {
        g.set(25, col, Cell { char: ch, ..Cell::default() });
    }

    // Resize to landscape: 101 x 11
    let pos1 = g.resize_with_cursor(101, 11, Some((25, 8)));
    assert_eq!(pos1, Some((10, 8)));
    assert_eq!(g.cols(), 101);
    assert_eq!(g.rows(), 11);

    // Resize back to portrait: 53 x 26
    let pos2 = g.resize_with_cursor(53, 26, Some((10, 8)));
    assert_eq!(pos2, Some((25, 8)));
    assert_eq!(g.cols(), 53);
    assert_eq!(g.rows(), 26);
    assert_eq!(&row_chars(&g, 25)[..8], "prompt$ ");
}

#[test]
fn test_grid_resize_reflow_cursor_placement_wrapped_lines() {
    let mut g = Grid::new(10, 4);
    // Write a 25-char line across rows 0, 1, 2
    let text = "abcdefghijklmnopqrstuvwxy";
    for (i, ch) in text.chars().enumerate() {
        let r = i / 10;
        let c = i % 10;
        g.set(r, c, Cell { char: ch, ..Cell::default() });
        if r > 0 {
            g.set_line_wrapped(r, true);
        }
    }
    // Cursor on 'm' (index 12 -> row 1, col 2 at width 10)
    assert_eq!(g.get(1, 2).unwrap().char, 'm');

    // Resize to width 5, height 8
    // In width 5, 'm' (index 12) is at row 2, col 2 (12 / 5 = 2, 12 % 5 = 2)
    let new_pos = g.resize_with_cursor(5, 8, Some((1, 2)));
    assert_eq!(new_pos, Some((2, 2)));
    assert_eq!(g.get(2, 2).unwrap().char, 'm');

    // Resize to width 25, height 4
    // In width 25, 'm' (index 12) is at row 0, col 12
    let new_pos = g.resize_with_cursor(25, 4, Some((2, 2)));
    assert_eq!(new_pos, Some((0, 12)));
    assert_eq!(g.get(0, 12).unwrap().char, 'm');
}

#[test]
fn test_grid_resize_reflow_cursor_on_trailing_blank_cells() {
    let mut g = Grid::new(20, 2);
    // Write 5 characters on row 0
    for (c, ch) in "hello".chars().enumerate() {
        g.set(0, c, Cell { char: ch, ..Cell::default() });
    }
    // Cursor is at col 15 (a blank cell on row 0)
    let new_pos = g.resize_with_cursor(10, 4, Some((0, 15)));
    // At width 10, offset 15 is row 1, col 5
    assert_eq!(new_pos, Some((1, 5)));

    // Resize back to width 20, height 2
    let new_pos2 = g.resize_with_cursor(20, 2, Some((1, 5)));
    assert_eq!(new_pos2, Some((0, 15)));
}

#[test]
fn test_grid_resize_reflow_cursor_with_wide_characters() {
    let mut g = Grid::new(10, 2);
    g.set(0, 0, Cell { char: 'a', ..Cell::default() });
    g.set_wide(0, 1, wide('あ')); // cols 1 and 2
    g.set(0, 3, Cell { char: 'b', ..Cell::default() });

    // Cursor on 'あ' (col 1)
    let pos = g.resize_with_cursor(4, 4, Some((0, 1)));
    assert_eq!(pos, Some((0, 1)));
    assert_eq!(g.get(0, 1).unwrap().char, 'あ');

    // Cursor on spacer (col 2)
    let pos = g.resize_with_cursor(4, 4, Some((0, 2)));
    assert_eq!(pos, Some((0, 2)));
    assert!(g.get(0, 2).unwrap().is_wide_spacer);

    // Cursor on 'b' (col 3)
    let pos = g.resize_with_cursor(4, 4, Some((0, 3)));
    assert_eq!(pos, Some((0, 3)));
    assert_eq!(g.get(0, 3).unwrap().char, 'b');

    // If width shrinks to 2: 'a' is at (0, 0), wide pair 'あ' cannot fit on row 0, wraps to (1, 0)
    let pos = g.resize_with_cursor(2, 4, Some((0, 1)));
    assert_eq!(pos, Some((1, 0)));
    assert_eq!(g.get(1, 0).unwrap().char, 'あ');
}

#[test]
fn grapheme_clusters_are_interned_once_per_width() {
    let mut g = Grid::new(4, 2);
    assert_eq!(g.intern_grapheme("", false), 0);
    let narrow = g.intern_grapheme("\u{0301}", false);
    assert_ne!(narrow, 0);
    assert_eq!(g.intern_grapheme("\u{0301}", false), narrow);
    let wide = g.intern_grapheme("\u{0301}", true);
    assert_ne!(wide, narrow);
    let before = g.retained_capacity_bytes();
    g.set(0, 0, Cell { char: 'q', grapheme: narrow, ..Cell::default() });
    g.set_wide(0, 1, Cell { char: '\u{1F44D}', grapheme: wide, ..Cell::default() });
    let cell = *g.get(0, 0).unwrap();
    assert_eq!(g.grapheme(&cell), "\u{0301}");
    assert!(!g.cell_is_wide(&cell));
    assert!(g.cell_is_wide(g.get(0, 1).unwrap()));
    // The spacer names no cluster of its own.
    assert_eq!(g.get(0, 2).unwrap().grapheme, 0);
    let mut text = String::new();
    for col in 0..4 {
        g.push_cell_text(&mut text, g.get(0, col).unwrap());
    }
    assert_eq!(text, "q\u{0301}\u{1F44D}\u{0301}  ");
    assert_eq!(g.grapheme(&Cell::default()), "");
    assert!(g.retained_capacity_bytes() >= before);
}

#[test]
fn unused_grapheme_entries_are_reclaimed_and_live_ones_kept() {
    let mut g = Grid::with_scrollback_capacity(4, 2, 4);
    let kept = g.intern_grapheme("\u{0301}", false);
    g.set(0, 0, Cell { char: 'q', grapheme: kept, ..Cell::default() });
    g.scroll_up(1);
    let visible = g.intern_grapheme("\u{0302}", false);
    g.set(1, 0, Cell { char: 'a', grapheme: visible, ..Cell::default() });
    for n in 0..10_000 {
        g.intern_grapheme(&format!("\u{0303}{n}"), false);
    }
    assert!(g.graphemes.live() <= 4096, "{}", g.graphemes.live());
    let history = g.scrollback_line(0).unwrap()[0];
    assert_eq!(g.grapheme(&history), "\u{0301}");
    assert_eq!(g.grapheme(g.get(1, 0).unwrap()), "\u{0302}");
    // A reclaimed cluster interns again under a fresh or reused id.
    let again = g.intern_grapheme("\u{0303}0", false);
    assert_ne!(again, 0);
}

#[test]
fn a_full_grapheme_table_refuses_new_clusters_until_ids_are_free() {
    let mut g = Grid::with_scrollback_capacity(256, 256, 0);
    let mut stored = 0;
    'fill: for row in 0..256 {
        for col in 0..256 {
            let id = g.intern_grapheme(&format!("{row}:{col}"), false);
            if id == 0 {
                break 'fill;
            }
            g.set(row, col, Cell { char: 'a', grapheme: id, ..Cell::default() });
            stored += 1;
        }
    }
    assert_eq!(stored, u16::MAX as usize);
    assert_eq!(g.intern_grapheme("more", false), 0);
    // Clusters already interned are still found.
    assert_eq!(g.intern_grapheme("0:0", false), g.get(0, 0).unwrap().grapheme);

    // Once cells stop naming them, a later collection frees the ids; until
    // then the table refuses without rescanning the grid every time.
    g.clear_all();
    let mut refused = 0;
    while g.intern_grapheme("more", false) == 0 {
        refused += 1;
        assert!(refused <= 4096, "never collected");
    }
    assert!(refused > 0);
    assert!(g.graphemes.live() < 16);
}

#[test]
fn a_grapheme_id_costs_a_cell_no_bytes() {
    // The id sits in padding the cell already had.
    assert_eq!(std::mem::size_of::<Cell>(), 32);
}
