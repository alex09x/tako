/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

#[test]
fn checkpoint_bool_wrappers_round_trip() {
    let core = TakoCore::new(20, 5);
    core.feed(b"hello there".to_vec());
    let blob = core.checkpoint();
    assert!(!blob.is_empty());
    assert!(core.verify_checkpoint(blob.clone()));
    assert!(
        !core.verify_checkpoint(vec![1, 2, 3]),
        "garbage does not verify"
    );

    let dest = TakoCore::new(20, 5);
    assert!(dest.restore(blob));
    assert_eq!(
        dest.get_line(0).trim_end_matches(['\0', ' ']),
        "hello there"
    );
    assert!(!dest.restore(Vec::new()), "empty payload fails to restore");
}

/// `checkpoint_export` rejects any nonzero `flags` (the v1 container
/// reserves the field) with a typed `Corrupt` error, without touching the
/// terminal.
#[test]
fn checkpoint_export_rejects_nonzero_flags() {
    let core = TakoCore::new(20, 5);
    core.feed(b"data".to_vec());
    match core.checkpoint_export(1, u64::MAX) {
        Err(TakoCheckpointError::Corrupt { reason }) => {
            assert!(reason.contains("flags"));
        }
        other => panic!("expected Corrupt for nonzero flags, got {other:?}"),
    }
}

/// `checkpoint_inspect` on an empty blob fails with `NullArgument`, the
/// same as `checkpoint_import`.
#[test]
fn checkpoint_inspect_rejects_empty_blob() {
    let core = TakoCore::new(20, 5);
    assert_eq!(
        core.checkpoint_inspect(Vec::new()),
        Err(TakoCheckpointError::NullArgument)
    );
}

// -----------------------------------------------------------------------
// Synchronized output / kitty flags (src/ffi/mod.rs:855-863)
// -----------------------------------------------------------------------

/// `is_synchronized_output_active` mirrors the terminal's mode-2026 state.
#[test]
fn is_synchronized_output_active_tracks_mode_2026() {
    let core = TakoCore::new(20, 5);
    assert!(!core.is_synchronized_output_active());
    core.feed(b"\x1b[?2026h".to_vec());
    assert!(core.is_synchronized_output_active());
    core.feed(b"\x1b[?2026l".to_vec());
    assert!(!core.is_synchronized_output_active());
}

/// `kitty_keyboard_flags` reports the raw enhancement bitmask after a CSI
/// `>` push (progressive enhancement flags = 1, disambiguate escape codes).
#[test]
fn kitty_keyboard_flags_reports_pushed_bitmask() {
    let core = TakoCore::new(20, 5);
    assert_eq!(core.kitty_keyboard_flags(), 0);
    core.feed(b"\x1b[>1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 1);
}

// -----------------------------------------------------------------------
// Key encoding (src/ffi/mod.rs:918-1033)
// -----------------------------------------------------------------------

/// Named (non-character) keys encode to their standard escape sequences;
/// this walks a representative sample across the whole match arm rather
/// than every single variant, which would be redundant with key_encode's
/// own tests.
#[test]
fn encode_key_named_keys_produce_expected_bytes() {
    let core = TakoCore::new(20, 5);
    assert_eq!(core.encode_key(default_key_event(FfiKey::Enter)), b"\r");
    assert_eq!(core.encode_key(default_key_event(FfiKey::Tab)), b"\t");
    assert_eq!(core.encode_key(default_key_event(FfiKey::Escape)), b"\x1b");
    assert_eq!(core.encode_key(default_key_event(FfiKey::Up)), b"\x1b[A");
    assert_eq!(core.encode_key(default_key_event(FfiKey::F1)), b"\x1bOP");
    assert_eq!(
        core.encode_key(default_key_event(FfiKey::KeypadEnter)),
        b"\r"
    );
    assert_eq!(core.encode_key(default_key_event(FfiKey::Space)), b" ");
}

/// A `Character` key with `unshifted_text` set uses the physical base key,
/// not what came out of `text` -- this is what makes ctrl+c on any layout
/// send 0x03 instead of the localized letter. See the comment on the
/// `FfiKey::Character` arm in `encode_key`.
#[test]
fn encode_key_character_prefers_unshifted_base_for_ctrl() {
    let core = TakoCore::new(20, 5);
    let mut event = default_key_event(FfiKey::Character);
    event.text = "\u{0003}".to_string(); // what ctrl+c produced on this layout
    event.unshifted_text = "c".to_string();
    event.ctrl = true;
    assert_eq!(core.encode_key(event), vec![0x03]);
}

/// A `Character` key with neither `unshifted_text` nor `text` set has no
/// base key to encode, so the call returns empty bytes rather than
/// panicking.
#[test]
fn encode_key_character_with_no_base_returns_empty() {
    let core = TakoCore::new(20, 5);
    let event = default_key_event(FfiKey::Character);
    assert!(core.encode_key(event).is_empty());
}

/// A `Character` key falls back to `text` when `unshifted_text` is absent
/// (e.g. IME commit with no physical-key concept).
#[test]
fn encode_key_character_falls_back_to_text() {
    let core = TakoCore::new(20, 5);
    let mut event = default_key_event(FfiKey::Character);
    event.text = "A".to_string();
    assert_eq!(core.encode_key(event), b"A");
}

/// `encode_key` reads the terminal's live cursor-key mode, so an arrow key
/// switches between `CSI` and `SS3` depending on DECCKM.
#[test]
fn encode_key_respects_live_cursor_key_app_mode() {
    let core = TakoCore::new(20, 5);
    assert_eq!(core.encode_key(default_key_event(FfiKey::Up)), b"\x1b[A");
    core.feed(b"\x1b[?1h".to_vec()); // DECCKM on
    assert_eq!(core.encode_key(default_key_event(FfiKey::Up)), b"\x1bOA");
}

// -----------------------------------------------------------------------
// Mouse encoding, paste (src/ffi/mod.rs:1038-1102)
// -----------------------------------------------------------------------

fn mouse_event(
    button: FfiMouseButton,
    action: FfiMouseAction,
    col: u32,
    row: u32,
) -> FfiMouseEvent {
    FfiMouseEvent {
        button,
        action,
        shift: false,
        alt: false,
        ctrl: false,
        col,
        row,
    }
}

/// With mouse tracking off, `encode_mouse` produces nothing regardless of
/// the event -- the terminal never asked for mouse reports.
#[test]
fn encode_mouse_off_produces_no_bytes() {
    let core = TakoCore::new(20, 5);
    let bytes = core.encode_mouse(mouse_event(
        FfiMouseButton::Left,
        FfiMouseAction::Press,
        1,
        1,
    ));
    assert!(bytes.is_empty());
}

/// Normal tracking (mode 1000) reports presses/releases but not motion.
#[test]
fn encode_mouse_normal_tracking_drops_motion_reports_presses() {
    let core = TakoCore::new(20, 5);
    core.feed(b"\x1b[?1000h".to_vec());
    let motion = core.encode_mouse(mouse_event(
        FfiMouseButton::None,
        FfiMouseAction::Motion,
        1,
        1,
    ));
    assert!(
        motion.is_empty(),
        "plain normal tracking must not report motion"
    );

    let press = core.encode_mouse(mouse_event(
        FfiMouseButton::Left,
        FfiMouseAction::Press,
        1,
        1,
    ));
    assert!(!press.is_empty());
}

/// SGR mouse encoding (mode 1006 + 1000) yields the `CSI < ... M` form,
/// with 1-based coordinates.
#[test]
fn encode_mouse_sgr_encoding_reports_one_based_coordinates() {
    let core = TakoCore::new(20, 5);
    core.feed(b"\x1b[?1000h\x1b[?1006h".to_vec());
    let bytes = core.encode_mouse(mouse_event(
        FfiMouseButton::Left,
        FfiMouseAction::Press,
        4,
        2,
    ));
    let text = String::from_utf8(bytes).unwrap();
    assert_eq!(text, "\x1b[<0;5;3M");
}

/// Bracketed paste wraps the payload in `ESC[200~ ... ESC[201~` only when
/// mode 2004 is on, and strips a trailing paste terminator either way.
#[test]
fn encode_paste_brackets_only_when_mode_2004_is_on() {
    let core = TakoCore::new(20, 5);
    let plain = core.encode_paste("hi".to_string());
    assert_eq!(plain, b"hi");

    core.feed(b"\x1b[?2004h".to_vec());
    let bracketed = core.encode_paste("hi".to_string());
    assert_eq!(bracketed, b"\x1b[200~hi\x1b[201~");
}

/// Text with newlines or control characters is flagged unsafe to paste
/// unbracketed; plain text is not.
#[test]
fn paste_is_unsafe_flags_control_characters() {
    let core = TakoCore::new(20, 5);
    assert!(!core.paste_is_unsafe("plain text".to_string()));
    assert!(core.paste_is_unsafe("line one\nline two".to_string()));
    assert!(core.paste_is_unsafe("bell\x07here".to_string()));
}
