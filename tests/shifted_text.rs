// A shifted letter must reach the shell as the shifted letter.
//
// The engine encodes the character it is handed, so this pins the contract
// the host layer has to satisfy: the character a key produces is the one
// with modifiers applied. The macOS layer was handing over the *unmodified*
// character, so every capital arrived lower case -- a bug no engine test
// could have caught, because the engine was doing exactly what it was told.

use tako_core::key_encode::{encode, EncodeConfig, Key, KeyEvent, Mods};

fn typed(ch: char, mods: Mods) -> Vec<u8> {
    encode(
        KeyEvent {
            key: Key::Char(ch),
            mods,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        },
        EncodeConfig::default(),
    )
}

/// The same key, reported the way a host reports it: the shifted character
/// as the text, the base character alongside.
fn typed_with_base(ch: char, base: char, mods: Mods, kitty: u8) -> Vec<u8> {
    encode(
        KeyEvent {
            key: Key::Char(ch),
            mods,
            repeat: false,
            press: true,
            unshifted: Some(base),
            physical: Some(base),
            text: None,
            composing: false,
        },
        EncodeConfig {
            cursor_key_app_mode: false,
            keypad_app_mode: false,
            kitty_flags: kitty,
            alt_esc_prefix: true,
            macos_option_as_alt: tako_core::key_encode::OptionAsAlt::False,
            backarrow_key_mode: false,
            modify_other_keys_state_2: false,
            ignore_keypad_with_numlock: false,
        },
    )
}

/// The plain letter.
#[test]
fn lowercase_letter_passes_through() {
    assert_eq!(typed('a', Mods::empty()), b"a");
}

/// The shifted letter, with the shift bit set as the platform reports it.
#[test]
fn shifted_letter_reaches_the_shell_uppercase() {
    assert_eq!(typed('A', Mods::SHIFT), b"A");
}

/// Shift must not swallow the character or change its case.
#[test]
fn shift_does_not_alter_the_character_it_is_given() {
    for ch in ['A', 'Z', '!', '~', '?'] {
        assert_eq!(
            typed(ch, Mods::SHIFT),
            ch.to_string().as_bytes(),
            "shifted {ch:?} should encode as itself"
        );
    }
}

/// Control still takes precedence and produces a control byte.
#[test]
fn control_letter_still_encodes_as_a_control_byte() {
    assert_eq!(typed('c', Mods::CTRL), vec![0x03]);
}


// The Kitty keyboard protocol identifies a key by its *base* codepoint and
// reports shift as a modifier. Sending the shifted codepoint instead gives a
// protocol-aware shell -- fish does this by default -- no way to tell which
// key was pressed, and it drops the event: shift typed nothing at all.

/// Upstream's "kitty: plain text": under disambiguate alone, a text key
/// sends its text. This is the one that mattered -- we were escaping it,
/// and fish, which turns the protocol on, threw the result away.
#[test]
fn kitty_sends_text_keys_as_text() {
    assert_eq!(typed_with_base('a', 'a', Mods::empty(), 1), b"a");
}

/// Shift alone is still just text: shift is how a capital is typed.
#[test]
fn kitty_sends_a_shifted_letter_as_its_letter() {
    assert_eq!(typed_with_base('A', 'a', Mods::SHIFT, 1), b"A");
}

/// And a shifted digit as its punctuation.
#[test]
fn kitty_sends_a_shifted_digit_as_its_symbol() {
    assert_eq!(typed_with_base('!', '1', Mods::SHIFT, 1), b"!");
}

/// A modifier other than shift does make it an escape code, and there the
/// key number is the base key -- `ctrl+shift+a` is the `a` key.
#[test]
fn kitty_reports_the_base_key_when_it_does_escape() {
    assert_eq!(
        typed_with_base('A', 'a', Mods::SHIFT | Mods::CTRL, 1),
        b"\x1b[97;6u",
        "the key number must be the base key, 97, not the shifted 65"
    );
}

/// Reporting all keys as escape codes overrides the text rule.
#[test]
fn kitty_report_all_escapes_text_keys_too() {
    assert_eq!(typed_with_base('A', 'a', Mods::SHIFT, 1 | 8), b"\x1b[97;2u");
}

/// Legacy encoding still sends the character the key produced, not the base:
/// there is no modifier field to carry the shift in.
#[test]
fn legacy_still_sends_the_shifted_character() {
    assert_eq!(typed_with_base('A', 'a', Mods::SHIFT, 0), b"A");
    assert_eq!(typed_with_base('!', '1', Mods::SHIFT, 0), b"!");
}
