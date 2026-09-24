// Upstream tests ported 1:1 from the upstream `key_encode` test suite (group: kitty)

use tako_core::key_encode::{encode, EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt};

fn make_key_event(key: Key, mods: Mods, press: bool, repeat: bool, unshifted: Option<char>) -> KeyEvent {
    KeyEvent {
        key,
        mods,
        repeat,
        press,
        unshifted,
        physical: unshifted,
        text: None,
        composing: false,
    }
}

/// Like `make_key_event`, but for the dead-key/IME-commit and composing
/// tests upstream drives through `event.utf8`/`event.composing`, which the
/// 5-arg helper above has no way to express.
fn make_key_event_full(
    key: Key,
    mods: Mods,
    press: bool,
    repeat: bool,
    unshifted: Option<char>,
    text: Option<&str>,
    composing: bool,
) -> KeyEvent {
    KeyEvent {
        key,
        mods,
        repeat,
        press,
        unshifted,
        physical: unshifted,
        text: text.map(String::from),
        composing,
    }
}

fn cfg(kitty_flags: u8) -> EncodeConfig {
    EncodeConfig {
        cursor_key_app_mode: false,
        keypad_app_mode: false,
        kitty_flags,
        alt_esc_prefix: false,
        macos_option_as_alt: OptionAsAlt::False,
        backarrow_key_mode: false,
        modify_other_keys_state_2: false,
        ignore_keypad_with_numlock: false,
    }
}

/// Upstream test: "kitty: plain text"
#[test]
fn kitty_plain_text() {
    let ev = make_key_event_full(Key::Char('a'), Mods::empty(), true, false, None, Some("abcd"), false);
    assert_eq!(encode(ev, cfg(1)), b"abcd");
}

/// Upstream test: "kitty: repeat with just disambiguate"
#[test]
fn kitty_repeat_with_just_disambiguate() {
    let ev = make_key_event(Key::Char('a'), Mods::empty(), true, true, None);
    assert_eq!(encode(ev, cfg(1)), b"a");
}

/// Upstream test: "kitty: enter, backspace, tab"
#[test]
fn kitty_enter_backspace_tab() {
    assert_eq!(
        encode(make_key_event(Key::Enter, Mods::empty(), true, false, None), cfg(1)),
        b"\r"
    );
    assert_eq!(
        encode(make_key_event(Key::Backspace, Mods::empty(), true, false, None), cfg(1)),
        b"\x7f"
    );
    assert_eq!(
        encode(make_key_event(Key::Backspace, Mods::empty(), true, false, None), cfg(1)),
        b"\x7f"
    );
    assert_eq!(
        encode(make_key_event(Key::Tab, Mods::empty(), true, false, None), cfg(1)),
        b"\t"
    );

    // No release events if "report_all" is not set
    assert_eq!(
        encode(make_key_event(Key::Enter, Mods::empty(), false, false, None), cfg(3)),
        b""
    );
    assert_eq!(
        encode(make_key_event(Key::Backspace, Mods::empty(), false, false, None), cfg(3)),
        b""
    );
    assert_eq!(
        encode(make_key_event(Key::Tab, Mods::empty(), false, false, None), cfg(3)),
        b""
    );

    // Release events if "report_all" is set
    assert_eq!(
        encode(make_key_event(Key::Enter, Mods::empty(), false, false, None), cfg(11)),
        b"\x1b[13;1:3u"
    );
    assert_eq!(
        encode(make_key_event(Key::Backspace, Mods::empty(), false, false, None), cfg(11)),
        b"\x1b[127;1:3u"
    );
    assert_eq!(
        encode(make_key_event(Key::Tab, Mods::empty(), false, false, None), cfg(11)),
        b"\x1b[9;1:3u"
    );
}

/// Upstream test: "kitty: shift+backspace emits CSI u"
#[test]
fn kitty_shift_backspace_emits_csi_u() {
    let ev = make_key_event(Key::Backspace, Mods::SHIFT, true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[127;2u");
}

/// Upstream test: "kitty: shift+enter emits CSI u"
#[test]
fn kitty_shift_enter_emits_csi_u() {
    let ev = make_key_event(Key::Enter, Mods::SHIFT, true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[13;2u");
}

/// Upstream test: "kitty: shift+tab emits CSI u"
#[test]
fn kitty_shift_tab_emits_csi_u() {
    let ev = make_key_event(Key::Tab, Mods::SHIFT, true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[9;2u");
}

/// Upstream test: "kitty: enter with all flags"
#[test]
fn kitty_enter_with_all_flags() {
    let ev = make_key_event(Key::Enter, Mods::empty(), true, false, None);
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[13u");
}

/// Upstream test: "kitty: ctrl with all flags"
#[test]
fn kitty_ctrl_with_all_flags() {
    let ev = make_key_event(Key::ControlLeft, Mods::CTRL, true, false, None);
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[57442;5u");
}

/// Upstream test: "kitty: ctrl release with ctrl mod set"
#[test]
fn kitty_ctrl_release_with_ctrl_mod_set() {
    let ev = make_key_event(Key::ControlLeft, Mods::CTRL, false, false, None);
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[57442;5:3u");
}

/// Upstream test: "kitty: delete"
#[test]
fn kitty_delete() {
    let ev = make_key_event(Key::Delete, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[3~");
}

/// Upstream test: "kitty: composing with no modifier"
#[test]
fn kitty_composing_with_no_modifier() {
    let ev = make_key_event_full(Key::Char('a'), Mods::SHIFT, true, false, None, None, true);
    assert_eq!(encode(ev, cfg(1)), b"");
}

/// Upstream test: "kitty: composing with modifier"
#[test]
fn kitty_composing_with_modifier() {
    // While composing, only a plain modifier-key event is still sent
    // (upstream: `entry.modifier` breaks the composing suppression), and
    // only under report_all.
    let ev = make_key_event_full(Key::ShiftLeft, Mods::SHIFT, true, false, None, None, true);
    let actual = encode(ev, cfg(9)); // disambiguate + report_all
    assert_eq!(&actual[..], b"\x1b[57441;2u");
}

/// Upstream test: "kitty: composed text with report all"
#[test]
fn kitty_composed_text_with_report_all() {
    let ev = make_key_event_full(Key::Unidentified, Mods::empty(), true, false, None, Some("\u{fb}"), false);
    assert_eq!(encode(ev, cfg(31)), "\u{fb}".as_bytes());
}

/// Upstream test: "kitty: shift+a on US keyboard"
#[test]
fn kitty_shift_a_on_us_keyboard() {
    let ev = make_key_event(Key::Char('a'), Mods::SHIFT, true, false, Some('a'));
    assert_eq!(encode(ev, cfg(5)), b"\x1b[97:65;2u");
}

/// Upstream test: "kitty: matching unshifted codepoint"
#[test]
fn kitty_matching_unshifted_codepoint() {
    let ev = make_key_event(Key::Char('a'), Mods::SHIFT, true, false, Some('A'));
    assert_eq!(encode(ev, cfg(5)), b"\x1b[65::97;2u");
}

/// Upstream test: "kitty: report alternates with caps"
#[test]
fn kitty_report_alternates_with_caps() {
    let ev = make_key_event_full(Key::Char('j'), Mods::CAPS_LOCK, true, false, Some('j'), Some("J"), false);
    assert_eq!(encode(ev, cfg(29)), b"\x1b[106;65;74u"); // disambiguate + report_all + report_alternates + report_associated
}

/// Upstream test: "kitty: report alternates colon (shift+';')"
#[test]
fn kitty_report_alternates_colon_shift_semicolon() {
    let ev = make_key_event(Key::Char(';'), Mods::SHIFT, true, false, Some(';'));
    assert_eq!(encode(ev, cfg(31)), b"\x1b[59:58;2;58u");
}

/// Upstream test: "kitty: report alternates with ru layout"
#[test]
fn kitty_report_alternates_with_ru_layout() {
    let ev = make_key_event(Key::Char(';'), Mods::empty(), true, false, Some('ч'));
    assert_eq!(encode(ev, cfg(31)), b"\x1b[1095::59;;1095u");
}

/// Upstream test: "kitty: report alternates with ru layout shifted"
#[test]
fn kitty_report_alternates_with_ru_layout_shifted() {
    let ev = make_key_event(Key::Char(';'), Mods::SHIFT, true, false, Some('ч'));
    assert_eq!(encode(ev, cfg(31)), b"\x1b[1095:1063:59;2;1063u");
}

/// Upstream test: "kitty: report alternates with ru layout caps lock"
#[test]
fn kitty_report_alternates_with_ru_layout_caps_lock() {
    let ev = make_key_event_full(Key::Char(';'), Mods::CAPS_LOCK, true, false, Some('ч'), Some("Ч"), false);
    assert_eq!(encode(ev, cfg(29)), b"\x1b[1095::59;65;1063u"); // disambiguate + report_all + report_alternates + report_associated
}

/// Upstream test: "kitty: report alternates with hu layout release"
#[test]
fn kitty_report_alternates_with_hu_layout_release() {
    let ev = make_key_event(Key::Char('['), Mods::CTRL, false, false, Some('ő'));
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[337::91;5:3u");
}

/// Upstream test: "kitty: up arrow with utf8"
#[test]
fn kitty_up_arrow_with_utf8() {
    let ev = make_key_event(Key::Up, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[A");
}

/// Upstream test: "kitty: shift+tab"
#[test]
fn kitty_shift_tab() {
    let ev = make_key_event(Key::Tab, Mods::SHIFT, true, false, None);
    assert_eq!(encode(ev, cfg(5)), b"\x1b[9;2u");
}

/// Upstream test: "kitty: left shift"
#[test]
fn kitty_left_shift() {
    let ev = make_key_event(Key::ShiftLeft, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(5)), b""); // disambiguate + report_alternates, no report_all
}

/// Upstream test: "kitty: left shift with report all"
#[test]
fn kitty_left_shift_with_report_all() {
    let ev = make_key_event(Key::ShiftLeft, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(9)), b"\x1b[57441u"); // disambiguate + report_all
}

/// Upstream test: "kitty: report associated with alt text on macOS with option"
#[test]
fn kitty_report_associated_with_alt_text_on_macos_with_option() {
    // macos_option_as_alt = false: Alt does not suppress associated text, so
    // the composed character ("∑", option+w on a US Mac layout) still comes
    // through.
    let ev = make_key_event_full(Key::Char('w'), Mods::ALT, true, false, Some('w'), Some("\u{2211}"), false);
    let config = EncodeConfig {
        cursor_key_app_mode: false,
        keypad_app_mode: false,
        kitty_flags: 29, // disambiguate + report_all + report_alternates + report_associated
        alt_esc_prefix: false,
        macos_option_as_alt: OptionAsAlt::False,
        backarrow_key_mode: false,
        modify_other_keys_state_2: false,
        ignore_keypad_with_numlock: false,
    };
    assert_eq!(encode(ev, config), b"\x1b[119;3;8721u");
}

/// Upstream test: "kitty: report associated with alt text on macOS with alt"
#[test]
fn kitty_report_associated_with_alt_text_on_macos_with_alt() {
    // macos_option_as_alt = true: Alt is a real modifier now, so it
    // suppresses the associated text -- with the modifier, no text section;
    // without it, the composed character still comes through.
    let with_alt = make_key_event_full(Key::Char('w'), Mods::ALT, true, false, Some('w'), Some("\u{2211}"), false);
    let config = EncodeConfig {
        cursor_key_app_mode: false,
        keypad_app_mode: false,
        kitty_flags: 29,
        alt_esc_prefix: false,
        macos_option_as_alt: OptionAsAlt::True,
        backarrow_key_mode: false,
        modify_other_keys_state_2: false,
        ignore_keypad_with_numlock: false,
    };
    assert_eq!(encode(with_alt, config), b"\x1b[119;3u");

    let without_alt = make_key_event_full(Key::Char('w'), Mods::empty(), true, false, Some('w'), Some("\u{2211}"), false);
    let actual = encode(without_alt, config);
    assert_eq!(&actual[..], "\u{1b}[119;;8721u".as_bytes());
}

/// Upstream test: "kitty: report associated with modifiers"
#[test]
fn kitty_report_associated_with_modifiers() {
    let ev = make_key_event(Key::Char('j'), Mods::CTRL, true, false, Some('j'));
    assert_eq!(encode(ev, cfg(31)), b"\x1b[106;5u");
}

/// Upstream test: "kitty: report associated"
#[test]
fn kitty_report_associated() {
    let ev = make_key_event(Key::Char('j'), Mods::SHIFT, true, false, Some('j'));
    assert_eq!(encode(ev, cfg(31)), b"\x1b[106:74;2;74u");
}

/// Upstream test: "kitty: report associated on release"
#[test]
fn kitty_report_associated_on_release() {
    let ev = make_key_event(Key::Char('j'), Mods::SHIFT, false, false, Some('j'));
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[106:74;2:3u");
}

/// Upstream test: "kitty: alternates omit control characters"
#[test]
fn kitty_alternates_omit_control_characters() {
    let ev = make_key_event(Key::Delete, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(13)), b"\x1b[3~");
}

/// Upstream test: "kitty: enter with utf8 (dead key state)"
#[test]
fn kitty_enter_with_utf8_dead_key_state() {
    // An IME confirmation still sends an Enter key, so when it carries
    // committed text (and that text is not itself a single control
    // character), the text wins over Enter's own default bytes.
    let ev = make_key_event_full(Key::Enter, Mods::empty(), true, false, Some('\r'), Some("A"), false);
    assert_eq!(encode(ev, cfg(13)), b"A");
}

/// Upstream test: "kitty: keypad number"
#[test]
fn kitty_keypad_number() {
    let ev = make_key_event_full(Key::Keypad1, Mods::empty(), true, false, None, Some("1"), false);
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[57400;;49u");
}

/// Upstream test: "kitty: backspace with utf8 (dead key state)"
#[test]
fn kitty_backspace_with_utf8_dead_key_state() {
    // Backspace's dead-key text commit encodes nothing at all: the IME
    // already modified the preedit buffer, so there is nothing left to send.
    let ev = make_key_event_full(Key::Backspace, Mods::empty(), true, false, Some('\r'), Some("A"), false);
    assert_eq!(encode(ev, cfg(31)), b"");
}

/// Upstream test: "kitty: backspace (DECBKM reset) (report_all: true)"
#[test]
fn kitty_backspace_decbkm_reset_report_all_true() {
    let ev = make_key_event(Key::Backspace, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(31)), b"\x1b[127u");
}

/// Upstream test: "kitty: backspace (DECBKM set) (report_all: true)"
#[test]
fn kitty_backspace_decbkm_set_report_all_true() {
    let ev = make_key_event(Key::Backspace, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(31)), b"\x1b[127u");
}

// Upstream's `KittySequence: ...` tests exercise the CSI-sequence formatter
// directly rather than through the full `kitty()` pipeline above -- see
// `key_encode::kitty_sequence_encode`'s doc comment for the parameter
// mapping (mods_int is the "1 + bitmask" seqInt value, event_val is
// 0=none/1=press/2=repeat/3=release).
use tako_core::key_encode::kitty_sequence_encode;

/// Upstream test: "KittySequence: backspace"
#[test]
fn kitty_sequence_backspace() {
    // Plain.
    assert_eq!(kitty_sequence_encode(127, b'u', 1, 0, [None, None], None), b"\x1b[127u");
    // Release event.
    assert_eq!(kitty_sequence_encode(127, b'u', 1, 3, [None, None], None), b"\x1b[127;1:3u");
    // Shift.
    assert_eq!(kitty_sequence_encode(127, b'u', 2, 0, [None, None], None), b"\x1b[127;2u");
}

/// Upstream test: "KittySequence: text"
#[test]
fn kitty_sequence_text() {
    // Plain.
    assert_eq!(kitty_sequence_encode(127, b'u', 1, 0, [None, None], Some("A")), b"\x1b[127;;65u");
    // Release.
    assert_eq!(kitty_sequence_encode(127, b'u', 1, 3, [None, None], Some("A")), b"\x1b[127;1:3;65u");
    // Shift.
    assert_eq!(kitty_sequence_encode(127, b'u', 2, 0, [None, None], Some("A")), b"\x1b[127;2;65u");
}

/// Upstream test: "KittySequence: text with control characters"
#[test]
fn kitty_sequence_text_with_control_characters() {
    // By itself: the only codepoint is control, so the whole text section
    // (and its leading ";;") is omitted.
    assert_eq!(kitty_sequence_encode(127, b'u', 1, 0, [None, None], Some("\n")), b"\x1b[127u");
    // With other printables: the control codepoint is skipped, not the text
    // section itself.
    assert_eq!(kitty_sequence_encode(127, b'u', 1, 0, [None, None], Some("A\n")), b"\x1b[127;;65u");
}

/// Upstream test: "KittySequence: special no mods"
#[test]
fn kitty_sequence_special_no_mods() {
    assert_eq!(kitty_sequence_encode(1, b'A', 1, 0, [None, None], None), b"\x1b[A");
}

/// Upstream test: "KittySequence: special mods only"
#[test]
fn kitty_sequence_special_mods_only() {
    assert_eq!(kitty_sequence_encode(1, b'A', 2, 0, [None, None], None), b"\x1b[1;2A");
}

/// Upstream test: "KittySequence: special mods and event"
#[test]
fn kitty_sequence_special_mods_and_event() {
    assert_eq!(kitty_sequence_encode(1, b'A', 2, 3, [None, None], None), b"\x1b[1;2:3A");
}
