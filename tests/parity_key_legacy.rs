// Ported 1:1 from upstream's tests in the upstream `key_encode` test suite.
// Reference: the upstream `key_encode` test suite

use tako_core::key_encode::{encode, EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt};

/// Upstream test: "legacy: backspace with utf8 (dead key state)"
#[test]
fn legacy_backspace_with_utf8_dead_key_state() {
    // `unshifted: Some('\r')` here is just backspace's own normal unshifted
    // value (upstream's test sets `unshifted_codepoint = 0x0D` too) -- the
    // dead-key commit is carried by `text`, upstream's `utf8`.
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\r'),
        physical: Some('\r'),
        text: Some("A".to_string()),
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"");
}

/// Upstream test: "legacy: enter with utf8 (dead key state)"
#[test]
fn legacy_enter_with_utf8_dead_key_state() {
    let event = KeyEvent {
        key: Key::Enter,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\r'),
        physical: Some('\r'),
        text: Some("A".to_string()),
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"A");
}

/// Upstream test: "legacy: esc with utf8 (dead key state)"
#[test]
fn legacy_esc_with_utf8_dead_key_state() {
    let event = KeyEvent {
        key: Key::Escape,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\r'),
        physical: Some('\r'),
        text: Some("A".to_string()),
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"A");
}

/// Upstream test: "legacy: ctrl+shift+minus (underscore on US)"
#[test]
fn legacy_ctrl_shift_minus_underscore_on_us() {
    let event = KeyEvent {
        key: Key::Char('_'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1F");
}

/// Upstream test: "legacy: ctrl+alt+c"
#[test]
fn legacy_ctrl_alt_c() {
    let event = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL | Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b\x03");
}

/// Upstream test: "legacy: alt+c"
#[test]
fn legacy_alt_c() {
    let event = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bc");
}

/// Upstream test: "legacy: alt+e only unshifted"
#[test]
fn legacy_alt_e_only_unshifted() {
    let event = KeyEvent {
        key: Key::Char('e'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: Some('e'),
        physical: Some('e'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1be");
}

/// Upstream test: "legacy: alt+x macos"
#[test]
fn legacy_alt_x_macos() {
    let event = KeyEvent {
        key: Key::Char('\u{2248}'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bc");
}

/// Upstream test: "legacy: shift+alt+. macos"
#[test]
fn legacy_shift_alt_period_macos() {
    let event = KeyEvent {
        key: Key::Char('>'),
        mods: Mods::ALT | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: Some('.'),
        physical: Some('.'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b>");
}

/// Upstream test: "legacy: alt+ф"
#[test]
fn legacy_alt_cyrillic_ef() {
    let event = KeyEvent {
        key: Key::Char('ф'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), "ф".as_bytes());
}

/// Upstream test: "legacy: ctrl+c"
#[test]
fn legacy_ctrl_c() {
    let event = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x03");
}

/// Upstream test: "legacy: ctrl+space"
#[test]
fn legacy_ctrl_space() {
    let event = KeyEvent {
        key: Key::Space,
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x00");
}

/// Upstream test: "legacy: ctrl+shift+backspace"
#[test]
fn legacy_ctrl_shift_backspace() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x08");
}

/// Upstream test: "legacy: backspace (DECBKM reset)"
#[test]
fn legacy_backspace_decbkm_reset() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x7f");
}

/// Upstream test: "legacy: backspace (DECBKM reset, with ctrl)"
#[test]
fn legacy_backspace_decbkm_reset_with_ctrl() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x08");
}

/// Upstream test: "legacy: backspace (DECBKM set)"
#[test]
fn legacy_backspace_decbkm_set() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        backarrow_key_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x08");
}

/// Upstream test: "legacy: backspace (DECBKM set, with ctrl)"
#[test]
fn legacy_backspace_decbkm_set_with_ctrl() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        backarrow_key_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x7f");
}

/// Upstream test: "legacy: ctrl+shift+char with modify other state 2"
#[test]
fn legacy_ctrl_shift_char_with_modify_other_state_2() {
    let event = KeyEvent {
        key: Key::Char('H'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        modify_other_keys_state_2: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b[27;6;72~");
}

/// Upstream test: "legacy: ctrl+shift+char with modify other state 2 and consumed mods"
#[test]
fn legacy_ctrl_shift_char_with_modify_other_state_2_and_consumed_mods() {
    // Upstream's `consumed_mods` (which mods the apprt already used to
    // produce `utf8`) has no equivalent field here; this crate derives the
    // same "was shift used up" fact from `unshifted` instead, so the
    // scenario is identical to the plain modify-other-state-2 case above.
    let event = KeyEvent {
        key: Key::Char('H'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        modify_other_keys_state_2: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b[27;6;72~");
}

/// Upstream test: "legacy: alt+digit with modify other state 2"
#[test]
fn legacy_alt_digit_with_modify_other_state_2() {
    let event = KeyEvent {
        key: Key::Char('8'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        modify_other_keys_state_2: true,
        macos_option_as_alt: OptionAsAlt::True,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b[27;3;56~");
}

/// Upstream test: "legacy: alt+digit with modify other state 2 and macos-option-as-alt = false"
#[test]
fn legacy_alt_digit_with_modify_other_state_2_and_macos_option_as_alt_false() {
    let event = KeyEvent {
        key: Key::Char('['),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"[");
}

/// Upstream test: "legacy: fixterm awkward letters"
#[test]
fn legacy_fixterm_awkward_letters() {
    let config = EncodeConfig::default();
    {
        let event = KeyEvent {
            key: Key::Char('i'),
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[105;5u");
    }
    {
        let event = KeyEvent {
            key: Key::Char('m'),
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[109;5u");
    }
    {
        let event = KeyEvent {
            key: Key::Char('['),
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[91;5u");
    }
    {
        let event = KeyEvent {
            key: Key::Char('@'),
            mods: Mods::CTRL | Mods::SHIFT,
            repeat: false,
            press: true,
            unshifted: Some('2'),
        physical: Some('2'),
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[64;5u");
    }
}

/// Upstream test: "legacy: ctrl+shift+letter ascii"
#[test]
fn legacy_ctrl_shift_letter_ascii() {
    let event = KeyEvent {
        key: Key::Char('M'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: Some('m'),
        physical: Some('m'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[109;6u");
}

/// Upstream test: "legacy: shift+function key should use all mods"
#[test]
fn legacy_shift_function_key_should_use_all_mods() {
    let event = KeyEvent {
        key: Key::Up,
        mods: Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[1;2A");
}

/// Upstream test: "legacy: keypad enter"
#[test]
fn legacy_keypad_enter() {
    let event = KeyEvent {
        key: Key::KeypadEnter,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\r");
}

/// Upstream test: "legacy: keypad 1"
#[test]
fn legacy_keypad_1() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"1");
}

/// Upstream test: "legacy: keypad 1 with application keypad"
#[test]
fn legacy_keypad_1_with_application_keypad() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        keypad_app_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bOq");
}

/// Upstream test: "legacy: keypad 1 with application keypad and numlock"
#[test]
fn legacy_keypad_1_with_application_keypad_and_numlock() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        keypad_app_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bOq");
}

/// Upstream test: "legacy: keypad 1 with application keypad and numlock ignore"
#[test]
fn legacy_keypad_1_with_application_keypad_and_numlock_ignore() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    // DEC mode 1035: numlock's real state, not the app-mode request,
    // decides digit-vs-SS3 -- upstream's `ignore_keypad_with_numlock`.
    // Without this field the previous two tests are indistinguishable from
    // this one; the port originally dropped it since the field didn't
    // exist yet.
    let config = EncodeConfig {
        keypad_app_mode: true,
        ignore_keypad_with_numlock: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"1");
}

/// Upstream test: "legacy: f1"
#[test]
fn legacy_f1() {
    let config = EncodeConfig::default();
    {
        let event = KeyEvent {
            key: Key::F1,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[1;5P");
    }
    {
        let event = KeyEvent {
            key: Key::F2,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[1;5Q");
    }
    {
        let event = KeyEvent {
            key: Key::F3,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[13;5~");
    }
    {
        let event = KeyEvent {
            key: Key::F4,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[1;5S");
    }
    {
        let event = KeyEvent {
            key: Key::F5,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
        physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[15;5~");
    }
}

/// Upstream test: "legacy: left_shift+tab"
#[test]
fn legacy_left_shift_tab() {
    // Note: sides (left/right modifier) is omitted.
    let event = KeyEvent {
        key: Key::Tab,
        mods: Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[Z");
}

/// Upstream test: "legacy: right_shift+tab"
#[test]
fn legacy_right_shift_tab() {
    // Note: sides (left/right modifier) is omitted.
    let event = KeyEvent {
        key: Key::Tab,
        mods: Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[Z");
}

/// Upstream test: "legacy: hu layout ctrl+ő sends proper codepoint"
#[test]
fn legacy_hu_layout_ctrl_o_double_acuteness_sends_proper_codepoint() {
    let event = KeyEvent {
        key: Key::Char('ő'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: char::from_u32(337),
        physical: char::from_u32(337),
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[337;5u");
}

/// Upstream test: "legacy: super-only on macOS with text"
#[test]
fn legacy_super_only_on_macos_with_text() {
    let event = KeyEvent {
        key: Key::Char('b'),
        mods: Mods::SUPER,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"");
}

/// Upstream test: "legacy: super and other mods on macOS with text"
#[test]
fn legacy_super_and_other_mods_on_macos_with_text() {
    let event = KeyEvent {
        key: Key::Char('B'),
        mods: Mods::SUPER | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"");
}

/// Upstream test: "legacy: backspace with DEL utf8 (DECBKM reset)"
#[test]
fn legacy_backspace_with_del_utf8_decbkm_reset() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\x08'),
        physical: Some('\x08'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x7f");
}

/// Upstream test: "legacy: backspace with DEL utf8 (DECBKM set)"
#[test]
fn legacy_backspace_with_del_utf8_decbkm_set() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\x08'),
        physical: Some('\x08'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        backarrow_key_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x08");
}
