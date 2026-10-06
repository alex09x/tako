/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

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
            g.set(
                row,
                col,
                Cell {
                    char: ch,
                    ..Cell::default()
                },
            );
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
            g.set(
                0,
                col,
                Cell {
                    char: (b'0' + i) as char,
                    ..Cell::default()
                },
            );
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
    g.set(
        0,
        0,
        Cell {
            char: 'a',
            ..Cell::default()
        },
    );
    g.scroll_up(0);
    assert_eq!(g.scrollback_len(), 0);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
}

#[test]
fn test_clear_line_from_col() {
    let mut g = Grid::new(5, 1);
    for col in 0..5 {
        g.set(
            0,
            col,
            Cell {
                char: 'x',
                ..Cell::default()
            },
        );
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
        g.set(
            0,
            col,
            Cell {
                char: 'x',
                ..Cell::default()
            },
        );
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
        g.set(
            0,
            col,
            Cell {
                char: 'x',
                ..Cell::default()
            },
        );
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
            g.set(
                row,
                col,
                Cell {
                    char: 'x',
                    ..Cell::default()
                },
            );
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
    g.set(
        0,
        0,
        Cell {
            char: 'a',
            ..Cell::default()
        },
    );
    g.set(
        1,
        0,
        Cell {
            char: 'b',
            ..Cell::default()
        },
    );
    g.resize(3, 4);
    assert_eq!(g.rows(), 4);
    assert_eq!(g.cols(), 3);
    assert_eq!(g.get(0, 0).unwrap().char, 'a');
    assert_eq!(g.get(1, 0).unwrap().char, 'b');
    assert_eq!(g.get(2, 0).unwrap(), &Cell::default());
    assert_eq!(g.get(3, 0).unwrap(), &Cell::default());
    assert_eq!(g.scrollback_len(), 0);
}
