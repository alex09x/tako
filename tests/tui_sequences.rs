// What full-screen programs rely on. A modern TUI renderer keeps a buffer of
// cells and sends only the difference between frames, picking the cheapest
// sequence for each change: erase or repeat characters, insert or delete
// them, scroll a region, move by tab stops. It assumes an erase fills with
// the current background, and it asks the terminal what it supports before
// it draws. One test per thing, so a regression names what broke.

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// A terminal set up the way the apps set one up: colours, cell size and a
/// colour scheme, so the queries that report them have something to say.
fn term() -> Terminal {
    let mut t = Terminal::new(20, 6);
    t.set_base_colors(Some((0xec, 0xe6, 0xe1)), Some((0x14, 0x10, 0x0e)), Some((0xf0, 0x60, 0x28)), &[]);
    t.resize_with_cell_size(20, 6, 8, 16);
    t.set_dark_scheme(true);
    t
}

fn fed(bytes: &[u8]) -> Terminal {
    let mut t = term();
    t.feed(bytes);
    t
}

fn row(t: &Terminal, r: usize) -> String {
    let text: String = t
        .viewport_row(r)
        .iter()
        .filter(|c| !c.is_wide_spacer)
        .map(|c| if c.char == '\0' { ' ' } else { c.char })
        .collect();
    text.trim_end().to_string()
}

fn rows(t: &Terminal, n: usize) -> Vec<String> {
    (0..n).map(|r| row(t, r)).collect()
}

fn reply(bytes: &[u8]) -> String {
    let mut t = term();
    t.feed(bytes);
    String::from_utf8(t.take_output()).unwrap()
}

fn reply_of(t: &mut Terminal, bytes: &[u8]) -> String {
    t.feed(bytes);
    String::from_utf8(t.take_output()).unwrap()
}

fn bg(t: &Terminal, r: usize, c: usize) -> Color {
    t.viewport_row(r)[c].bg
}

// --- Editing a row in place ---

#[test]
fn erase_character_blanks_in_place_and_leaves_the_cursor() {
    let t = fed(b"abcdef\r\x1b[3X");
    assert_eq!(row(&t, 0), "   def");
    assert_eq!(t.cursor(), (0, 0));
}

#[test]
fn insert_character_pushes_the_rest_right() {
    assert_eq!(row(&fed(b"abcdef\r\x1b[2@"), 0), "  abcdef");
}

#[test]
fn delete_character_pulls_the_rest_left() {
    assert_eq!(row(&fed(b"abcdef\r\x1b[2P"), 0), "cdef");
}

#[test]
fn repeat_prints_the_last_character_again() {
    assert_eq!(row(&fed(b"a\x1b[3b"), 0), "aaaa");
}

#[test]
fn insert_mode_pushes_text_right_as_it_prints() {
    assert_eq!(row(&fed(b"abc\r\x1b[4hX\x1b[4l"), 0), "Xabc");
}

// --- Moving blocks of lines ---

#[test]
fn scroll_up_moves_everything_up_a_line() {
    assert_eq!(rows(&fed(b"1\r\n2\r\n3\x1b[S"), 2), ["2", "3"]);
}

#[test]
fn scroll_down_moves_everything_down_a_line() {
    assert_eq!(rows(&fed(b"1\r\n2\x1b[T"), 3), ["", "1", "2"]);
}

#[test]
fn a_region_scroll_leaves_the_lines_outside_it_alone() {
    let t = fed(b"top\x1b[2;4r\x1b[2;1H2\r\n3\r\n4\x1b[6;1Hbottom\x1b[S");
    assert_eq!(rows(&t, 6), ["top", "3", "4", "", "", "bottom"]);
}

#[test]
fn reverse_index_at_the_top_margin_scrolls_the_region_down() {
    let t = fed(b"\x1b[2;4r\x1b[2;1HA\x1bM");
    assert_eq!(rows(&t, 4), ["", "", "A", ""]);
}

#[test]
fn insert_line_opens_a_blank_line_at_the_cursor() {
    assert_eq!(rows(&fed(b"1\r\n2\r\n3\x1b[2;1H\x1b[L"), 4), ["1", "", "2", "3"]);
}

// --- Moving the cursor ---

#[test]
fn tab_moves_forward_and_back_by_stops() {
    assert_eq!(fed(b"\x1b[2I").cursor(), (0, 16), "CHT");
    assert_eq!(fed(b"\x1b[12G\x1b[Z").cursor(), (0, 8), "CBT");
}

#[test]
fn position_absolute_and_relative_move_like_cha_cuf_and_cud() {
    assert_eq!(fed(b"\x1b[5`").cursor(), (0, 4), "HPA");
    assert_eq!(fed(b"\x1b[2G\x1b[3a").cursor(), (0, 4), "HPR");
    assert_eq!(fed(b"\x1b[2;1H\x1b[2e").cursor(), (3, 0), "VPR");
    assert_eq!(fed(b"\x1b[3d").cursor(), (2, 0), "VPA");
}

#[test]
fn relative_moves_stop_at_the_edge_like_the_moves_they_alias() {
    assert_eq!(fed(b"\x1b[99a").cursor(), (0, 19), "HPR");
    assert_eq!(fed(b"\x1b[99e").cursor(), (5, 0), "VPR");
}

#[test]
fn tab_stops_every_eight_columns_come_back_on_request() {
    // A program that cleared every stop, then asked for the default set:
    // the next tab lands on column 8 again, not at the edge.
    assert_eq!(fed(b"\x1b[3g\x1b[?5W\t").cursor(), (0, 8), "CSI ? 5 W");
    assert_eq!(fed(b"\x1b[3g\x1b[?W\t").cursor(), (0, 8), "CSI ? W");
    assert_eq!(fed(b"\x1b[3g\x1b[?4W\t").cursor(), (0, 19), "another parameter is not a reset");
}

// --- Erasing with the current background ---

#[test]
fn every_erase_fills_with_the_current_background() {
    assert_eq!(bg(&fed(b"\x1b[44m\x1b[2J"), 3, 3), Color::Indexed(4), "ED");
    assert_eq!(bg(&fed(b"abc\r\x1b[41m\x1b[K"), 0, 10), Color::Indexed(1), "EL");
    assert_eq!(bg(&fed(b"abc\r\x1b[42m\x1b[2X"), 0, 0), Color::Indexed(2), "ECH");
    assert_eq!(bg(&fed(b"1\r\n2\x1b[1;1H\x1b[43m\x1b[L"), 0, 5), Color::Indexed(3), "IL");
    assert_eq!(bg(&fed(b"1\r\n2\x1b[45m\x1b[S"), 5, 5), Color::Indexed(5), "SU");
    assert_eq!(bg(&fed(b"abc\r\x1b[46m\x1b[2@"), 0, 0), Color::Indexed(6), "ICH");
    assert_eq!(bg(&fed(b"abc\r\x1b[46m\x1b[2P"), 0, 19), Color::Indexed(6), "DCH");
}

// --- What a program asks before it draws ---

#[test]
fn mode_requests_report_each_mode() {
    assert_eq!(reply(b"\x1b[?2026$p"), "\x1b[?2026;2$y", "synchronized output");
    assert_eq!(reply(b"\x1b[?2027$p"), "\x1b[?2027;1$y", "grapheme clustering");
    assert_eq!(reply(b"\x1b[?2004$p"), "\x1b[?2004;2$y", "bracketed paste");
    assert_eq!(reply(b"\x1b[?9999$p"), "\x1b[?9999;0$y", "unknown");
    assert_eq!(reply(b"\x1b[4$p"), "\x1b[4;2$y", "ANSI insert mode");
}

#[test]
fn the_terminal_says_what_it_is() {
    assert_eq!(reply(b"\x1b[>0q"), "\x1bP>|tako\x1b\\", "XTVERSION");
    assert!(reply(b"\x1b[c").starts_with("\x1b[?"), "DA1");
    assert!(reply(b"\x1b[>c").starts_with("\x1b[>"), "DA2");
    // XTGETTCAP TN: the terminal's name, hex-encoded.
    assert_eq!(reply(b"\x1bP+q544e\x1b\\"), "\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\");
}

#[test]
fn keyboard_flags_push_pop_and_report() {
    assert_eq!(reply(b"\x1b[?u"), "\x1b[?0u");
    assert_eq!(reply(b"\x1b[>11u\x1b[?u"), "\x1b[?11u");
    assert_eq!(reply(b"\x1b[>11u\x1b[<u\x1b[?u"), "\x1b[?0u");
}

#[test]
fn colour_queries_answer_with_the_hosts_colours() {
    assert_eq!(reply(b"\x1b]11;?\x07"), "\x1b]11;rgb:1414/1010/0e0e\x07", "background, BEL");
    assert_eq!(reply(b"\x1b]10;?\x1b\\"), "\x1b]10;rgb:ecec/e6e6/e1e1\x1b\\", "foreground, ST");
    assert!(reply(b"\x1b]12;?\x07").starts_with("\x1b]12;rgb:f0f0/6060/2828"), "cursor");
    assert!(reply(b"\x1b]4;1;?\x07").starts_with("\x1b]4;1;rgb:"), "palette");
}

#[test]
fn colour_queries_stay_silent_before_the_host_sets_colours() {
    // A program then falls back to its own guess instead of being told a
    // colour the window does not have.
    let mut t = Terminal::new(20, 6);
    t.feed(b"\x1b]11;?\x07\x1b]10;?\x07");
    assert!(t.take_output().is_empty());
}

#[test]
fn size_reports_use_the_hosts_cell_size() {
    assert_eq!(reply(b"\x1b[18t"), "\x1b[8;6;20t", "text area in cells");
    assert_eq!(reply(b"\x1b[16t"), "\x1b[6;16;8t", "cell in pixels");
    assert_eq!(reply(b"\x1b[14t"), "\x1b[4;96;160t", "text area in pixels");
}

#[test]
fn the_colour_scheme_is_reported() {
    assert_eq!(reply(b"\x1b[?996n"), "\x1b[?997;1n", "dark");
    let mut t = term();
    t.set_dark_scheme(false);
    t.feed(b"\x1b[?996n");
    assert_eq!(t.take_output(), b"\x1b[?997;2n", "light");
}

#[test]
fn a_program_that_set_mode_2031_is_told_when_the_scheme_changes() {
    let mut t = term();
    t.feed(b"\x1b[?2031h");
    assert_eq!(reply_of(&mut t, b"\x1b[?2031$p"), "\x1b[?2031;1$y");
    t.set_dark_scheme(false);
    assert_eq!(t.take_output(), b"\x1b[?997;2n", "turned light");
    t.set_dark_scheme(false);
    assert!(t.take_output().is_empty(), "no change, nothing to say");
    t.set_dark_scheme(true);
    assert_eq!(t.take_output(), b"\x1b[?997;1n", "turned dark");
}

#[test]
fn without_mode_2031_a_scheme_change_is_not_announced() {
    let mut t = term();
    t.set_dark_scheme(false);
    assert!(t.take_output().is_empty());
    assert_eq!(reply_of(&mut t, b"\x1b[?2031$p"), "\x1b[?2031;2$y");
}

#[test]
fn the_host_sets_the_scheme_through_the_core() {
    let core = tako_core::ffi::TakoCore::new(20, 4);
    core.feed(b"\x1b[?996n".to_vec());
    assert!(core.take_output().is_empty(), "silent until the host says");
    core.set_color_scheme(false);
    core.feed(b"\x1b[?996n".to_vec());
    assert_eq!(core.take_output(), b"\x1b[?997;2n");
    core.feed(b"\x1b[?2031h".to_vec());
    core.set_color_scheme(true);
    assert_eq!(core.take_output(), b"\x1b[?997;1n", "told when it turns dark");
}

#[test]
fn a_checkpoint_carries_mode_2031() {
    let t = fed(b"\x1b[?2031h");
    let restored = tako_core::terminal::checkpoint::import(&t.export_checkpoint().unwrap()).unwrap();
    assert!(restored.modes().color_scheme_updates);
}

// --- Cursor, styles, links and progress ---

#[test]
fn cursor_shape_and_colour_follow_the_program() {
    assert_eq!(format!("{:?}", fed(b"\x1b[5 q").cursor_style()), "CursorStyle { shape: Bar, blinking: true }");
    assert_eq!(reply(b"\x1b]12;#ff0000\x07\x1b]12;?\x07"), "\x1b]12;rgb:ffff/0000/0000\x07");
    assert!(reply(b"\x1b]12;#ff0000\x07\x1b]112\x07\x1b]12;?\x07").starts_with("\x1b]12;rgb:f0f0/6060/2828"), "OSC 112 restores the host's");
}

#[test]
fn curly_underline_keeps_its_own_colour() {
    let t = fed(b"\x1b[4:3m\x1b[58:2::255:0:0mU");
    let cell = &t.viewport_row(0)[0];
    assert_eq!(cell.underline_style, 3);
    assert_eq!(cell.underline_color, Color::Rgb(255, 0, 0));
}

#[test]
fn hyperlinks_attach_to_the_cells_they_cover() {
    let t = fed(b"\x1b]8;;https://example.com\x07L\x1b]8;;\x07M");
    let link = t.viewport_row(0)[0].hyperlink.and_then(|id| t.hyperlink_uri(id));
    assert_eq!(link, Some("https://example.com"));
    assert_eq!(t.viewport_row(0)[1].hyperlink, None);
}

#[test]
fn progress_reports_become_events() {
    let mut t = fed(b"\x1b]9;4;1;50\x07");
    assert_eq!(format!("{:?}", t.take_events()), "[Progress { state: 1, value: Some(50) }]");
}

#[test]
fn a_sequence_passed_through_tmux_still_arrives() {
    assert_eq!(fed(b"\x1bPtmux;\x1b\x1b]2;inner\x07\x1b\\").title(), "inner");
}

#[test]
fn the_clipboard_is_not_read_back_to_a_program() {
    // OSC 52 writes are honoured; a read would hand any program running in
    // the terminal whatever the user last copied, so it gets no answer.
    assert_eq!(reply(b"\x1b]52;c;?\x07"), "");
}
