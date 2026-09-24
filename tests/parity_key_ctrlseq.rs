// Parity tests ported from upstream's key-encoding test suite in
// the upstream `key_encode` test suite (specifically the "ctrlseq: ..." group).

use tako_core::key_encode::{ctrl_seq, encode, EncodeConfig, Key, KeyEvent, Mods};

const DEFAULT_CONFIG: EncodeConfig = EncodeConfig {
    cursor_key_app_mode: false,
    keypad_app_mode: false,
    kitty_flags: 0,
    alt_esc_prefix: false,
    macos_option_as_alt: tako_core::key_encode::OptionAsAlt::False,
    backarrow_key_mode: false,
    modify_other_keys_state_2: false,
    ignore_keypad_with_numlock: false,
};

/// Upstream test: "ctrlseq: normal ctrl c"
#[test]
fn ctrlseq_normal_ctrl_c() {
    let ev = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x03");
}

/// Upstream test: "ctrlseq: normal ctrl c, right control"
#[test]
fn ctrlseq_normal_ctrl_c_right_control() {
    // Note: upstream .sides (right control) is omitted as modifier sides are not modelled in Rust API.
    let ev = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x03");
}

/// Upstream test: "ctrlseq: alt should be allowed"
#[test]
fn ctrlseq_alt_should_be_allowed() {
    let ev = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL | Mods::ALT,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x03");
}

/// Upstream test: "ctrlseq: no ctrl does nothing"
#[test]
fn ctrlseq_no_ctrl_does_nothing() {
    let ev = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"c");
}

/// Upstream test: "ctrlseq: shifted non-character"
#[test]
fn ctrlseq_shifted_non_character() {
    let ev = KeyEvent {
        key: Key::Char('_'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: Some('-'),
        physical: Some('-'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x1f");
}

/// Upstream test: "ctrlseq: caps ascii letter"
#[test]
fn ctrlseq_caps_ascii_letter() {
    // Note: upstream .caps_lock is omitted as caps_lock is not modelled in Rust Mods.
    let ev = KeyEvent {
        key: Key::Char('C'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x03");
}

/// Upstream test: "ctrlseq: shift does not generate ctrl seq"
///
/// Upstream's real test exercises `ctrlSeq()` in isolation (does it
/// recognize the combination at all?), not what the full `legacy()`
/// pipeline eventually does with a `None` -- that's covered separately by
/// `legacy_ctrl_shift_letter_ascii` in parity_key_legacy.rs, which (per
/// upstream's fixterms CSI u fallback) escapes rather than passing the
/// letter through. The original port here called the full `encode()`
/// pipeline instead and happened to match before that fallback existed;
/// fixed to test the same function upstream does.
#[test]
fn ctrlseq_shift_does_not_generate_ctrl_seq() {
    assert_eq!(ctrl_seq("C", Some('c'), None, Mods::SHIFT), None);
    assert_eq!(ctrl_seq("C", Some('c'), None, Mods::SHIFT | Mods::CTRL), None);
}

/// Upstream test: "ctrlseq: russian ctrl c"
#[test]
fn ctrlseq_russian_ctrl_c() {
    let ev = KeyEvent {
        key: Key::Char('с'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: Some('с'),
        // Upstream's first argument is the logical key -- `key_c` -- which
        // is the ASCII the key types on a US layout, not what this layout
        // makes of it.
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x03");
}

/// Upstream test: "ctrlseq: russian shifted ctrl c"
///
/// Same correction as `ctrlseq_shift_does_not_generate_ctrl_seq` above:
/// tests `ctrl_seq()` directly, matching upstream's real test.
#[test]
fn ctrlseq_russian_shifted_ctrl_c() {
    assert_eq!(ctrl_seq("с", Some('с'), Some('c'), Mods::CTRL | Mods::SHIFT), None);
}

/// Upstream test: "ctrlseq: russian alt ctrl c"
#[test]
fn ctrlseq_russian_alt_ctrl_c() {
    let ev = KeyEvent {
        key: Key::Char('с'),
        mods: Mods::CTRL | Mods::ALT,
        repeat: false,
        press: true,
        unshifted: Some('с'),
        // Upstream's first argument is the logical key -- `key_c` -- which
        // is the ASCII the key types on a US layout, not what this layout
        // makes of it.
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x03");
}

/// Upstream test: "ctrlseq: right ctrl c"
#[test]
fn ctrlseq_right_ctrl_c() {
    // Note: upstream .sides (right control) is omitted as modifier sides are not modelled in Rust API.
    let ev = KeyEvent {
        key: Key::Char('с'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    assert_eq!(encode(ev, DEFAULT_CONFIG).as_slice(), b"\x03");
}
