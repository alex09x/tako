// Control keys as macOS actually delivers them.
//
// The parity suite encodes ctrl+c from a clean event -- key `c`, CTRL set,
// no text. AppKit does not hand us that. `NSEvent.characters` has already
// applied the modifier, so what arrives is the control character itself:
// text "\u{03}", charactersIgnoringModifiers "c".
//
// That difference is the whole bug this file exists for. Taking the key's
// identity from `text` made ctrl+c a press of U+0003 rather than a press of
// `c` with control held, which is in no control-sequence table -- so nothing
// usable reached the pty and `tail -f` could not be interrupted.

use tako_core::key_encode::{encode, EncodeConfig, Key, KeyEvent, Mods};

const CFG: EncodeConfig = EncodeConfig {
    cursor_key_app_mode: false,
    keypad_app_mode: false,
    kitty_flags: 0,
    alt_esc_prefix: true,
    macos_option_as_alt: tako_core::key_encode::OptionAsAlt::False,
    backarrow_key_mode: false,
    modify_other_keys_state_2: false,
    ignore_keypad_with_numlock: true,
};

/// A key event shaped the way the macOS host builds one: `text` is what the
/// OS produced with modifiers already applied, `unshifted` is the base key.
fn macos_key(text: &str, unshifted: char, mods: Mods) -> KeyEvent {
    KeyEvent {
        key: Key::Char(unshifted),
        mods,
        repeat: false,
        press: true,
        unshifted: Some(unshifted),
        physical: Some(unshifted),
        text: if text.is_empty() { None } else { Some(text.to_string()) },
        composing: false,
    }
}

#[test]
fn ctrl_c_is_the_interrupt_byte() {
    // The one that matters: without this, nothing can be interrupted.
    let ev = macos_key("\u{3}", 'c', Mods::CTRL);
    assert_eq!(encode(ev, CFG).as_slice(), b"\x03");
}

#[test]
fn ctrl_d_is_end_of_transmission() {
    let ev = macos_key("\u{4}", 'd', Mods::CTRL);
    assert_eq!(encode(ev, CFG).as_slice(), b"\x04");
}

#[test]
fn ctrl_z_suspends() {
    let ev = macos_key("\u{1a}", 'z', Mods::CTRL);
    assert_eq!(encode(ev, CFG).as_slice(), b"\x1a");
}

#[test]
fn every_ctrl_letter_maps_to_its_control_byte() {
    // `i` and `m` are left out on purpose: their control bytes are Tab and
    // Return, and this engine disambiguates them into CSI u so an app can
    // tell `ctrl+i` from a real Tab. Whether that is right is a separate
    // question from this file's, and upstream's ported tests do not pin it,
    // so nothing here asserts a guess about it.
    for (i, letter) in ('a'..='z').enumerate() {
        if letter == 'i' || letter == 'm' {
            continue;
        }
        let produced = char::from_u32(i as u32 + 1).unwrap();
        let ev = macos_key(&produced.to_string(), letter, Mods::CTRL);
        assert_eq!(
            encode(ev, CFG).as_slice(),
            &[i as u8 + 1],
            "ctrl+{letter}"
        );
    }
}

/// Ordinary typing must be unaffected: the text a key produced is still what
/// reaches the shell, shift included.
#[test]
fn plain_and_shifted_typing_still_sends_its_text() {
    assert_eq!(encode(macos_key("a", 'a', Mods::empty()), CFG).as_slice(), b"a");
    assert_eq!(encode(macos_key("A", 'a', Mods::SHIFT), CFG).as_slice(), b"A");
    assert_eq!(encode(macos_key("1", '1', Mods::empty()), CFG).as_slice(), b"1");
    assert_eq!(encode(macos_key("!", '1', Mods::SHIFT), CFG).as_slice(), b"!");
}

// ── Through the FFI, the way the app actually sends a key ────────────────────
//
// The tests above exercise the encoder directly. These go through
// TakoCore::encode_key, which is what the macOS host calls, because the
// bug was in that layer's idea of which character identifies the key.

use tako_core::ffi::{FfiKey, FfiKeyEvent, TakoCore};

/// An event with the fields the macOS host fills in for a character key.
fn ffi_event(text: &str, unshifted: &str, ctrl: bool, shift: bool) -> FfiKeyEvent {
    FfiKeyEvent {
        key: FfiKey::Character,
        text: text.to_string(),
        physical_text: unshifted.to_string(),
        unshifted_text: unshifted.to_string(),
        shift,
        alt: false,
        ctrl,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    }
}

#[test]
fn the_host_path_sends_the_interrupt_byte_for_ctrl_c() {
    let core = TakoCore::new(80, 24);
    // AppKit has already folded ctrl into `characters`, so text is U+0003.
    let bytes = core.encode_key(ffi_event("\u{3}", "c", true, false));
    assert_eq!(bytes, b"\x03".to_vec(), "ctrl+c must reach the pty as 0x03");
}

#[test]
fn the_host_path_sends_ctrl_d_and_ctrl_z() {
    let core = TakoCore::new(80, 24);
    assert_eq!(core.encode_key(ffi_event("\u{4}", "d", true, false)), b"\x04".to_vec());
    assert_eq!(core.encode_key(ffi_event("\u{1a}", "z", true, false)), b"\x1a".to_vec());
}

#[test]
fn the_host_path_leaves_ordinary_typing_alone() {
    let core = TakoCore::new(80, 24);
    assert_eq!(core.encode_key(ffi_event("a", "a", false, false)), b"a".to_vec());
    assert_eq!(core.encode_key(ffi_event("A", "a", false, true)), b"A".to_vec());
    assert_eq!(core.encode_key(ffi_event("!", "1", false, true)), b"!".to_vec());
}

/// Non-Latin layouts identify the key by the character the layout produces,
/// and must keep sending that character when no modifier is held.
#[test]
fn the_host_path_handles_a_non_latin_layout() {
    let core = TakoCore::new(80, 24);
    assert_eq!(
        core.encode_key(ffi_event("\u{444}", "\u{444}", false, false)),
        "\u{444}".as_bytes().to_vec()
    );
}

// ── Negotiated keyboard modes & alternate-screen prompts ────────────────────
//
// An interactive mobile prompt can run in alternate-screen mode and negotiate
// Kitty keyboard flags (flag 1: DISAMBIGUATE_ESCAPE_CODES).
// The visible Ctrl+C quick key on mobile (providing 'c' with ctrl=true)
// must emit 0x03 (ETX/SIGINT) rather than \x1b[99;5u so that the composer
// is cancelled without asking the application to parse CSI-u for interrupts.

#[test]
fn mobile_alternate_screen_prompt_ctrl_c_uses_interrupt_byte() {
    let core = TakoCore::new(80, 24);

    // Alternate screen + bracketed paste + Kitty flag 1.
    core.feed(b"\x1b[?1049h\x1b[?2004h\x1b[=1;1u\x1b[?u".to_vec());
    assert_eq!(
        core.kitty_keyboard_flags(),
        1,
        "the prompt negotiated Kitty flag 1 (DISAMBIGUATE_ESCAPE_CODES)"
    );

    core.feed(b"prompt> draft text".to_vec());
    let plain = core.buffer_text();
    assert!(
        plain.contains("draft text"),
        "active prompt text must be present on screen"
    );

    // Mobile visible quick key: supplies 'c' with ctrl=true
    let bytes = core.encode_key(ffi_event("c", "c", true, false));
    assert_eq!(
        bytes,
        b"\x03".to_vec(),
        "visible Ctrl+C quick key must emit 0x03 to interrupt the active prompt"
    );

    // Also verify AppKit / folded character form (\u{3})
    let bytes_folded = core.encode_key(ffi_event("\u{3}", "c", true, false));
    assert_eq!(
        bytes_folded,
        b"\x03".to_vec(),
        "a host-folded Ctrl+C event must emit 0x03 in the active prompt"
    );
}

#[test]
fn legacy_mode_ctrl_c_emits_interrupt_byte() {
    let core = TakoCore::new(80, 24);

    // Legacy mode has no Kitty flags.
    assert_eq!(core.kitty_keyboard_flags(), 0);
    core.feed(b"prompt> draft text".to_vec());

    let bytes = core.encode_key(ffi_event("c", "c", true, false));
    assert_eq!(bytes, b"\x03".to_vec(), "legacy mode Ctrl+C must emit 0x03");
}

#[test]
fn pure_ctrl_c_preserves_kitty_protocol_boundaries() {
    let core = TakoCore::new(80, 24);

    // Mode 1: DISAMBIGUATE_ESCAPE_CODES (1)
    core.feed(b"\x1b[=1;1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 1);
    assert_eq!(
        core.encode_key(ffi_event("c", "c", true, false)),
        b"\x03".to_vec(),
        "mode 1: Ctrl+C must emit 0x03"
    );
    // Disambiguation of other control keys remains intact.
    assert_eq!(
        core.encode_key(ffi_event("a", "a", true, false)),
        b"\x1b[97;5u".to_vec(),
        "mode 1: Ctrl+A emits CSI u"
    );
    assert_eq!(
        core.encode_key(ffi_event("C", "c", true, true)),
        b"\x1b[99;6u".to_vec(),
        "mode 1: Ctrl+Shift+C emits CSI u"
    );
    let mut ctrl_alt_c = ffi_event("c", "c", true, false);
    ctrl_alt_c.alt = true;
    assert_eq!(
        core.encode_key(ctrl_alt_c),
        b"\x1b[99;7u".to_vec(),
        "mode 1: Ctrl+Alt+C emits CSI u"
    );
    let mut ctrl_super_c = ffi_event("c", "c", true, false);
    ctrl_super_c.super_key = true;
    assert_eq!(
        core.encode_key(ctrl_super_c),
        b"\x1b[99;13u".to_vec(),
        "mode 1: Ctrl+Super+C emits CSI u"
    );

    // Mode 2: REPORT_EVENT_TYPES (2)
    core.feed(b"\x1b[=2;1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 2);
    assert_eq!(
        core.encode_key(ffi_event("c", "c", true, false)),
        b"\x03".to_vec(),
        "mode 2: Ctrl+C press must emit 0x03"
    );
    let mut release_ev = ffi_event("c", "c", true, false);
    release_ev.press = false;
    assert_eq!(
        core.encode_key(release_ev),
        b"\x1b[99;5:3u".to_vec(),
        "mode 2: Ctrl+C release reports release event type"
    );

    // Mode 4: REPORT_ALTERNATE_KEYS (4)
    core.feed(b"\x1b[=4;1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 4);
    assert_eq!(
        core.encode_key(ffi_event("c", "c", true, false)),
        b"\x03".to_vec(),
        "mode 4: Ctrl+C must emit 0x03"
    );

    // Mode 16: REPORT_ASSOCIATED_TEXT (16)
    core.feed(b"\x1b[=16;1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 16);
    assert_eq!(
        core.encode_key(ffi_event("c", "c", true, false)),
        b"\x03".to_vec(),
        "mode 16: Ctrl+C must emit 0x03"
    );

    // Mode 8: REPORT_ALL_KEYS_AS_ESCAPES (8)
    core.feed(b"\x1b[=8;1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 8);
    assert_eq!(
        core.encode_key(ffi_event("c", "c", true, false)),
        b"\x1b[99;5u".to_vec(),
        "mode 8: Ctrl+C emits CSI u when all keys are requested as escapes"
    );

    // Full flags (31)
    core.feed(b"\x1b[=31;1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 31);
    assert_eq!(
        core.encode_key(ffi_event("c", "c", true, false)),
        b"\x1b[99;5u".to_vec(),
        "mode 31: Ctrl+C emits CSI u"
    );
}

#[test]
fn cyrillic_layout_physical_c_ctrl_c_in_kitty_mode_emits_interrupt_byte() {
    let core = TakoCore::new(80, 24);
    core.feed(b"\x1b[=1;1u".to_vec());

    let mut ev = ffi_event("\u{441}", "\u{441}", true, false);
    ev.physical_text = "c".to_string();
    assert_eq!(
        core.encode_key(ev),
        b"\x03".to_vec(),
        "Russian layout Ctrl+C in Kitty mode 1 must emit 0x03"
    );
}
