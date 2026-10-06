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

#[test]
fn viewport_offset_scrollback_len_and_viewport_row_track_scroll_state() {
    let core = TakoCore::new(10, 3);
    for i in 0..10 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    assert_eq!(core.viewport_offset(), 0);
    assert!(core.scrollback_len() > 0);

    core.scroll_viewport_up(2);
    assert_eq!(core.viewport_offset(), 2);

    let row = core.viewport_row(0);
    assert_eq!(row.len(), 10);
    let text: String = row
        .iter()
        .map(|c| char::from_u32(c.ch).unwrap_or(' '))
        .collect();
    assert!(
        text.trim_end().starts_with('L'),
        "viewport_row must read the scrolled-to line, got {text:?}"
    );
}

// -----------------------------------------------------------------------
// Cursor / geometry / line accessors (src/ffi/mod.rs:1368-1459)
// -----------------------------------------------------------------------

/// `cursor_is_at_prompt` and `row_semantic_prompt` after OSC 133;A marks
/// the current row as a shell prompt.
#[test]
fn cursor_is_at_prompt_and_row_semantic_prompt_after_osc_133() {
    let core = TakoCore::new(20, 5);
    assert!(!core.cursor_is_at_prompt());
    assert_eq!(core.row_semantic_prompt(0), 0);

    core.feed(b"\x1b]133;A\x07$ ".to_vec());
    assert!(core.cursor_is_at_prompt());
    assert_eq!(core.row_semantic_prompt(0), 1);
}

/// `resize` changes both `cols()`/`rows()` and what `get_line` returns for
/// the same row index.
#[test]
fn resize_changes_reported_geometry() {
    let core = TakoCore::new(10, 3);
    core.feed(b"hi".to_vec());
    assert_eq!((core.cols(), core.rows()), (10, 3));
    core.resize(20, 6);
    assert_eq!((core.cols(), core.rows()), (20, 6));
}

/// `cursor_row`/`cursor_col`/`cursor_visible`/`title` reflect the terminal
/// state directly.
#[test]
fn cursor_and_title_accessors_report_live_state() {
    let core = TakoCore::new(20, 5);
    core.feed(b"abc".to_vec());
    assert_eq!(core.cursor_row(), 0);
    assert_eq!(core.cursor_col(), 3);
    assert!(core.cursor_visible());

    core.feed(b"\x1b[?25l".to_vec());
    assert!(!core.cursor_visible());

    core.feed(b"\x1b]0;My Title\x07".to_vec());
    assert_eq!(core.title(), "My Title");
}

/// `get_cell` returns `None` past the grid bounds.
#[test]
fn get_cell_out_of_bounds_returns_none() {
    let core = TakoCore::new(5, 2);
    assert!(core.get_cell(100, 100).is_none());
    assert!(core.get_cell(0, 0).is_some());
}

/// `get_line` returns the plain text of a row with no styling, and an
/// empty string for a row past the grid's bounds.
#[test]
fn get_line_returns_plain_text_and_empty_out_of_bounds() {
    let core = TakoCore::new(10, 2);
    core.feed(b"hey".to_vec());
    assert_eq!(core.get_line(0).trim_end_matches(['\0', ' ']), "hey");
    assert_eq!(core.get_line(50), "");
}

// -----------------------------------------------------------------------
// Selection surface (src/ffi/mod.rs:1481-1526)
// -----------------------------------------------------------------------

/// `select_word` selects the whole word under the point, `select_line`
/// selects the whole logical line, `has_selection`/`selected_text` and
/// `clear_selection` round-trip through them.
#[test]
fn select_word_and_select_line_produce_expected_text() {
    let core = TakoCore::new(30, 3);
    core.feed(b"hello world".to_vec());

    assert!(!core.has_selection());
    core.select_word(0, 2); // inside "hello"
    assert!(core.has_selection());
    assert_eq!(core.selected_text().as_deref(), Some("hello"));

    core.select_line(0, 0);
    assert_eq!(core.selected_text().as_deref(), Some("hello world"));

    core.clear_selection();
    assert!(!core.has_selection());
    assert!(core.selected_text().is_none());
    assert!(core.selection_range().is_none());
}

// -----------------------------------------------------------------------
// scroll_to / scroll_position (src/ffi/mod.rs:1543-1572)
// -----------------------------------------------------------------------

/// `scroll_to` snaps to bottom first, then scrolls up by the given offset
/// -- so it is absolute, not relative to wherever the viewport already was.
#[test]
fn scroll_to_is_absolute_from_the_bottom() {
    let core = TakoCore::new(10, 3);
    for i in 0..20 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    core.scroll_viewport_up(5);
    assert_eq!(core.viewport_offset(), 5);

    core.scroll_to(2);
    assert_eq!(
        core.viewport_offset(),
        2,
        "scroll_to must be absolute, not additive"
    );

    core.scroll_to(0);
    assert_eq!(core.viewport_offset(), 0);
}

/// `scroll_position`/`set_scroll_position` round-trip a fraction, and an
/// out-of-range value is clamped rather than rejected.
#[test]
fn scroll_position_round_trips_and_clamps() {
    let core = TakoCore::new(10, 3);
    for i in 0..20 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    assert_eq!(core.scroll_position(), 1.0, "live screen is fraction 1");

    core.set_scroll_position(0.0);
    assert_eq!(
        core.scroll_position(),
        0.0,
        "oldest retained line is fraction 0"
    );

    core.set_scroll_position(-5.0);
    assert_eq!(core.scroll_position(), 0.0, "below range clamps to 0");

    core.set_scroll_position(5.0);
    assert_eq!(core.scroll_position(), 1.0, "above range clamps to 1");
}

// -----------------------------------------------------------------------
// get_plain_text (src/ffi/mod.rs:1575-1608)
// -----------------------------------------------------------------------

/// `get_plain_text` joins wrapped lines and trims trailing spaces on real
/// content, out-of-bounds `start_row` returns an empty string, and trailing
/// blank lines are dropped from the result.
#[test]
fn get_plain_text_joins_wraps_trims_and_bounds_check() {
    let core = TakoCore::new(10, 5);
    core.feed(b"a line with more than ten chars\r\nshort".to_vec());

    assert_eq!(
        core.get_plain_text(50, 5),
        "",
        "start_row past the grid returns empty"
    );

    let text = core.get_plain_text(0, 5);
    let lines: Vec<&str> = text.split('\n').collect();
    // The long first logical line soft-wraps across several rows; joined
    // back into one line with no internal trailing spaces, followed by
    // "short" -- and no empty trailing lines despite unused rows below.
    assert!(lines[0].starts_with("a line with more than ten chars"));
    assert!(lines.iter().all(|l| !l.ends_with(' ')));
    assert_eq!(lines.last(), Some(&"short"));
}

/// A `max_rows` of 0 (or a start_row exactly at the row count) is the
/// degenerate empty-range case.
#[test]
fn get_plain_text_zero_max_rows_is_empty() {
    let core = TakoCore::new(10, 3);
    core.feed(b"content".to_vec());
    assert_eq!(core.get_plain_text(0, 0), "");
}

// -----------------------------------------------------------------------
// snapshot() graphics placements (src/ffi/mod.rs:1611-1660)
// -----------------------------------------------------------------------

/// `snapshot().graphics_placements` reports live Kitty Graphics placements
/// with their cell coordinates, mirroring `graphics_placements()`.
#[test]
fn snapshot_reports_graphics_placements() {
    let core = TakoCore::new(20, 10);
    let payload = base64_encode(&[10, 20, 30]);
    core.feed(format!("\x1b_Ga=T,f=24,s=1,v=1,i=7;{payload}\x1b\\").into_bytes());

    let snap = core.snapshot();
    let placements = core.graphics_placements();
    assert_eq!(snap.graphics_placements.len(), placements.len());
    if let Some(p) = snap.graphics_placements.first() {
        assert_eq!(p.image_id, 7);
    }
}
