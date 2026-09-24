// Tests revived from SKIPPED status after their blocking APIs were
// implemented (answerback, xtversion/scheme/pixel-size host config,
// plain_string_unwrapped, G2/G3 + single shifts, progress events).
// Each is a 1:1 port of the named upstream test.

use tako_core::terminal::{Terminal, TerminalEvent};

/// Upstream (`stream_terminal`): "enquiry with effect"
#[test]
fn enquiry_with_effect() {
    let mut term = Terminal::new(80, 24);
    term.set_answerback("tako");
    term.feed(b"\x05");
    assert_eq!(term.take_output(), b"tako".to_vec());
}

/// Upstream (`stream_terminal`): "enquiry with empty response"
#[test]
fn enquiry_with_empty_response() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x05");
    assert_eq!(term.take_output(), b"".to_vec());
}

/// Upstream (`stream_terminal`): "xtversion with effect"
#[test]
fn xtversion_with_effect() {
    let mut term = Terminal::new(80, 24);
    term.set_xtversion("tako 1.2.3");
    term.feed(b"\x1b[>0q");
    assert_eq!(term.take_output(), b"\x1bP>|tako 1.2.3\x1b\\".to_vec());
}

/// Upstream (`stream_terminal`): "xtversion with empty string effect"
#[test]
fn xtversion_with_empty_string_effect() {
    let mut term = Terminal::new(80, 24);
    term.set_xtversion("");
    term.feed(b"\x1b[>0q");
    assert_eq!(term.take_output(), b"\x1bP>|tako\x1b\\".to_vec());
}

/// Upstream (`stream_terminal`): "size report csi_14_t with effect"
#[test]
fn size_report_csi_14_t() {
    let mut term = Terminal::new(80, 24);
    term.resize_with_cell_size(80, 24, 9, 18);
    term.feed(b"\x1b[14t");
    assert_eq!(term.take_output(), b"\x1b[4;432;720t".to_vec());
}

/// Upstream (`stream_terminal`): "size report csi_16_t with effect"
#[test]
fn size_report_csi_16_t() {
    let mut term = Terminal::new(80, 24);
    term.resize_with_cell_size(80, 24, 9, 18);
    term.feed(b"\x1b[16t");
    assert_eq!(term.take_output(), b"\x1b[6;18;9t".to_vec());
}

/// Upstream (`stream_terminal`): "size report csi_18_t with effect"
#[test]
fn size_report_csi_18_t() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[18t");
    assert_eq!(term.take_output(), b"\x1b[8;24;80t".to_vec());
}

/// Upstream (`stream_terminal`): "device status: color scheme dark"
#[test]
fn device_status_color_scheme_dark() {
    let mut term = Terminal::new(80, 24);
    term.set_dark_scheme(true);
    term.feed(b"\x1b[?996n");
    assert_eq!(term.take_output(), b"\x1b[?997;2n".to_vec());
}

/// Upstream (`stream_terminal`): "device status: color scheme light"
#[test]
fn device_status_color_scheme_light() {
    let mut term = Terminal::new(80, 24);
    term.set_dark_scheme(false);
    term.feed(b"\x1b[?996n");
    assert_eq!(term.take_output(), b"\x1b[?997;1n".to_vec());
}

/// Upstream (`stream_terminal`): "progress_report effect callback" --
/// including the split-feed chunking the upstream test exercises.
#[test]
fn progress_report_events() {
    let mut term = Terminal::new(80, 24);
    let cases: &[(&[u8], u8, Option<u8>)] = &[
        (b"\x1b]9;4;0\x1b\\", 0, None),
        (b"\x1b]9;4;1;25\x1b\\", 1, Some(25)),
        (b"\x1b]9;4;2;50\x1b\\", 2, Some(50)),
        (b"\x1b]9;4;3\x1b\\", 3, None),
        (b"\x1b]9;4;4;75\x1b\\", 4, Some(75)),
    ];
    for (seq, state, value) in cases {
        let mid = seq.len() / 2;
        term.feed(&seq[..mid]);
        assert!(term.take_events().is_empty());
        term.feed(&seq[mid..]);
        assert_eq!(
            term.take_events(),
            vec![TerminalEvent::Progress { state: *state, value: *value }]
        );
    }
}

/// Upstream test: "Terminal: resize preserves pixel dimensions when omitted"
#[test]
fn resize_preserves_pixel_dimensions_when_omitted() {
    let mut term = Terminal::new(10, 5);
    term.resize_with_cell_size(10, 5, 9, 18);
    term.resize(20, 10);
    assert_eq!(term.pixel_size(), (90, 90));
}

/// Upstream test: "Terminal: resize updates pixels without changing cell dimensions"
#[test]
fn resize_updates_pixels_without_changing_cell_dimensions() {
    let mut term = Terminal::new(10, 5);
    term.resize_with_cell_size(10, 5, 9, 18);
    assert_eq!(term.pixel_size(), (90, 90));
}

/// Upstream test: "Terminal: resize pixel dimensions saturate"
#[test]
fn resize_pixel_dimensions_saturate() {
    let mut term = Terminal::new(2, 3);
    term.resize_with_cell_size(2, 3, u32::MAX, u32::MAX);
    assert_eq!(term.pixel_size(), (u32::MAX, u32::MAX));
}

/// Upstream test: "Terminal: setTitle accepts its current value"
#[test]
fn set_title_accepts_its_current_value() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"\x1b]2;same\x1b\\");
    term.feed(b"\x1b]2;same\x1b\\");
    assert_eq!(term.title(), "same");
}

/// Upstream test: "Terminal: print charset" -- G1/G2/G3 designation must not
/// affect GL printing; G0 designation must.
#[test]
fn print_charset_g1_g2_g3_do_not_affect_gl() {
    let mut term = Terminal::new(80, 5);
    term.feed(b"\x1b)0\x1b*0\x1b+0"); // G1/G2/G3 = DEC special
    term.feed(b"`");
    term.feed(b"\x1b(B`"); // G0 = ascii
    term.feed(b"\x1b(0`"); // G0 = DEC special
    assert_eq!(term.plain_string(), "``\u{25C6}");
}

/// Upstream test: "Terminal: print charset outside of ASCII"
#[test]
fn print_charset_outside_of_ascii() {
    let mut term = Terminal::new(80, 5);
    term.feed(b"\x1b)0\x1b*0\x1b+0");
    term.feed(b"\x1b(0"); // G0 = DEC special
    term.feed(b"`");
    term.feed("\u{1F600}".as_bytes()); // outside ASCII: unmapped
    assert_eq!(term.plain_string(), "\u{25C6}");
}

/// Upstream test: "Terminal: print invoke charset single" -- SS2 applies G2 to
/// exactly one glyph.
#[test]
fn print_invoke_charset_single() {
    let mut term = Terminal::new(80, 5);
    term.feed(b"\x1b*0"); // G2 = DEC special
    term.feed(b"`");
    term.feed(b"\x1bN`"); // SS2 + '`' -> diamond
    term.feed(b"`");
    assert_eq!(term.plain_string(), "`\u{25C6}`");
}

/// Upstream test: "Terminal: saveCursor" -- bold + GR slot + origin mode all
/// round-trip through DECSC/DECRC.
#[test]
fn save_cursor_round_trips_gr_slot() {
    let mut term = Terminal::new(3, 3);
    term.feed(b"\x1b[1m"); // bold
    term.feed(b"\x1b|"); // LS3R: GR = G3
    term.feed(b"\x1b[?6h"); // origin mode
    term.feed(b"\x1b7");
    term.feed(b"\x1b}"); // GR = G2
    term.feed(b"\x1b[0m");
    term.feed(b"\x1b[?6l");
    term.feed(b"\x1b8");
    term.feed(b"X");
    let cell = term.active_grid().get(0, 0).unwrap();
    assert!(cell.attrs.contains(tako_core::grid::CellAttrs::BOLD));
    assert!(term.modes().origin_mode);
    assert_eq!(term.gr_slot(), 3);
}


/// Upstream test: "Terminal: print writes to bottom if scrolled"
#[test]
fn print_writes_to_bottom_if_scrolled() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"hello");
    term.feed(b"\x1b[1;1H");
    // Three indexes push "hello" off the screen into scrollback.
    term.feed(b"\x1bD\x1bD\x1bD");
    assert_eq!(term.plain_string(), "");

    // Scroll the viewport to the top: the scrollback line is visible.
    term.scroll_viewport_up(usize::MAX);
    assert_eq!(term.plain_string(), "hello");

    // Typing snaps back to the live screen and writes there.
    term.feed(b"A");
    term.scroll_viewport_bottom();
    assert_eq!(term.plain_string(), "\nA");
}

/// Viewport scrolling exposes scrollback rows and clamps at both ends.
#[test]
fn viewport_scroll_clamps_and_reads_scrollback() {
    let mut term = Terminal::new(4, 2);
    term.feed(b"aaaa\r\nbbbb\r\ncccc\r\ndddd");
    assert!(term.active_grid().scrollback_len() >= 2);

    term.scroll_viewport_up(1);
    assert_eq!(term.viewport_offset(), 1);
    let row0: String = term.viewport_row(0).iter().map(|c| c.char).collect();
    assert_eq!(row0, "bbbb");

    term.scroll_viewport_up(1000); // clamps to available scrollback
    assert_eq!(term.viewport_offset(), term.active_grid().scrollback_len());

    term.scroll_viewport_down(1000);
    assert_eq!(term.viewport_offset(), 0);
}
