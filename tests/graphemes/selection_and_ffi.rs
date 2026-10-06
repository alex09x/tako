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
fn selection_copies_whole_clusters() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 3);
        feed(&mut t, &format!("a{}b\r\nc{}", k.text, k.text));
        t.start_selection(0, 0, SelectionMode::Linear);
        t.extend_selection(1, 9);
        assert_eq!(
            t.selected_text().unwrap(),
            format!("a{}b\nc{}", k.text, k.text),
            "{}",
            k.name
        );
        t.start_selection(0, 1, SelectionMode::Rectangular);
        t.extend_selection(1, 1 + k.width - 1);
        assert_eq!(
            t.selected_text().unwrap(),
            format!("{}\n{}", k.text, k.text),
            "{}",
            k.name
        );
        assert_eq!(
            t.plain_string_unwrapped(),
            format!("a{}b\nc{}", k.text, k.text),
            "{}",
            k.name
        );
    });
}

#[test]
fn variation_selector_15_narrows_an_emoji() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\u{231A}\u{FE0E}x");
    assert_eq!(t.cursor(), (0, 2));
    assert_eq!(t.plain_string(), "\u{231A}\u{FE0E}x");
    assert_eq!(t.active_grid().get(0, 1).unwrap().char, 'x');
    // At the right edge the pending wrap is given back with the column.
    let mut t = Terminal::new(4, 2);
    feed(&mut t, "ab\u{231A}\u{FE0E}x");
    assert_eq!(t.plain_string(), "ab\u{231A}\u{FE0E}x");
    assert_eq!(t.cursor(), (0, 3));
    assert!(t.pending_wrap());
}

#[test]
fn a_cluster_with_no_room_to_widen_stays_narrow() {
    // A one-column terminal can never hold two columns.
    let mut t = Terminal::new(1, 2);
    feed(&mut t, "\u{2764}\u{FE0F}");
    let cell = *t.active_grid().get(0, 0).unwrap();
    assert_eq!((cell.char, cell.grapheme), ('\u{2764}', 0));
    assert_eq!(t.cursor(), (0, 0));
    // Nor can the right margin's column without wraparound.
    let mut t = Terminal::new(5, 2);
    feed(
        &mut t,
        "\x1b[?7l\x1b[?69h\x1b[1;3s\x1b[1;3H\u{2764}\x1b[1;4H\u{FE0F}",
    );
    assert_eq!(t.active_grid().get(0, 2).unwrap().grapheme, 0);
    assert!(!t.active_grid().get(0, 3).unwrap().is_wide_spacer);
}

#[test]
fn mode_2027_is_reported_and_follows_the_width_method() {
    let query = |t: &mut Terminal| {
        feed(t, "\x1b[?2027$p");
        String::from_utf8(t.take_output()).unwrap()
    };
    let mut t = Terminal::new(10, 2);
    assert_eq!(t.grapheme_width_method(), GraphemeWidthMethod::Unicode);
    assert_eq!(query(&mut t), "\x1b[?2027;1$y");
    feed(&mut t, "\x1b[?2027l");
    assert_eq!(query(&mut t), "\x1b[?2027;2$y");
    // With the mode reset a skin tone takes its own two columns.
    feed(&mut t, "\u{1F44D}\u{1F3FD}");
    assert_eq!(t.cursor(), (0, 4));
    feed(&mut t, "\x1b[?2027h");
    assert_eq!(query(&mut t), "\x1b[?2027;1$y");

    t.set_grapheme_width_method(GraphemeWidthMethod::Legacy);
    assert_eq!(query(&mut t), "\x1b[?2027;2$y");
    feed(&mut t, "\x1b[?2027h");
    assert_eq!(query(&mut t), "\x1b[?2027;1$y");
    // A reset returns the mode to the host's method.
    feed(&mut t, "\x1bc");
    assert_eq!(query(&mut t), "\x1b[?2027;2$y");
    assert_eq!(
        t.fresh_keeping_host_config().grapheme_width_method(),
        GraphemeWidthMethod::Legacy
    );
}

#[test]
fn a_checkpoint_keeps_the_clusters_and_the_importing_hosts_method() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "q\u{0301}\u{1F44D}\u{1F3FD}");
    let import = |blob: &[u8]| {
        let mut restored = Terminal::new(10, 2);
        restored.set_grapheme_width_method(GraphemeWidthMethod::Legacy);
        restored.import_checkpoint(blob).unwrap();
        restored
    };
    let restored = import(&t.export_checkpoint().unwrap());
    assert_eq!(restored.plain_string(), "q\u{0301}\u{1F44D}\u{1F3FD}");
    assert_eq!(
        restored.grapheme_width_method(),
        GraphemeWidthMethod::Legacy
    );
    // Version 2 has nowhere to put them: each cell keeps its first character.
    let v2 = import(&t.export_checkpoint_version(2, 0).unwrap());
    assert_eq!(v2.plain_string(), "q\u{1F44D}");
}

#[test]
fn zero_width_codepoints_with_nothing_to_join_are_dropped() {
    let mut t = Terminal::new(10, 2);
    // A joiner at the start of a line, a mark after an erased cell and a
    // zero-width space after text all take no column and leave no text.
    feed(&mut t, "\u{200D}a\x1b[1;5H\u{0301}\x1b[1;2H\u{200B}b");
    assert_eq!(t.plain_string(), "ab");
    assert_eq!(t.cursor(), (0, 2));
}

#[test]
fn stacked_marks_stop_growing_a_cell_but_take_no_column() {
    let mut t = Terminal::new(10, 2);
    let marks: String = std::iter::repeat_n('\u{0336}', 1000).collect();
    feed(&mut t, &format!("z{marks}x"));
    assert_eq!(t.cursor(), (0, 2));
    let text = cell_text(&t, 0, 0);
    assert!(
        text.starts_with("z\u{0336}") && text.len() < 300,
        "{}",
        text.len()
    );
}

#[test]
fn ffi_cells_frames_and_text_carry_whole_clusters() {
    let core = TakoCore::new(10, 3);
    core.feed(
        "q\u{0301}x\u{1F44D}\u{1F3FD}\r\n\u{1F1FA}\u{1F1F8}"
            .as_bytes()
            .to_vec(),
    );

    let cell = core.get_cell(0, 0).unwrap();
    assert_eq!(cell.ch, u32::from('q'));
    assert_eq!(cell.grapheme.as_deref(), Some("q\u{0301}"));
    assert_eq!(core.get_cell(0, 1).unwrap().grapheme, None);
    let row = core.viewport_row(0);
    assert_eq!(row[2].grapheme.as_deref(), Some("\u{1F44D}\u{1F3FD}"));
    assert_eq!(row[3].grapheme, None);

    let bits = |packed: &[u8], row: usize, col: usize| {
        let at = (row * 10 + col) * PACKED_CELL_SIZE + 10;
        u16::from_le_bytes([packed[at], packed[at + 1]])
    };
    let frame = core.render_frame();
    assert_eq!(frame.packed_cells.len(), 10 * 3 * PACKED_CELL_SIZE);
    assert_ne!(bits(&frame.packed_cells, 0, 0) & PACKED_GRAPHEME, 0);
    assert_eq!(bits(&frame.packed_cells, 0, 1) & PACKED_GRAPHEME, 0);
    let texts: Vec<(u32, u32, &str)> = frame
        .graphemes
        .iter()
        .map(|g| (g.row, g.col, g.text.as_str()))
        .collect();
    assert_eq!(
        texts,
        [
            (0, 0, "q\u{0301}"),
            (0, 2, "\u{1F44D}\u{1F3FD}"),
            (1, 0, "\u{1F1FA}\u{1F1F8}")
        ]
    );
    assert_eq!(core.viewport_graphemes(), frame.graphemes);
    assert_eq!(core.viewport_packed(), frame.packed_cells);
    assert_eq!(core.render_frame_overscan(1).graphemes, frame.graphemes);

    // A delta names rows by their place in its payload.
    let first = core.render_frame_delta(0);
    core.feed("\x1b[3;1H\u{0336}z\u{0336}".as_bytes().to_vec());
    let delta = core.render_frame_delta(first.frame_version);
    assert_eq!(delta.row_indices, [2]);
    let texts: Vec<(u32, u32, &str)> = delta
        .graphemes
        .iter()
        .map(|g| (g.row, g.col, g.text.as_str()))
        .collect();
    assert_eq!(texts, [(0, 0, "z\u{0336}")]);

    // A wide pair's spacer reads as a space here.
    assert_eq!(
        core.get_line(0).trim_end_matches('\0'),
        "q\u{0301}x\u{1F44D}\u{1F3FD} "
    );
    assert_eq!(
        core.get_plain_text(0, 3),
        "q\u{0301}x\u{1F44D}\u{1F3FD}\n\u{1F1FA}\u{1F1F8}\nz\u{0336}"
    );
    assert!(
        core.buffer_text()
            .starts_with("q\u{0301}x\u{1F44D}\u{1F3FD}\n")
    );
    core.start_selection(0, 0, FfiSelectionMode::Linear);
    core.extend_selection(0, 9);
    assert_eq!(
        core.selected_text().unwrap(),
        "q\u{0301}x\u{1F44D}\u{1F3FD}"
    );

    core.set_grapheme_width_method(FfiGraphemeWidthMethod::Legacy);
    core.feed(b"\x1b[3;1H\x1b[2K\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd".to_vec());
    assert_eq!(core.cursor_col(), 4);
    core.set_grapheme_width_method(FfiGraphemeWidthMethod::Unicode);
    core.feed(b"\x1b[3;1H\x1b[2K\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd".to_vec());
    assert_eq!(core.cursor_col(), 2);
}
