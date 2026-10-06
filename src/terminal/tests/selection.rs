/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::terminal::*;

#[test]
fn test_selection_linear_within_one_row() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"hello");
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(0, 4);
    assert_eq!(term.selection_range(), Some(((0, 0), (0, 4))));
    assert_eq!(term.selected_text(), Some("hello".to_string()));
}

#[test]
fn test_selection_linear_multi_row_joins_with_newline_and_trims_trailing_space() {
    let mut term = Terminal::new(10, 3);
    // "abc" on row 0, hard newline (not a soft wrap), "def" on row 1.
    term.feed(b"abc\r\ndef");
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(1, 2);
    assert!(!term.active_grid().is_line_wrapped(1));
    // Row 0 has 7 trailing blank cells after "abc" that must not appear.
    assert_eq!(term.selected_text(), Some("abc\ndef".to_string()));
}

#[test]
fn test_selection_linear_across_soft_wrap_has_no_newline_and_no_trim() {
    let mut term = Terminal::new(5, 3);
    // Fills row 0 exactly ("abcde") and soft-wraps 'f' onto row 1.
    term.feed(b"abcdef");
    assert!(term.active_grid().is_line_wrapped(1));
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(1, 0);
    // No "\n" at the wrap point, and row 0's full width is kept verbatim
    // (it's a mid-word wrap, not trailing padding).
    assert_eq!(term.selected_text(), Some("abcdef".to_string()));
}

#[test]
fn test_selection_rectangular_multi_row_narrower_than_full_width() {
    let mut term = Terminal::new(12, 3);
    term.feed(b"0123456789\r\nabcdefghij\r\nABCDEFGHIJ");
    term.start_selection(0, 2, SelectionMode::Rectangular);
    term.extend_selection(2, 5);
    assert_eq!(term.selection_range(), Some(((0, 2), (2, 5))));
    assert_eq!(term.selected_text(), Some("2345\ncdef\nCDEF".to_string()));
}

#[test]
fn test_selection_reversed_anchor_active_matches_forward_drag() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"abc\r\ndef");

    let mut forward = Terminal::new(10, 3);
    forward.feed(b"abc\r\ndef");
    forward.start_selection(0, 0, SelectionMode::Linear);
    forward.extend_selection(1, 2);

    // Same span, but dragged backward: mouse-down at the end, drag up to
    // the start.
    term.start_selection(1, 2, SelectionMode::Linear);
    term.extend_selection(0, 0);

    assert_eq!(term.selected_text(), forward.selected_text());
    assert_eq!(term.selected_text(), Some("abc\ndef".to_string()));
}

#[test]
fn test_clear_selection_and_has_selection() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"hello");
    assert!(!term.has_selection());
    assert_eq!(term.selected_text(), None);

    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(0, 4);
    assert!(term.has_selection());
    assert_eq!(term.selected_text(), Some("hello".to_string()));

    term.clear_selection();
    assert!(!term.has_selection());
    assert_eq!(term.selected_text(), None);
    assert_eq!(term.selection_range(), None);
}

#[test]
fn test_resize_with_active_selection_does_not_panic_and_stays_in_bounds() {
    let mut term = Terminal::new(10, 5);
    term.start_selection(4, 9, SelectionMode::Linear);
    term.extend_selection(0, 0);
    assert!(term.has_selection());

    term.resize(4, 3);

    assert!(term.has_selection());
    let (start, end) = term.selection_range().unwrap();
    assert!(start.0 < 3 && start.1 < 4);
    assert!(end.0 < 3 && end.1 < 4);
    // Extracting text must not panic even though the grid shrank out
    // from under the selection.
    let _ = term.selected_text();
}

#[test]
fn ios_surface_eviction_before_inside_active_selection() {
    let mut term = Terminal::with_scrollback(10, 3, 4);
    term.feed(b"Line 1\r\nLine 2\r\nLine 3\r\nLine 4\r\nLine 5\r\nLine 6\r\nLine 7");

    // Start a selection on the oldest retained line
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(2, 5);
    assert!(term.has_selection());

    let initial_text = term.selected_text();
    assert!(initial_text.is_some());

    // Scroll more lines to trigger scrollback eviction
    term.feed(b"\r\nLine 8\r\nLine 9\r\nLine 10");

    // Selection spanning boundary should remain valid and clamp upper evicted lines deterministically
    assert!(term.has_selection());
    let remaining_text = term.selected_text();
    assert!(remaining_text.is_some());

    // Feed many more lines to completely evict the selection
    for i in 11..=30 {
        term.feed(format!("\r\nLine {}", i).as_bytes());
    }

    // Selection should be completely evicted and return None
    assert!(!term.has_selection());
    assert_eq!(term.selected_text(), None);
}

#[test]
fn ios_surface_forward_reverse_rectangular_selection() {
    let mut term = Terminal::new(10, 4);
    term.feed(b"AAAA\r\nBBBB\r\nCCCC\r\nDDDD");

    // Forward linear selection
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(1, 3);
    let fwd_linear = term.selected_text();

    // Reverse linear selection
    term.start_selection(1, 3, SelectionMode::Linear);
    term.extend_selection(0, 0);
    let rev_linear = term.selected_text();
    assert_eq!(fwd_linear, rev_linear);

    // Forward rectangular selection (drag top-left to bottom-right)
    term.start_selection(0, 1, SelectionMode::Rectangular);
    term.extend_selection(2, 2);
    let fwd_rect = term.selected_text();
    assert_eq!(fwd_rect, Some("AA\nBB\nCC".to_string()));

    // Reverse rectangular selection (drag bottom-right to top-left)
    term.start_selection(2, 2, SelectionMode::Rectangular);
    term.extend_selection(0, 1);
    let rev_rect1 = term.selected_text();
    assert_eq!(rev_rect1, Some("AA\nBB\nCC".to_string()));

    // Reverse rectangular selection (drag top-right to bottom-left)
    term.start_selection(0, 2, SelectionMode::Rectangular);
    term.extend_selection(2, 1);
    let rev_rect2 = term.selected_text();
    assert_eq!(rev_rect2, Some("AA\nBB\nCC".to_string()));
}

#[test]
fn ios_surface_resize_history_interactions() {
    let mut term = Terminal::with_scrollback(10, 4, 100);
    for i in 1..=20 {
        term.feed(format!("Item {}\r\n", i).as_bytes());
    }

    // Start a selection in history
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(2, 5);
    assert!(term.has_selection());

    // Resize grid
    term.resize(15, 6);
    assert!(term.has_selection());
    assert!(term.selected_text().is_some());

    term.resize(5, 2);
    assert!(term.selected_text().is_some() || !term.has_selection());
}

#[test]
fn test_scrollback_soft_wrap_selection_eviction_forward_reverse() {
    let mut term = Terminal::with_scrollback(5, 2, 2);

    term.feed(b"ABCDEFGHIJKLMNOPQRST");

    assert_eq!(term.active_grid().scrollback_len(), 2);
    assert!(!term.is_line_wrapped_abs(0));
    assert!(term.is_line_wrapped_abs(1));
    assert!(term.is_line_wrapped_abs(2));
    assert!(term.is_line_wrapped_abs(3));

    term.scroll_viewport_up(2);
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(3, 4);
    let forward_selected = term.selected_text().unwrap();
    assert_eq!(forward_selected, "ABCDEFGHIJKLMNOPQRST");

    term.start_selection(3, 4, SelectionMode::Linear);
    term.extend_selection(0, 0);
    let reverse_selected = term.selected_text().unwrap();
    assert_eq!(reverse_selected, "ABCDEFGHIJKLMNOPQRST");

    term.feed(b"\r\nUVWXYZ");
    assert_eq!(term.active_grid().scrollback_len(), 2);

    term.scroll_viewport_up(2);
    term.start_selection(0, 0, SelectionMode::Linear);
    term.extend_selection(3, 4);
    let evicted_selected = term.selected_text().unwrap();
    // The new CR/LF output evicts the first wrapped pair from the
    // capacity-two scrollback. Selection must clamp to the oldest line
    // still retained, rather than referencing discarded text.
    assert_eq!(evicted_selected, "KLMNOPQRST\nUVWXYZ");
}
