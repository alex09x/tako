// Grapheme clusters: a cell keeps every codepoint of the cluster it shows,
// and the cluster follows the cell through every grid operation -- scrolling
// and scroll regions, erases, character and line insertion and deletion,
// reflow, scrollback, the alternate screen, and the wide-pair rules -- so text
// extraction returns it whole.

use tako_core::ffi::{FfiGraphemeWidthMethod, FfiSelectionMode, PACKED_CELL_SIZE, PACKED_GRAPHEME, TakoCore};
use tako_core::terminal::{GraphemeWidthMethod, SelectionMode, Terminal};

struct Kind {
    name: &'static str,
    text: &'static str,
    /// Columns under grapheme-width-method=unicode.
    width: usize,
    /// Columns under grapheme-width-method=legacy: each codepoint's wcwidth.
    legacy_width: usize,
}

const KINDS: &[Kind] = &[
    // Open e with a combining tilde: no precomposed form.
    Kind { name: "IPA", text: "\u{025B}\u{0303}", width: 1, legacy_width: 1 },
    // Shin with qamats and shin dot.
    Kind { name: "Hebrew points", text: "\u{05E9}\u{05B8}\u{05C1}", width: 1, legacy_width: 1 },
    // Ka with the spacing vowel sign i.
    Kind { name: "Devanagari sign", text: "\u{0915}\u{093F}", width: 1, legacy_width: 2 },
    Kind { name: "stacked marks", text: "z\u{0336}\u{0337}\u{0338}\u{0335}", width: 1, legacy_width: 1 },
    Kind { name: "variation selector", text: "\u{2764}\u{FE0F}", width: 2, legacy_width: 1 },
    Kind {
        name: "ZWJ sequence",
        text: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        width: 2,
        legacy_width: 6,
    },
    Kind { name: "skin tone", text: "\u{1F44D}\u{1F3FD}", width: 2, legacy_width: 4 },
    Kind { name: "flag", text: "\u{1F1FA}\u{1F1F8}", width: 2, legacy_width: 2 },
];

fn feed(t: &mut Terminal, s: &str) {
    t.feed(s.as_bytes());
}

/// The text of the cluster in `(row, col)`.
fn cell_text(t: &Terminal, row: usize, col: usize) -> String {
    let grid = t.active_grid();
    let cell = grid.get(row, col).unwrap();
    let mut out = String::new();
    grid.push_cell_text(&mut out, cell);
    out
}

/// One visible row as text, trailing blanks trimmed.
fn line(t: &Terminal, row: usize) -> String {
    t.dump_text().lines().nth(row).unwrap_or("").to_string()
}

fn for_each_kind(check: impl Fn(&Kind)) {
    for kind in KINDS {
        check(kind);
    }
}

#[test]
fn a_cluster_takes_one_cell_and_its_presentation_width() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("a{}b", k.text));
        assert_eq!(t.plain_string(), format!("a{}b", k.text), "{}", k.name);
        assert_eq!(t.cursor(), (0, 2 + k.width), "{}", k.name);
        assert_eq!(cell_text(&t, 0, 1), k.text, "{}", k.name);
        assert_eq!(t.active_grid().get(0, 2).unwrap().is_wide_spacer, k.width == 2, "{}", k.name);
    });
}

#[test]
fn legacy_width_sums_the_codepoints_and_keeps_the_text() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        t.set_grapheme_width_method(GraphemeWidthMethod::Legacy);
        feed(&mut t, k.text);
        assert_eq!(t.cursor(), (0, k.legacy_width), "{}", k.name);
        assert_eq!(t.plain_string(), k.text, "{}", k.name);
    });
}

#[test]
fn clusters_scroll_into_scrollback_and_back_into_view() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 3);
        feed(&mut t, &format!("{}\r\n1\r\n2\r\n3\r\n4", k.text));
        assert_eq!(t.active_grid().scrollback_len(), 2, "{}", k.name);
        assert!(t.buffer_text().starts_with(&format!("{}\n1\n", k.text)), "{}", k.name);
        t.scroll_viewport_up(2);
        assert_eq!(line(&t, 0), k.text, "{}", k.name);
    });
}

#[test]
fn clusters_move_with_full_width_scroll_regions() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 5);
        feed(&mut t, &format!("\x1b[2;4r\x1b[3;1H{}", k.text));
        feed(&mut t, "\x1b[S");
        assert_eq!(line(&t, 1), k.text, "{} after SU", k.name);
        assert_eq!(line(&t, 2), "", "{} after SU", k.name);
        feed(&mut t, "\x1b[2T");
        assert_eq!(line(&t, 3), k.text, "{} after SD", k.name);
        // Reverse index at the region's top scrolls it down once more,
        // pushing the cluster out through the bottom margin.
        feed(&mut t, "\x1b[2;1H\x1bM");
        assert!(!t.plain_string().contains(k.text), "{} after RI", k.name);
    });
}

#[test]
fn clusters_move_with_scroll_regions_inside_side_margins() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 5);
        feed(&mut t, &format!("\x1b[?69h\x1b[1;8s\x1b[2;4r\x1b[3;1H{}", k.text));
        feed(&mut t, "\x1b[S");
        assert_eq!(line(&t, 1), k.text, "{} after SU", k.name);
        feed(&mut t, "\x1b[T");
        assert_eq!(line(&t, 2), k.text, "{} after SD", k.name);
        assert_eq!(cell_text(&t, 2, 0), k.text, "{}", k.name);
    });
}

#[test]
fn erases_remove_the_whole_cluster() {
    for_each_kind(|k| {
        let w = k.width;
        let fresh = |s: &str| {
            let mut t = Terminal::new(20, 3);
            feed(&mut t, &format!("{}xyz", k.text));
            feed(&mut t, s);
            t
        };
        // EL 0 from the cluster, EL 1 through the column after it, EL 2.
        assert_eq!(fresh("\x1b[1;1H\x1b[K").plain_string(), "", "{} EL0", k.name);
        let el1 = fresh(&format!("\x1b[1;{}H\x1b[1K", w + 1)).plain_string();
        assert_eq!(el1, format!("{}yz", " ".repeat(w + 1)), "{} EL1", k.name);
        assert_eq!(fresh("\x1b[2K").plain_string(), "", "{} EL2", k.name);
        // ED 2 and ED 1.
        assert_eq!(fresh("\x1b[2J").plain_string(), "", "{} ED2", k.name);
        assert_eq!(fresh("\x1b[2;1H\x1b[1J").plain_string(), "", "{} ED1", k.name);
        // ECH over the cluster's columns, and ECH of one column on its spacer.
        let ech = fresh(&format!("\x1b[1;1H\x1b[{w}X")).plain_string();
        assert_eq!(ech, format!("{}xyz", " ".repeat(w)), "{} ECH", k.name);
        if w == 2 {
            let tail = fresh("\x1b[1;2H\x1b[X").plain_string();
            assert_eq!(tail, "  xyz", "{} ECH on the spacer", k.name);
        }
    });
}

#[test]
fn selective_erase_keeps_a_protected_cluster() {
    for_each_kind(|k| {
        for (erase, what) in [("\x1b[?2J", "DECSED"), ("\x1b[1;1H\x1b[?2K", "DECSEL")] {
            let mut t = Terminal::new(20, 2);
            feed(&mut t, &format!("\x1b[1\"q{}\x1b[0\"qab", k.text));
            feed(&mut t, erase);
            assert_eq!(t.plain_string(), k.text, "{} {what}", k.name);
            assert_eq!(cell_text(&t, 0, 0), k.text, "{} {what}", k.name);
        }
        // An unprotected cluster goes.
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("{}ab\x1b[?2J", k.text));
        assert_eq!(t.plain_string(), "", "{}", k.name);
    });
}

#[test]
fn inserted_and_deleted_characters_shift_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("x{}y\x1b[1;1H\x1b[2@", k.text));
        assert_eq!(t.plain_string(), format!("  x{}y", k.text), "{} ICH", k.name);
        assert_eq!(cell_text(&t, 0, 3), k.text, "{} ICH", k.name);
        feed(&mut t, "\x1b[2P");
        assert_eq!(t.plain_string(), format!("x{}y", k.text), "{} DCH", k.name);
        feed(&mut t, &format!("\x1b[1;2H\x1b[{}P", k.width));
        assert_eq!(t.plain_string(), "xy", "{} DCH of the cluster", k.name);
        // Insert mode shifts it like ICH.
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("y{}\x1b[1;1H\x1b[4hab", k.text));
        assert_eq!(t.plain_string(), format!("aby{}", k.text), "{} IRM", k.name);
    });
}

#[test]
fn inserted_and_deleted_lines_move_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 4);
        feed(&mut t, &format!("\x1b[2;1H{}\x1b[1;1H\x1b[L", k.text));
        assert_eq!(line(&t, 2), k.text, "{} IL", k.name);
        feed(&mut t, "\x1b[M");
        assert_eq!(line(&t, 1), k.text, "{} DL", k.name);
        feed(&mut t, "\x1b[2;1H\x1b[M");
        assert!(!t.plain_string().contains(k.text), "{} DL of its row", k.name);
        // With side margins IL/DL copy cells one by one.
        let mut t = Terminal::new(20, 4);
        feed(&mut t, &format!("\x1b[2;1H{}\x1b[?69h\x1b[1;10s\x1b[1;1H\x1b[L", k.text));
        assert_eq!(line(&t, 2), k.text, "{} IL in margins", k.name);
        feed(&mut t, "\x1b[M");
        assert_eq!(line(&t, 1), k.text, "{} DL in margins", k.name);
    });
}

#[test]
fn column_insertion_and_deletion_shift_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("x{}\x1b[1;1H\x1b['}}", k.text));
        assert_eq!(t.plain_string(), format!(" x{}", k.text), "{} DECIC", k.name);
        feed(&mut t, "\x1b['~");
        assert_eq!(t.plain_string(), format!("x{}", k.text), "{} DECDC", k.name);
    });
}

#[test]
fn reflow_carries_the_cluster_across_widths() {
    for_each_kind(|k| {
        let mut t = Terminal::new(7, 3);
        feed(&mut t, &format!("abcd{}ef", k.text));
        t.resize(20, 3);
        assert_eq!(t.plain_string(), format!("abcd{}ef", k.text), "{} widened", k.name);
        assert_eq!(cell_text(&t, 0, 4), k.text, "{} widened", k.name);
        t.resize(6, 3);
        assert!(t.buffer_text().starts_with(&format!("abcd{}ef\n", k.text)), "{} narrowed", k.name);
        t.resize(7, 3);
        assert_eq!(cell_text(&t, 0, 4), k.text, "{} restored", k.name);
    });
}

#[test]
fn row_resizes_move_the_cluster_through_scrollback() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 4);
        feed(&mut t, &format!("{}\r\n1\r\n2\r\n3", k.text));
        t.resize(10, 2);
        assert_eq!(t.plain_string(), "2\n3", "{} shrunk", k.name);
        assert!(t.buffer_text().starts_with(&format!("{}\n", k.text)), "{} shrunk", k.name);
        t.resize(10, 4);
        assert_eq!(line(&t, 0), k.text, "{} grown back", k.name);
        // Without wraparound, a resize truncates rather than reflows.
        let mut t = Terminal::new(10, 2);
        feed(&mut t, &format!("\x1b[?7l{}x", k.text));
        t.resize(3, 2);
        assert_eq!(t.plain_string(), format!("{}x", k.text), "{} no reflow", k.name);
    });
}

#[test]
fn the_alternate_screen_keeps_its_own_clusters() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 3);
        feed(&mut t, &format!("{}\x1b[?1049h", k.text));
        assert_eq!(t.plain_string(), "", "{}", k.name);
        feed(&mut t, &format!("\x1b[H{}!", k.text));
        assert_eq!(t.plain_string(), format!("{}!", k.text), "{} alternate", k.name);
        feed(&mut t, "\x1b[?1049l");
        assert_eq!(t.plain_string(), k.text, "{} primary", k.name);
        feed(&mut t, "\x1b[?1049h");
        assert_eq!(t.plain_string(), "", "{} alternate cleared", k.name);
    });
}

#[test]
fn overwriting_either_half_replaces_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 2);
        feed(&mut t, &format!("{}y\x1b[1;1Hx", k.text));
        let expected = if k.width == 2 { "x y" } else { "xy" };
        assert_eq!(t.plain_string(), expected, "{} head", k.name);
        assert_eq!(t.active_grid().get(0, 0).unwrap().grapheme, 0, "{} head", k.name);
        if k.width == 2 {
            let mut t = Terminal::new(10, 2);
            feed(&mut t, &format!("{}y\x1b[1;2Hx", k.text));
            assert_eq!(t.plain_string(), " xy", "{} spacer", k.name);
            // Inserting inside the pair splits it: nothing half-drawn stays.
            let mut t = Terminal::new(10, 2);
            feed(&mut t, &format!("{}y\x1b[1;2H\x1b[@", k.text));
            assert_eq!(t.plain_string(), "   y", "{} ICH on the spacer", k.name);
        }
    });
}

#[test]
fn a_wide_cluster_that_does_not_fit_wraps_whole() {
    for_each_kind(|k| {
        if k.width != 2 {
            return;
        }
        let mut t = Terminal::new(5, 3);
        feed(&mut t, &format!("abcd{}z", k.text));
        assert_eq!(line(&t, 0), "abcd", "{}", k.name);
        assert_eq!(line(&t, 1), format!("{}z", k.text), "{}", k.name);
        assert!(t.active_grid().get(0, 4).unwrap().is_wide_spacer_head, "{}", k.name);
        assert_eq!(t.cursor(), (1, 3), "{}", k.name);
        assert!(t.buffer_text().starts_with(&format!("abcd{}z\n", k.text)), "{}", k.name);
    });
}

#[test]
fn a_mark_after_a_wide_cluster_joins_its_head() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 2);
        feed(&mut t, &format!("{}\u{0301}x", k.text));
        assert_eq!(t.plain_string(), format!("{}\u{0301}x", k.text), "{}", k.name);
        assert_eq!(t.cursor(), (0, k.width + 1), "{}", k.name);
    });
}

#[test]
fn selection_copies_whole_clusters() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 3);
        feed(&mut t, &format!("a{}b\r\nc{}", k.text, k.text));
        t.start_selection(0, 0, SelectionMode::Linear);
        t.extend_selection(1, 9);
        assert_eq!(t.selected_text().unwrap(), format!("a{}b\nc{}", k.text, k.text), "{}", k.name);
        t.start_selection(0, 1, SelectionMode::Rectangular);
        t.extend_selection(1, 1 + k.width - 1);
        assert_eq!(t.selected_text().unwrap(), format!("{}\n{}", k.text, k.text), "{}", k.name);
        assert_eq!(t.plain_string_unwrapped(), format!("a{}b\nc{}", k.text, k.text), "{}", k.name);
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
    feed(&mut t, "\x1b[?7l\x1b[?69h\x1b[1;3s\x1b[1;3H\u{2764}\x1b[1;4H\u{FE0F}");
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
    assert_eq!(t.fresh_keeping_host_config().grapheme_width_method(), GraphemeWidthMethod::Legacy);
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
    assert_eq!(restored.grapheme_width_method(), GraphemeWidthMethod::Legacy);
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
    assert!(text.starts_with("z\u{0336}") && text.len() < 300, "{}", text.len());
}

#[test]
fn ffi_cells_frames_and_text_carry_whole_clusters() {
    let core = TakoCore::new(10, 3);
    core.feed("q\u{0301}x\u{1F44D}\u{1F3FD}\r\n\u{1F1FA}\u{1F1F8}".as_bytes().to_vec());

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
    let texts: Vec<(u32, u32, &str)> =
        frame.graphemes.iter().map(|g| (g.row, g.col, g.text.as_str())).collect();
    assert_eq!(
        texts,
        [(0, 0, "q\u{0301}"), (0, 2, "\u{1F44D}\u{1F3FD}"), (1, 0, "\u{1F1FA}\u{1F1F8}")]
    );
    assert_eq!(core.viewport_graphemes(), frame.graphemes);
    assert_eq!(core.viewport_packed(), frame.packed_cells);
    assert_eq!(core.render_frame_overscan(1).graphemes, frame.graphemes);

    // A delta names rows by their place in its payload.
    let first = core.render_frame_delta(0);
    core.feed("\x1b[3;1H\u{0336}z\u{0336}".as_bytes().to_vec());
    let delta = core.render_frame_delta(first.frame_version);
    assert_eq!(delta.row_indices, [2]);
    let texts: Vec<(u32, u32, &str)> =
        delta.graphemes.iter().map(|g| (g.row, g.col, g.text.as_str())).collect();
    assert_eq!(texts, [(0, 0, "z\u{0336}")]);

    // A wide pair's spacer reads as a space here.
    assert_eq!(core.get_line(0).trim_end_matches('\0'), "q\u{0301}x\u{1F44D}\u{1F3FD} ");
    assert_eq!(core.get_plain_text(0, 3), "q\u{0301}x\u{1F44D}\u{1F3FD}\n\u{1F1FA}\u{1F1F8}\nz\u{0336}");
    assert!(core.buffer_text().starts_with("q\u{0301}x\u{1F44D}\u{1F3FD}\n"));
    core.start_selection(0, 0, FfiSelectionMode::Linear);
    core.extend_selection(0, 9);
    assert_eq!(core.selected_text().unwrap(), "q\u{0301}x\u{1F44D}\u{1F3FD}");

    core.set_grapheme_width_method(FfiGraphemeWidthMethod::Legacy);
    core.feed(b"\x1b[3;1H\x1b[2K\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd".to_vec());
    assert_eq!(core.cursor_col(), 4);
    core.set_grapheme_width_method(FfiGraphemeWidthMethod::Unicode);
    core.feed(b"\x1b[3;1H\x1b[2K\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd".to_vec());
    assert_eq!(core.cursor_col(), 2);
}
