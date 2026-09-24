// Zero-width codepoints -- combining marks, joiners, variation selectors --
// belong to the character before them. Printing each into a column of its
// own shifted everything after it: macOS stores file names decomposed
// (NFD), so `ls` of a directory holding "café" put the rest of the line
// one column to the right of where the program meant it. Marks that have a
// precomposed form fold into their character (NFC); every other codepoint
// that continues a grapheme cluster joins its cell, and one that belongs to
// no cluster, like a zero-width space, takes no column and is dropped. See
// Terminal::join_previous_cluster, and tests/graphemes.rs for clusters
// crossing grid operations.

use tako_core::terminal::Terminal;

fn row(t: &Terminal, r: usize, n: usize) -> String {
    (0..n).map(|c| t.active_grid().get(r, c).unwrap().char).collect()
}

#[test]
fn a_combining_mark_composes_with_the_character_before_it() {
    let mut t = Terminal::new(20, 2);
    t.feed("cafe\u{0301}|".as_bytes());
    assert_eq!(row(&t, 0, 5), "caf\u{e9}|");
    assert_eq!(t.cursor(), (0, 5));
}

#[test]
fn decomposed_cyrillic_and_latin_compose_too() {
    let mut t = Terminal::new(20, 2);
    // й is и + U+0306, ё is е + U+0308, ñ is n + U+0303.
    t.feed("\u{0438}\u{0306}\u{0435}\u{0308}n\u{0303}.".as_bytes());
    assert_eq!(row(&t, 0, 4), "\u{0439}\u{0451}\u{f1}.");
    assert_eq!(t.cursor(), (0, 4));
}

#[test]
fn a_mark_with_no_composed_form_joins_the_cell_of_its_character() {
    // q has no precomposed form with a combining acute: the mark stays in
    // q's cell as part of its cluster, and takes no column.
    let mut t = Terminal::new(20, 2);
    t.feed("q\u{0301}x".as_bytes());
    assert_eq!(row(&t, 0, 2), "qx");
    assert_eq!(t.cursor(), (0, 2));
    let grid = t.active_grid();
    assert_eq!(grid.grapheme(grid.get(0, 0).unwrap()), "\u{0301}");
    assert_eq!(t.plain_string(), "q\u{0301}x");
}

#[test]
fn joiners_and_variation_selectors_take_no_column() {
    // The joiner and the selector continue the cluster before them and stay
    // in its cell; a zero-width space belongs to no cluster and is dropped.
    let mut t = Terminal::new(20, 2);
    t.feed("a\u{200b}b\u{200d}c\u{fe0f}d".as_bytes());
    assert_eq!(row(&t, 0, 4), "abcd");
    assert_eq!(t.cursor(), (0, 4));
    assert_eq!(t.plain_string(), "ab\u{200d}c\u{fe0f}d");
}

#[test]
fn a_mark_after_a_wide_character_attaches_to_it_not_its_spacer() {
    // Hiragana ka and the combining voiced mark make ga.
    let mut t = Terminal::new(20, 2);
    t.feed("\u{304b}\u{3099}x".as_bytes());
    assert_eq!(t.active_grid().get(0, 0).unwrap().char, '\u{304c}');
    assert!(t.active_grid().get(0, 1).unwrap().is_wide_spacer);
    assert_eq!(t.active_grid().get(0, 2).unwrap().char, 'x');
    assert_eq!(t.cursor(), (0, 3));
}

#[test]
fn a_mark_in_the_last_column_composes_before_the_deferred_wrap() {
    let mut t = Terminal::new(4, 2);
    t.feed("abce\u{0301}x".as_bytes());
    assert_eq!(row(&t, 0, 4), "abc\u{e9}");
    assert_eq!(row(&t, 1, 1), "x");
}

#[test]
fn a_joiner_at_the_start_of_a_line_is_dropped() {
    let mut t = Terminal::new(20, 2);
    t.feed("\u{200d}x".as_bytes());
    assert_eq!(row(&t, 0, 1), "x");
    assert_eq!(t.cursor(), (0, 1));
}
