// Grid snapshot format.
//
// `dump()` is the foundation every golden test stands on: replaying a
// recorded PTY session is only useful if the resulting screen can be
// compared against an approved one and a mismatch says which row and column
// moved. These tests pin the format itself.

use tako_core::terminal::Terminal;

fn feed(term: &mut Terminal, data: &str) {
    term.feed(data.as_bytes());
    let _ = term.take_output();
}

// ── Plain text ───────────────────────────────────────────────────────────────

#[test]
fn text_dump_is_one_line_per_row_with_trailing_blanks_trimmed() {
    let mut t = Terminal::new(10, 3);
    feed(&mut t, "hi\r\nthere");

    assert_eq!(t.dump_text(), "hi\nthere\n");
}

#[test]
fn text_dump_keeps_interior_spaces_but_drops_trailing_ones() {
    let mut t = Terminal::new(10, 1);
    feed(&mut t, "a b   ");

    assert_eq!(t.dump_text(), "a b");
}

#[test]
fn text_dump_counts_a_wide_glyph_once() {
    let mut t = Terminal::new(10, 1);
    // A CJK ideograph occupies two columns; the second is a spacer cell that
    // renders nothing and must not appear as a character.
    feed(&mut t, "\u{4e16}\u{754c}x");

    assert_eq!(t.dump_text(), "\u{4e16}\u{754c}x");
}

#[test]
fn text_dump_is_stable_across_repeated_calls() {
    let mut t = Terminal::new(20, 4);
    feed(&mut t, "\x1b[31mred\x1b[m plain\r\nsecond");

    assert_eq!(t.dump_text(), t.dump_text());
    assert_eq!(t.dump(), t.dump());
}

// ── Header ───────────────────────────────────────────────────────────────────

#[test]
fn dump_header_reports_geometry_cursor_screen_and_offset() {
    let mut t = Terminal::new(10, 3);
    feed(&mut t, "hi");

    let dump = t.dump();
    let header = dump.lines().next().unwrap();
    assert_eq!(header, "10x3 cursor=(0,2) screen=primary offset=0");
}

#[test]
fn dump_header_marks_a_hidden_cursor() {
    let mut t = Terminal::new(10, 3);
    feed(&mut t, "\x1b[?25l");

    assert!(t.dump().lines().next().unwrap().contains("hidden"));
}

#[test]
fn dump_header_names_the_alternate_screen() {
    let mut t = Terminal::new(10, 3);
    feed(&mut t, "\x1b[?1049h");

    assert!(
        t.dump().lines().next().unwrap().contains("screen=alternate"),
        "alt screen not reported: {}",
        t.dump()
    );
}

#[test]
fn dump_header_reports_a_scrolled_viewport() {
    let mut t = Terminal::new(10, 3);
    for _ in 0..20 {
        feed(&mut t, "line\r\n");
    }
    t.scroll_viewport_up(5);

    assert!(t.dump().lines().next().unwrap().contains("offset=5"));
}

// ── Rows ─────────────────────────────────────────────────────────────────────

#[test]
fn dump_quotes_and_numbers_every_row_including_blank_ones() {
    let mut t = Terminal::new(10, 3);
    feed(&mut t, "hi");

    let dump = t.dump();
    let rows: Vec<&str> = dump.lines().skip(1).take(3).collect();
    assert_eq!(rows, vec!["0 \"hi\"", "1 \"\"", "2 \"\""]);
}

#[test]
fn dump_pads_row_numbers_so_they_stay_aligned() {
    let mut t = Terminal::new(4, 12);
    feed(&mut t, "x");

    let dump = t.dump();
    let rows: Vec<&str> = dump.lines().skip(1).take(12).collect();
    // Two-digit grid: single digits are right-aligned into the same column.
    assert_eq!(rows[0], " 0 \"x\"");
    assert_eq!(rows[11], "11 \"\"");
}

// ── Style runs ───────────────────────────────────────────────────────────────

#[test]
fn an_unstyled_screen_reports_no_styles() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "plain text");

    assert!(
        !t.dump().contains("styles"),
        "default cells should not be reported: {}",
        t.dump()
    );
}

#[test]
fn adjacent_cells_of_equal_style_collapse_into_one_run() {
    let mut t = Terminal::new(10, 1);
    feed(&mut t, "\x1b[1;31mbold\x1b[m");

    let dump = t.dump();
    let styles: Vec<&str> = dump
        .lines()
        .skip_while(|l| *l != "styles")
        .skip(1)
        .collect();
    assert_eq!(styles, vec!["0 0..4 bold fg=1"]);
}

#[test]
fn a_style_change_starts_a_new_run() {
    let mut t = Terminal::new(10, 1);
    feed(&mut t, "\x1b[31mab\x1b[32mcd\x1b[m");

    let dump = t.dump();
    let styles: Vec<&str> = dump
        .lines()
        .skip_while(|l| *l != "styles")
        .skip(1)
        .collect();
    assert_eq!(styles, vec!["0 0..2 fg=1", "0 2..4 fg=2"]);
}

#[test]
fn runs_never_span_two_rows() {
    let mut t = Terminal::new(4, 2);
    // Same style either side of the wrap: still two runs, one per row.
    feed(&mut t, "\x1b[44mabcdefgh\x1b[m");

    let dump = t.dump();
    let styles: Vec<&str> = dump
        .lines()
        .skip_while(|l| *l != "styles")
        .skip(1)
        .collect();
    assert_eq!(styles, vec!["0 0..4 bg=4", "1 0..4 bg=4"]);
}

#[test]
fn truecolor_is_reported_as_hex() {
    let mut t = Terminal::new(10, 1);
    feed(&mut t, "\x1b[38;2;255;128;0mx\x1b[m");

    assert!(
        t.dump().contains("fg=#ff8000"),
        "truecolor not reported as hex: {}",
        t.dump()
    );
}

#[test]
fn every_attribute_has_a_name_in_the_snapshot() {
    let mut t = Terminal::new(20, 1);
    // bold, dim, italic, underline, blink, reverse, strike, overline
    feed(&mut t, "\x1b[1;2;3;4;5;7;9;53mx\x1b[m");

    let dump = t.dump();
    for name in [
        "bold", "dim", "italic", "underline", "blink", "reverse", "strike", "overline",
    ] {
        assert!(dump.contains(name), "{name} missing from: {dump}");
    }
}

#[test]
fn curly_underline_and_its_color_are_reported() {
    let mut t = Terminal::new(10, 1);
    feed(&mut t, "\x1b[4:3m\x1b[58;2;255;0;0mx\x1b[m");

    let dump = t.dump();
    assert!(dump.contains("ul=curly"), "underline style missing: {dump}");
    assert!(
        dump.contains("ulcolor=#ff0000"),
        "underline color missing: {dump}"
    );
}

// ── Regression value ─────────────────────────────────────────────────────────

#[test]
fn a_snapshot_distinguishes_screens_that_share_their_text() {
    // The whole point of carrying styling: two screens with identical text
    // but different colour must not compare equal.
    let mut plain = Terminal::new(10, 1);
    feed(&mut plain, "hello");

    let mut colored = Terminal::new(10, 1);
    feed(&mut colored, "\x1b[31mhello\x1b[m");

    assert_eq!(plain.dump_text(), colored.dump_text());
    assert_ne!(plain.dump(), colored.dump());
}
