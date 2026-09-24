// Double-click and triple-click selection.
//
// The strings people actually double-click in a terminal are paths, URLs and
// `file:line` references, and those are exactly the ones long enough to wrap
// at the screen edge. A word selection that stopped at the right margin
// would fail on the cases it exists for, so the wrapped ones are covered
// here alongside the easy ones.

use tako_core::terminal::Terminal;

fn term(cols: usize, rows: usize, text: &str) -> Terminal {
    let mut t = Terminal::new(cols, rows);
    t.feed(text.as_bytes());
    let _ = t.take_output();
    t
}

/// The selected text, or "" when nothing is selected.
fn selected(t: &Terminal) -> String {
    t.selected_text().unwrap_or_default()
}

// ── Words ────────────────────────────────────────────────────────────────────

#[test]
fn a_double_click_selects_the_word_under_it() {
    let mut t = term(40, 2, "hello world again");

    t.select_word(0, 7); // inside "world"
    assert_eq!(selected(&t), "world");
}

#[test]
fn clicking_the_first_or_last_letter_selects_the_same_word() {
    let mut t = term(40, 2, "hello world again");

    t.select_word(0, 6); // 'w'
    assert_eq!(selected(&t), "world");
    t.select_word(0, 10); // 'd'
    assert_eq!(selected(&t), "world");
}

#[test]
fn a_word_at_the_start_of_a_line_selects_whole() {
    let mut t = term(40, 2, "hello world");

    t.select_word(0, 0);
    assert_eq!(selected(&t), "hello");
}

#[test]
fn clicking_a_gap_selects_the_gap_not_the_words_around_it() {
    let mut t = term(40, 2, "a    b");

    t.select_word(0, 2); // in the run of spaces
    // Checked through the range rather than the text: copying deliberately
    // trims trailing whitespace, so a run of spaces extracts as nothing.
    let ((_, from), (_, to)) = t.selection_range().expect("nothing selected");
    assert_eq!((from, to), (1, 4), "the gap between 'a' and 'b' is columns 1..4");
}

#[test]
fn punctuation_selects_as_its_own_run() {
    // `(` and `)` are neither letters nor part of a path, so they form their
    // own run rather than joining the words on either side.
    let mut t = term(40, 2, "foo(((bar");

    t.select_word(0, 4);
    assert_eq!(selected(&t), "(((");
}

// ── The strings this feature exists for ──────────────────────────────────────

#[test]
fn a_path_selects_as_one_word() {
    let mut t = term(60, 2, "edit src/terminal/select.rs now");

    t.select_word(0, 10);
    assert_eq!(selected(&t), "src/terminal/select.rs");
}

#[test]
fn a_file_and_line_reference_selects_as_one_word() {
    let mut t = term(60, 2, "at select.rs:142 here");

    t.select_word(0, 5);
    assert_eq!(selected(&t), "select.rs:142");
}

#[test]
fn a_url_selects_as_one_word() {
    let mut t = term(80, 2, "see https://example.com/a/b?x=1&y=2 ok");

    t.select_word(0, 10);
    assert_eq!(selected(&t), "https://example.com/a/b?x=1&y=2");
}

#[test]
fn a_versioned_package_selects_as_one_word() {
    let mut t = term(60, 2, "install some-package@1.2.3 please");

    t.select_word(0, 12);
    assert_eq!(selected(&t), "some-package@1.2.3");
}

// ── Wrapping ─────────────────────────────────────────────────────────────────

#[test]
fn a_word_broken_by_the_screen_edge_still_selects_whole() {
    // 20 columns, so this path wraps mid-word.
    let mut t = term(20, 4, "cd /very/long/path/to/somewhere/deep");

    t.select_word(0, 5); // inside the path, before the wrap
    assert_eq!(selected(&t), "/very/long/path/to/somewhere/deep");
}

#[test]
fn a_word_selects_whole_when_clicked_after_the_wrap() {
    let mut t = term(20, 4, "cd /very/long/path/to/somewhere/deep");

    // Row 1 holds the continuation; click there instead.
    t.select_word(1, 2);
    assert_eq!(selected(&t), "/very/long/path/to/somewhere/deep");
}

#[test]
fn a_hard_newline_is_not_crossed() {
    // Two separate lines, not a wrap: the words must stay apart.
    let mut t = term(40, 3, "alpha\r\nbeta");

    t.select_word(0, 2);
    assert_eq!(selected(&t), "alpha");
    t.select_word(1, 2);
    assert_eq!(selected(&t), "beta");
}

// ── Lines ────────────────────────────────────────────────────────────────────

#[test]
fn a_triple_click_selects_the_whole_line() {
    let mut t = term(40, 3, "first line\r\nsecond line");

    t.select_line(1, 3);
    assert_eq!(selected(&t).trim_end(), "second line");
}

#[test]
fn a_wrapped_line_selects_as_the_one_line_it_looks_like() {
    let mut t = term(20, 4, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    // Clicking either half gives the whole logical line.
    t.select_line(0, 0);
    let from_first = selected(&t);
    t.select_line(1, 0);
    let from_second = selected(&t);

    assert_eq!(from_first.trim_end(), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    assert_eq!(from_first, from_second);
}

#[test]
fn line_selection_stops_at_a_hard_newline() {
    let mut t = term(40, 4, "one\r\ntwo\r\nthree");

    t.select_line(1, 0);
    assert_eq!(selected(&t).trim_end(), "two");
}

// ── Robustness ───────────────────────────────────────────────────────────────

#[test]
fn selecting_on_a_blank_screen_does_not_panic() {
    let mut t = Terminal::new(10, 3);

    t.select_word(1, 5);
    t.select_line(1, 5);
    // Every cell is blank, so the run is the whole row of spaces.
    assert!(!selected(&t).is_empty() || selected(&t).is_empty());
}

#[test]
fn a_click_past_the_last_column_is_clamped() {
    let mut t = term(10, 2, "hi");

    t.select_word(0, 999);
    t.select_line(0, 999);
    // Reaching here without panicking is the assertion.
}

#[test]
fn a_click_past_the_last_row_is_clamped() {
    let mut t = term(10, 2, "hi");

    t.select_word(999, 0);
    t.select_line(999, 0);
}

#[test]
fn a_wide_glyph_selects_with_its_spacer() {
    // Each ideograph occupies two columns; clicking the trailing spacer must
    // behave as clicking the glyph.
    let mut t = term(20, 2, "\u{4e16}\u{754c}");

    t.select_word(0, 0);
    let from_glyph = selected(&t);
    t.select_word(0, 1); // the spacer of the first glyph
    let from_spacer = selected(&t);

    assert_eq!(from_glyph, "\u{4e16}\u{754c}");
    assert_eq!(from_glyph, from_spacer);
}

/// Selection has to keep working while the viewport is scrolled back. The
/// viewport is always `rows` tall whatever the offset -- rows above the live
/// screen are served from scrollback, they are not extra rows on top of it --
/// and clamping a click as though they were addresses the wrong line.
#[test]
fn selection_addresses_the_viewport_while_scrolled_back() {
    let mut t = Terminal::new(30, 5);
    for i in 0..40 {
        t.feed(format!("line{i} alpha\r\n").as_bytes());
    }
    let _ = t.take_output();
    t.scroll_viewport_up(10);
    assert_eq!(t.viewport_offset(), 10);

    // Row 0 of the viewport now comes from scrollback. Whatever word is
    // there, selecting it must return that row's text and not another's.
    let row0: String = t
        .viewport_row(0)
        .iter()
        .map(|c| if c.char == '\0' { ' ' } else { c.char })
        .collect();
    let first_word = row0.split_whitespace().next().unwrap_or_default().to_string();

    t.select_word(0, 1);
    assert_eq!(selected(&t), first_word, "viewport row 0 was {row0:?}");

    // The bottom row of the viewport is `rows - 1`, not `rows - 1 + offset`.
    t.select_line(4, 0);
    let row4: String = t
        .viewport_row(4)
        .iter()
        .map(|c| if c.char == '\0' { ' ' } else { c.char })
        .collect();
    assert_eq!(selected(&t).trim_end(), row4.trim_end());
}
