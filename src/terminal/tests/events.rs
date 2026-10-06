/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{CellAttrs, Color};
use crate::terminal::{ClipboardPolicy, Terminal, TerminalEvent};

#[test]
fn test_events_bell_title_clipboard_notify_pwd() {
    let mut term = Terminal::new(10, 3);
    term.set_clipboard_policy(ClipboardPolicy::ReadWrite);
    term.feed(b"\x07");
    term.feed(b"\x1b]0;hi\x07");
    term.feed(b"\x1b]52;c;aGVsbG8=\x07"); // base64 "hello"
    term.feed(b"\x1b]52;c;?\x07");
    term.feed(b"\x1b]9;ping\x07");
    term.feed(b"\x1b]777;notify;T;B\x07");
    term.feed(b"\x1b]7;file://host/tmp\x07");
    let events = term.take_events();
    assert_eq!(
        events,
        vec![
            TerminalEvent::Bell,
            TerminalEvent::TitleChanged("hi".into()),
            TerminalEvent::ClipboardSet("hello".into()),
            TerminalEvent::ClipboardQuery,
            TerminalEvent::Notification {
                title: String::new(),
                body: "ping".into()
            },
            TerminalEvent::Notification {
                title: "T".into(),
                body: "B".into()
            },
            TerminalEvent::PwdChanged("file://host/tmp".into()),
        ]
    );
    assert!(term.take_events().is_empty());
}

#[test]
fn test_osc10_11_set_and_query_default_colors() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]10;#ff8000\x07");
    term.feed(b"\x1b]11;rgb:00/11/22\x07");
    assert_eq!(term.default_colors().0, Some((255, 128, 0)));
    assert_eq!(term.default_colors().1, Some((0, 17, 34)));
    term.feed(b"\x1b]10;?\x07");
    // BEL-terminated query -> BEL-terminated reply (terminator mirrors).
    assert_eq!(
        term.take_output(),
        b"\x1b]10;rgb:ffff/8080/0000\x07".to_vec()
    );
    term.feed(b"\x1b]110\x07\x1b]111\x07");
    assert_eq!(term.default_colors().0, None);
    assert_eq!(term.default_colors().1, None);
}

#[test]
fn test_decrqm_reports_mode_state() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[?6$p");
    assert_eq!(term.take_output(), b"\x1b[?6;2$y".to_vec());
    term.feed(b"\x1b[?6h\x1b[?6$p");
    assert_eq!(term.take_output(), b"\x1b[?6;1$y".to_vec());
    term.feed(b"\x1b[4h\x1b[4$p");
    assert_eq!(term.take_output(), b"\x1b[4;1$y".to_vec());
    term.feed(b"\x1b[?9999$p");
    assert_eq!(term.take_output(), b"\x1b[?9999;0$y".to_vec());
}

#[test]
fn test_sgr_colon_underline_styles_and_color() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[4:3m\x1b[58:2::10:20:30mX");
    let cell = term.active_grid().get(0, 0).unwrap();
    assert!(cell.attrs.contains(CellAttrs::UNDERLINE));
    assert_eq!(cell.underline_style, 3);
    assert_eq!(cell.underline_color, Color::Rgb(10, 20, 30));
    term.feed(b"\x1b[59m\x1b[4:0mY");
    let cell = term.active_grid().get(0, 1).unwrap();
    assert!(!cell.attrs.contains(CellAttrs::UNDERLINE));
    assert_eq!(cell.underline_color, Color::Default);
}

#[test]
fn test_sgr_overline_and_double_underline() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[53m\x1b[21mX\x1b[55m\x1b[24mY");
    let x = term.active_grid().get(0, 0).unwrap();
    assert!(x.attrs.contains(CellAttrs::OVERLINE));
    assert_eq!(x.underline_style, 2);
    let y = term.active_grid().get(0, 1).unwrap();
    assert!(!y.attrs.contains(CellAttrs::OVERLINE));
    assert_eq!(y.underline_style, 0);
}

#[test]
fn test_legacy_semicolon_truecolor_still_works() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b[38;2;1;2;3m\x1b[48;5;20mZ");
    let z = term.active_grid().get(0, 0).unwrap();
    assert_eq!(z.fg, Color::Rgb(1, 2, 3));
    assert_eq!(z.bg, Color::Indexed(20));
}

#[test]
fn test_decic_decdc_insert_delete_columns() {
    let mut term = Terminal::new(6, 2);
    term.feed(b"ABCDEF\r\nabcdef");
    term.feed(b"\x1b[1;2H"); // col 1
    term.feed(b"\x1b[2'}"); // DECIC 2
    assert_eq!(term.plain_string(), "A  BCD\na  bcd");
    term.feed(b"\x1b[2'~"); // DECDC 2
    assert_eq!(term.plain_string(), "ABCD\nabcd");
}

#[test]
fn test_decbi_decfi_at_margins_shift_columns() {
    let mut term = Terminal::new(4, 2);
    term.feed(b"ABCD\r\nabcd");
    term.feed(b"\x1b[1;1H");
    term.feed(b"\x1b6"); // DECBI at left margin: shift right
    assert_eq!(term.plain_string(), " ABC\n abc");
    term.feed(b"\x1b[1;4H");
    term.feed(b"\x1b9"); // DECFI at right margin: shift left
    assert_eq!(term.plain_string(), "ABC\nabc");
}

#[test]
fn test_uk_charset_pound() {
    let mut term = Terminal::new(5, 2);
    term.feed(b"\x1b(A#\x1b(B#");
    assert_eq!(term.active_grid().get(0, 0).unwrap().char, '\u{00A3}');
    assert_eq!(term.active_grid().get(0, 1).unwrap().char, '#');
}

#[test]
fn test_damage_tracking_reports_only_changed_rows() {
    let mut term = Terminal::new(10, 4);
    term.take_damage(); // clear the initial full-damage state
    assert!(term.take_damage().is_empty());

    term.feed(b"\x1b[2;1Hhello"); // writes row 1 only
    assert_eq!(term.take_damage(), vec![1]);
    assert!(term.take_damage().is_empty());

    term.feed(b"\x1b[4;1Hx");
    assert_eq!(term.take_damage(), vec![3]);
}

#[test]
fn test_scroll_and_resize_damage_everything() {
    let mut term = Terminal::new(5, 3);
    term.take_damage();
    term.feed(b"\r\n\r\n\r\n\r\n"); // forces a scroll
    assert_eq!(term.take_damage(), vec![0, 1, 2]);

    term.take_damage();
    term.resize(8, 3);
    assert_eq!(term.take_damage(), vec![0, 1, 2]);
}

#[test]
fn test_mark_all_damaged_forces_full_redraw() {
    let mut term = Terminal::new(5, 3);
    term.feed(b"hi");
    let _ = term.take_damage();
    term.mark_all_damaged();
    assert_eq!(term.take_damage(), vec![0, 1, 2]);
}

#[test]
fn ios_surface_soft_wrap_accessibility_and_plain_text() {
    use crate::ffi::TakoCore;
    let handle = TakoCore::new(5, 4);
    // Print 5 chars to trigger pending wrap, then next char wrapped to row 1
    handle.feed(b"ABCDE".to_vec());
    handle.feed(b"FGH".to_vec());
    // Explicit newline to row 2
    handle.feed(b"\r\nIJ".to_vec());

    assert_eq!(handle.get_plain_text(0, 4), "ABCDEFGH\nIJ");

    // Test wide character wrap
    let handle_wide = TakoCore::new(4, 4);
    // 3 ASCII + 1 wide char ("界" wide) at col 3 cannot fit, so wraps to row 1
    handle_wide.feed("ABC界".as_bytes().to_vec());
    assert_eq!(handle_wide.get_plain_text(0, 4), "ABC界");

    // Accessibility follows the same scrolled viewport as the renderer,
    // including soft-wrap bits archived with history rows. Previously this
    // always read the live grid, so VoiceOver described text that was no
    // longer on screen after a finger scrolled into history.
    let scrolled = TakoCore::new(5, 2);
    scrolled.feed(b"ABCDEFGHIJKLMNOP".to_vec());
    assert_eq!(scrolled.get_plain_text(0, 2), "KLMNOP");
    scrolled.scroll_viewport_up(2);
    assert_eq!(scrolled.get_plain_text(0, 2), "ABCDEFGHIJ");
}

#[test]
fn ios_surface_soft_wrap_scrollback_eviction_boundary() {
    let mut term = Terminal::with_scrollback(5, 2, 2);
    // "ABCDE" -> row 0, "FGHIJ" -> row 1 (wrapped), "KLMNO" -> row 2 (wrapped), "PQRST" -> row 3 (wrapped)
    term.feed(b"ABCDEFGHIJKLMNOPQRST");
    assert_eq!(term.active_grid().scrollback_len(), 2);

    // Line 0 in scrollback (oldest remaining, abs 0) was old live row 0 (start of line) -> not wrapped
    assert!(!term.is_line_wrapped_abs(0));
    // Line 1 in scrollback (abs 1) was old live row 1 -> wrapped continuation of abs 0
    assert!(term.is_line_wrapped_abs(1));
    // Live row 0 (abs 2) -> wrapped continuation of abs 1
    assert!(term.is_line_wrapped_abs(2));
    // Live row 1 (abs 3) -> wrapped continuation of abs 2
    assert!(term.is_line_wrapped_abs(3));

    term.start_selection(0, 0, crate::terminal::SelectionMode::Linear);
    term.extend_selection(1, 4);
    assert_eq!(term.selected_text(), Some("KLMNOPQRST".to_string()));
}

#[test]
fn ios_surface_input_encoding_decomposed_grapheme_and_multi_scalar_emoji() {
    use crate::ffi::{FfiKey, FfiKeyEvent, TakoCore};

    let core = TakoCore::new(80, 24);

    // 1. Decomposed grapheme e + combining acute accent
    let bytes_decomposed = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "e\u{0301}".to_string(),
        physical_text: "e".to_string(),
        unshifted_text: "e".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_decomposed, "e\u{0301}".as_bytes());

    // 2. Multi-scalar ZWJ family emoji
    let bytes_emoji = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "👨‍👩‍👧‍👦".to_string(),
        physical_text: "👨".to_string(),
        unshifted_text: "👨".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_emoji, "👨‍👩‍👧‍👦".as_bytes());

    // 3. Multi-scalar flag emoji
    let bytes_flag = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "🇦🇺".to_string(),
        physical_text: "🇦".to_string(),
        unshifted_text: "🇦".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_flag, "🇦🇺".as_bytes());

    // 4. Negative assertion: Ctrl+C with text still emits C0 control byte (0x03)
    let bytes_ctrl = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "c".to_string(),
        physical_text: "c".to_string(),
        unshifted_text: "c".to_string(),
        shift: false,
        alt: false,
        ctrl: true,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_ctrl, vec![0x03]);

    // 5. Negative assertion: Alt+'e' with decomposed text emits ESC prefix (\x1be), not raw text
    let bytes_alt = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "e\u{0301}".to_string(),
        physical_text: "e".to_string(),
        unshifted_text: "e".to_string(),
        shift: false,
        alt: true,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_alt, vec![0x1b, b'e']);

    // 6. Negative assertion: Super+A with text emits empty bytes
    let bytes_super = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "a".to_string(),
        physical_text: "a".to_string(),
        unshifted_text: "a".to_string(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: true,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_super, Vec::<u8>::new());

    // 7. Negative assertion: Kitty keyboard protocol active -> Ctrl+A emits CSI u sequence, not text
    core.feed(b"\x1b[>1u".to_vec());
    let bytes_kitty = core.encode_key(FfiKeyEvent {
        key: FfiKey::Character,
        text: "a".to_string(),
        physical_text: "a".to_string(),
        unshifted_text: "a".to_string(),
        shift: false,
        alt: false,
        ctrl: true,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    });
    assert_eq!(bytes_kitty, b"\x1b[97;5u".to_vec());
}
