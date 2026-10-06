/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;
use super::operations::*;

#[test]
fn test_property_resizing_invariants() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let mut term = Terminal::new(80, 24);

        // Feed some initial content with wrapping, styles and UTF-8
        for _ in 0..20 {
            term.feed(rng.choose(CURATED_VT_SNIPPETS));
            term.feed(rng.choose(CURATED_UTF8_TEXT).as_bytes());
        }

        for _ in 0..50 {
            let new_cols = match rng.gen_range(0, 4) {
                0 => 1,
                1 => rng.gen_range(2, 20),
                2 => rng.gen_range(21, 100),
                _ => rng.gen_range(101, 250),
            };
            let new_rows = match rng.gen_range(0, 4) {
                0 => 1,
                1 => rng.gen_range(2, 10),
                2 => rng.gen_range(11, 50),
                _ => rng.gen_range(51, 120),
            };

            term.resize(new_cols, new_rows);
            assert_durable_invariants(&term);

            // Interleaved feeds and scrolls
            if rng.gen_bool() {
                term.feed(rng.choose(CURATED_UTF8_TEXT).as_bytes());
            }
            if rng.gen_bool() {
                term.scroll_viewport_up(rng.gen_range(0, 10));
            }
            assert_durable_invariants(&term);
        }
    }
}

#[test]
fn test_property_selection_invariants() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let cols = rng.gen_range(10, 60);
        let rows = rng.gen_range(4, 20);
        let mut term = Terminal::new(cols, rows);

        // Populate with text
        for _ in 0..15 {
            term.feed(rng.choose(CURATED_UTF8_TEXT).as_bytes());
        }

        for _ in 0..40 {
            let row1 = rng.gen_range(0, rows + 50);
            let col1 = rng.gen_range(0, cols + 50);
            let row2 = rng.gen_range(0, rows + 50);
            let col2 = rng.gen_range(0, cols + 50);

            let mode = if rng.gen_bool() {
                SelectionMode::Linear
            } else {
                SelectionMode::Rectangular
            };

            // Test normal start + extend
            term.start_selection(row1, col1, mode);
            assert_durable_invariants(&term);

            term.extend_selection(row2, col2);
            assert_durable_invariants(&term);

            // Test word selection
            term.select_word(row1, col1);
            assert_durable_invariants(&term);

            // Test line selection
            term.select_line(row2, col2);
            assert_durable_invariants(&term);

            // Test clearing
            term.clear_selection();
            assert!(!term.has_selection());
            assert_eq!(term.selection_range(), None);
            assert_durable_invariants(&term);
        }
    }
}

#[test]
fn test_property_scrollback_and_viewport_invariants() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let cols = rng.gen_range(20, 80);
        let rows = rng.gen_range(4, 20);
        let mut term = Terminal::with_scrollback(cols, rows, 100);

        // Feed many lines to exceed scrollback capacity and trigger eviction
        for i in 0..300 {
            term.feed(format!("line {i} - {}\r\n", rng.choose(CURATED_UTF8_TEXT)).as_bytes());
        }
        let _ = term.take_output();

        assert_eq!(term.active_grid().scrollback_len(), 100);
        assert_durable_invariants(&term);

        // Test viewport movements
        for _ in 0..30 {
            let scroll_up = rng.gen_range(0, 150);
            term.scroll_viewport_up(scroll_up);
            assert_durable_invariants(&term);

            let scroll_down = rng.gen_range(0, 150);
            term.scroll_viewport_down(scroll_down);
            assert_durable_invariants(&term);

            let pos = match rng.gen_range(0, 5) {
                0 => -5.0,
                1 => 0.0,
                2 => rng.gen_f64(),
                3 => 1.0,
                _ => 10.0,
            };
            term.set_scroll_position(pos);
            assert_durable_invariants(&term);

            term.scroll_viewport_bottom();
            assert_eq!(term.viewport_offset(), 0);
            assert_eq!(term.scroll_position(), 1.0);
            assert_durable_invariants(&term);
        }
    }
}
