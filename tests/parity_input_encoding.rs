// End-to-end checks that the input encoders are wired to live terminal
// state through the same paths the FFI layer uses.

use tako_core::key_encode::{encode as encode_key, EncodeConfig, Key, KeyEvent, Mods};
use tako_core::mouse_encode::{
    encode as encode_mouse, MouseAction, MouseButton, MouseEncoding, MouseEvent, MouseMods,
};
use tako_core::paste;
use tako_core::terminal::Terminal;

fn cfg(term: &Terminal) -> EncodeConfig {
    EncodeConfig {
        cursor_key_app_mode: term.modes().cursor_key_app_mode,
        keypad_app_mode: false,
        kitty_flags: term.kitty_keyboard_flags(),
        alt_esc_prefix: true,
        macos_option_as_alt: tako_core::key_encode::OptionAsAlt::False,
        backarrow_key_mode: false,
        modify_other_keys_state_2: false,
        ignore_keypad_with_numlock: false,
    }
}

fn key(k: Key) -> KeyEvent {
    KeyEvent {
        key: k,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    }
}

/// DECCKM switches the arrow keys between CSI and SS3 form, and the
/// encoder must follow the terminal's live mode.
#[test]
fn arrows_follow_live_deckm_mode() {
    let mut term = Terminal::new(20, 5);
    assert_eq!(encode_key(key(Key::Up), cfg(&term)), b"\x1b[A".to_vec());
    term.feed(b"\x1b[?1h"); // DECCKM on
    assert_eq!(encode_key(key(Key::Up), cfg(&term)), b"\x1bOA".to_vec());
    term.feed(b"\x1b[?1l");
    assert_eq!(encode_key(key(Key::Up), cfg(&term)), b"\x1b[A".to_vec());
}

/// Enabling the Kitty keyboard protocol changes the encoding of keys the
/// legacy scheme reports ambiguously.
#[test]
fn kitty_flags_change_key_encoding() {
    let mut term = Terminal::new(20, 5);
    assert_eq!(encode_key(key(Key::Escape), cfg(&term)), b"\x1b".to_vec());
    term.feed(b"\x1b[>1u"); // push DISAMBIGUATE
    assert_eq!(term.kitty_keyboard_flags(), 1);
    assert_eq!(encode_key(key(Key::Escape), cfg(&term)), b"\x1b[27u".to_vec());
    term.feed(b"\x1b[<1u"); // pop
    assert_eq!(encode_key(key(Key::Escape), cfg(&term)), b"\x1b".to_vec());
}

/// Mouse encoding follows the tracking/encoding modes the app enabled.
#[test]
fn mouse_encoding_follows_live_modes() {
    let mut term = Terminal::new(20, 5);
    let ev = MouseEvent {
        button: MouseButton::Left,
        action: MouseAction::Press,
        mods: MouseMods::default(),
        col: 0,
        row: 0,
    };
    // X10 by default.
    assert_eq!(
        encode_mouse(ev, MouseEncoding::X10).unwrap(),
        b"\x1b[M\x20\x21\x21".to_vec()
    );
    // With SGR (1006) the same event is textual and unbounded.
    term.feed(b"\x1b[?1000h\x1b[?1006h");
    assert!(term.modes().mouse_sgr);
    assert_eq!(
        encode_mouse(ev, MouseEncoding::Sgr).unwrap(),
        b"\x1b[<0;1;1M".to_vec()
    );
    // A coordinate X10 cannot represent has no encoding, but SGR does.
    let far = MouseEvent { col: 500, row: 500, ..ev };
    assert!(encode_mouse(far, MouseEncoding::X10).is_none());
    assert_eq!(
        encode_mouse(far, MouseEncoding::Sgr).unwrap(),
        b"\x1b[<0;501;501M".to_vec()
    );
}

/// Bracketed paste turns on with DEC mode 2004 and the terminator is
/// always stripped from hostile input.
#[test]
fn paste_brackets_follow_mode_2004() {
    let mut term = Terminal::new(20, 5);
    assert!(!term.modes().bracketed_paste);
    assert_eq!(paste::encode("hi", term.modes().bracketed_paste), b"hi".to_vec());

    term.feed(b"\x1b[?2004h");
    assert!(term.modes().bracketed_paste);
    assert_eq!(
        paste::encode("hi", term.modes().bracketed_paste),
        b"\x1b[200~hi\x1b[201~".to_vec()
    );

    // A paste that tries to close the bracket itself cannot escape.
    let hostile = "a\x1b[201~b";
    let out = paste::encode(hostile, true);
    let s = String::from_utf8_lossy(&out).into_owned();
    assert_eq!(s, "\x1b[200~ab\x1b[201~");
    assert!(paste::is_unsafe("multi\nline"));
    assert!(!paste::is_unsafe("plain\ttext"));
}

/// Newlines in a paste become carriage returns, which is what shells
/// expect from terminal input.
#[test]
fn paste_normalizes_newlines() {
    assert_eq!(paste::sanitize("a\nb\r\nc"), "a\rb\rc");
    assert_eq!(
        paste::encode("a\nb", true),
        b"\x1b[200~a\rb\x1b[201~".to_vec()
    );
}

#[test]
fn character_key_encoding_preserves_multiscalar_text_and_graphemes() {
    let term = Terminal::new(80, 24);
    let cfg = cfg(&term);

    // Decomposed grapheme
    let ev_decomposed = KeyEvent {
        key: Key::Char('e'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('e'),
        physical: Some('e'),
        text: Some("e\u{0301}".to_string()),
        composing: false,
    };
    assert_eq!(encode_key(ev_decomposed, cfg), "e\u{0301}".as_bytes());

    // Multi-scalar emoji
    let ev_emoji = KeyEvent {
        key: Key::Char('👨'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('👨'),
        physical: Some('👨'),
        text: Some("👨‍👩‍👧‍👦".to_string()),
        composing: false,
    };
    assert_eq!(encode_key(ev_emoji, cfg), "👨‍👩‍👧‍👦".as_bytes());

    // Negative assertion: Ctrl+C
    let ev_ctrl = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: Some("c".to_string()),
        composing: false,
    };
    assert_eq!(encode_key(ev_ctrl, cfg), vec![0x03]);

    // Negative assertion: Super+A
    let ev_super = KeyEvent {
        key: Key::Char('a'),
        mods: Mods::SUPER,
        repeat: false,
        press: true,
        unshifted: Some('a'),
        physical: Some('a'),
        text: Some("a".to_string()),
        composing: false,
    };
    assert_eq!(encode_key(ev_super, cfg), Vec::<u8>::new());
}
