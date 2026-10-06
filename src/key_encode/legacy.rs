/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::control::{ctrl_seq, fixterms_csi_u, modify_other_keys};
use super::is_control_utf8;
use super::types::{EncodeConfig, Key, KeyEvent, Mods};

pub(crate) fn encode_legacy(event: KeyEvent, config: EncodeConfig) -> Vec<u8> {
    let kitty_active = false;
    let report_events = false;

    if !event.press && !report_events {
        return Vec::new();
    }

    let m = 1 + event.mods.binding().bits();

    let mod_str = if m != 1 { Some(format!("{m}")) } else { None };

    let disambiguate = false;

    match event.key {
        Key::Up => encode_arrow('A', config, mod_str),
        Key::Down => encode_arrow('B', config, mod_str),
        Key::Right => encode_arrow('C', config, mod_str),
        Key::Left => encode_arrow('D', config, mod_str),
        Key::Home => encode_arrow('H', config, mod_str),
        Key::End => encode_arrow('F', config, mod_str),

        Key::Insert => encode_tilde(2, mod_str),
        Key::Delete => encode_tilde(3, mod_str),
        Key::PageUp => encode_tilde(5, mod_str),
        Key::PageDown => encode_tilde(6, mod_str),

        Key::F1 => encode_f1_f4('P', mod_str),
        Key::F2 => encode_f1_f4('Q', mod_str),
        // F3 is the one named function key with no SS3 letter of its own --
        // it shares the tilde form and code 13 with Enter (see
        // `kitty_entry`'s table, which upstream's legacy table agrees with).
        Key::F3 => encode_tilde(13, mod_str),
        Key::F4 => encode_f1_f4('S', mod_str),

        Key::F5 => encode_tilde(15, mod_str),
        Key::F6 => encode_tilde(17, mod_str),
        Key::F7 => encode_tilde(18, mod_str),
        Key::F8 => encode_tilde(19, mod_str),
        Key::F9 => encode_tilde(20, mod_str),
        Key::F10 => encode_tilde(21, mod_str),
        Key::F11 => encode_tilde(23, mod_str),
        Key::F12 => encode_tilde(24, mod_str),

        Key::KeypadEnter => {
            if config.keypad_app_mode {
                b"\x1bOM".to_vec()
            } else {
                encode_ambiguous(13, b"\r", event, config, disambiguate, mod_str, false)
            }
        }
        Key::KeypadPlus => {
            if config.keypad_app_mode {
                b"\x1bOk".to_vec()
            } else {
                encode_ambiguous('+' as u32, b"+", event, config, disambiguate, mod_str, true)
            }
        }
        Key::KeypadMinus => {
            if config.keypad_app_mode {
                b"\x1bOm".to_vec()
            } else {
                encode_ambiguous('-' as u32, b"-", event, config, disambiguate, mod_str, true)
            }
        }
        Key::KeypadMultiply => {
            if config.keypad_app_mode {
                b"\x1bOj".to_vec()
            } else {
                encode_ambiguous('*' as u32, b"*", event, config, disambiguate, mod_str, true)
            }
        }
        Key::KeypadDivide => {
            if config.keypad_app_mode {
                b"\x1bOo".to_vec()
            } else {
                encode_ambiguous('/' as u32, b"/", event, config, disambiguate, mod_str, true)
            }
        }

        Key::Enter => {
            // An IME confirmation still sends an Enter key, so committed
            // dead-key text (not itself a single control character) wins
            // over Enter's own bytes -- upstream's comment: escape/enter/
            // backspace all have a specific meaning mid-composition, so we
            // must not send their PC-style sequence over real commit text.
            if let Some(text) = &event.text
                && !text.is_empty()
                && !is_control_utf8(text)
            {
                return text.as_bytes().to_vec();
            }
            encode_ambiguous(13, b"\r", event, config, disambiguate, mod_str, false)
        }
        Key::Tab => {
            if !kitty_active && event.mods.contains(Mods::SHIFT) {
                let mut bytes = b"\x1b[Z".to_vec();
                if event.mods.contains(Mods::ALT) && config.alt_esc_prefix {
                    bytes.insert(0, 0x1b);
                }
                bytes
            } else {
                encode_ambiguous(9, b"\t", event, config, disambiguate, mod_str, false)
            }
        }
        Key::Backspace => {
            // Backspace's dead-key text commit encodes nothing: the IME
            // already modified the preedit buffer, so there is nothing
            // left to send (upstream: "backspace encodes nothing because
            // we modified IME").
            if let Some(text) = &event.text
                && !text.is_empty()
                && !is_control_utf8(text)
            {
                return Vec::new();
            }
            // DEC Backarrow Key Mode (DECBKM): off sends 0x7F and ctrl+
            // backspace sends 0x08; on swaps them.
            let ctrl = !kitty_active && event.mods.contains(Mods::CTRL);
            let default_bytes: &[u8] = match (config.backarrow_key_mode, ctrl) {
                (false, false) => b"\x7f",
                (false, true) => b"\x08",
                (true, false) => b"\x08",
                (true, true) => b"\x7f",
            };
            encode_ambiguous(
                127,
                default_bytes,
                event,
                config,
                disambiguate,
                mod_str,
                false,
            )
        }
        Key::Escape => {
            // Same dead-key-text priority as Enter: e.g. on Japanese input,
            // escape clears (rather than commits) the composition, so a
            // real text commit still wins over escape's own byte.
            if let Some(text) = &event.text
                && !text.is_empty()
                && !is_control_utf8(text)
            {
                return text.as_bytes().to_vec();
            }
            encode_ambiguous(27, b"\x1b", event, config, disambiguate, mod_str, false)
        }
        Key::Space => {
            let default_bytes = if !kitty_active && event.mods.contains(Mods::CTRL) {
                b"\x00".as_slice()
            } else {
                b" ".as_slice()
            };
            encode_ambiguous(
                32,
                default_bytes,
                event,
                config,
                disambiguate,
                mod_str,
                true,
            )
        }

        Key::Char(c) => {
            // Keypad application mode (DECKPAM) applies to the digit keys
            // too, not just the named keypad symbols -- upstream's
            // function-key table covers numpad_0..9 the same way it covers
            // numpad_enter etc. We have no separate "this came from the
            // numpad, not the top row" signal, so this applies to any
            // digit character key; `ignore_keypad_with_numlock` (DEC mode
            // 1035) is how a host suppresses it.
            if config.keypad_app_mode && !config.ignore_keypad_with_numlock && c.is_ascii_digit() {
                let letter = (b'p' + c as u8 - b'0') as char;
                return format!("\x1bO{letter}").into_bytes();
            }

            // The key number identifies the key, not the character it made:
            // the physical key first, then its unmodified form, then the
            // character itself. On a Cyrillic layout only the first of those
            // says this is the `c` key, which is what lets `ctrl+c` work
            // there under the Kitty protocol as well as without it.
            let codepoint = event
                .physical
                .filter(char::is_ascii)
                .or(event.unshifted)
                .unwrap_or(c) as u32;

            if !kitty_active && event.mods.contains(Mods::CTRL) {
                let mut text_buf = [0u8; 4];
                let text = c.encode_utf8(&mut text_buf);
                if let Some(byte) = ctrl_seq(text, event.unshifted, event.physical, event.mods) {
                    let raw_bytes = [byte];
                    return encode_ambiguous(
                        codepoint,
                        &raw_bytes,
                        event,
                        config,
                        disambiguate,
                        mod_str,
                        true,
                    );
                }
            }

            // xterm's modifyOtherKeys state 2: ctrl/alt/shift combinations
            // that would otherwise lose their modifiers -- or collide with
            // another sequence -- go out as `CSI 27;mods;codepoint~`
            // instead. Checked after ctrlSeq (which gets first refusal) but
            // regardless of whether ctrl is held at all, since it also
            // covers plain alt+key.
            if config.modify_other_keys_state_2
                && let Some(out) = modify_other_keys(c, event.mods, config.macos_option_as_alt)
            {
                return out;
            }

            // The fixterms CSI u fallback: ctrl+letters that deliberately
            // have no C0 byte (i, m, [ -- see `ctrl_seq`'s doc comment) and
            // ctrl+shift+letter, which must stay distinguishable from
            // plain ctrl+letter.
            if !kitty_active && event.mods.contains(Mods::CTRL) {
                return fixterms_csi_u(c, event.unshifted, event.mods);
            }

            // On macOS, super+key never encodes text -- native apps and
            // other terminals (Terminal.app, iTerm2) agree on this. Linux
            // continues to encode text since that's typical there, but
            // this crate has only ever targeted macOS/iOS hosts.
            if event.mods.contains(Mods::SUPER) {
                return Vec::new();
            }

            let raw_bytes = match &event.text {
                Some(text) if !text.is_empty() => text.as_bytes().to_vec(),
                _ => {
                    let mut buf = [0u8; 4];
                    c.encode_utf8(&mut buf).as_bytes().to_vec()
                }
            };
            encode_ambiguous(
                codepoint,
                &raw_bytes,
                event,
                config,
                disambiguate,
                mod_str,
                true,
            )
        }

        // Numpad digits, the standalone modifier-key events and text with
        // no key behind it only ever exist under the Kitty protocol (see
        // `encode_kitty`'s entry table); legacy mode has no representation
        // for them.
        Key::Keypad0
        | Key::Keypad1
        | Key::Keypad2
        | Key::Keypad3
        | Key::Keypad4
        | Key::Keypad5
        | Key::Keypad6
        | Key::Keypad7
        | Key::Keypad8
        | Key::Keypad9
        | Key::ShiftLeft
        | Key::ShiftRight
        | Key::ControlLeft
        | Key::ControlRight
        | Key::AltLeft
        | Key::AltRight
        | Key::MetaLeft
        | Key::MetaRight
        | Key::Unidentified => Vec::new(),
    }
}

fn encode_arrow(letter: char, config: EncodeConfig, mod_str: Option<String>) -> Vec<u8> {
    if let Some(s) = mod_str {
        format!("\x1b[1;{s}{letter}").into_bytes()
    } else if config.cursor_key_app_mode {
        format!("\x1bO{letter}").into_bytes()
    } else {
        format!("\x1b[{letter}").into_bytes()
    }
}

fn encode_tilde(code: u8, mod_str: Option<String>) -> Vec<u8> {
    if let Some(s) = mod_str {
        format!("\x1b[{code};{s}~").into_bytes()
    } else {
        format!("\x1b[{code}~").into_bytes()
    }
}

fn encode_f1_f4(letter: char, mod_str: Option<String>) -> Vec<u8> {
    if let Some(s) = mod_str {
        format!("\x1b[1;{s}{letter}").into_bytes()
    } else {
        format!("\x1bO{letter}").into_bytes()
    }
}

fn encode_ambiguous(
    codepoint: u32,
    legacy_bytes: &[u8],
    event: KeyEvent,
    config: EncodeConfig,
    disambiguate: bool,
    mod_str: Option<String>,
    // True for keys that exist to produce text -- characters, space, the
    // keypad symbols -- as opposed to the ambiguous ones this mode is
    // named for.
    text_key: bool,
) -> Vec<u8> {
    // Under "disambiguate escape codes" alone, a key that produces text is
    // still sent as that text unless it carries a modifier other than shift.
    // Escaping it anyway hands the shell `CSI 97;2u` for a shifted `a`, and
    // a shell that speaks the protocol then has to work out the text itself
    // -- fish does not, so shifted keys typed nothing at all.
    //
    // This applies only to keys whose whole purpose is text. Escape, Enter,
    // Tab and Backspace also produce bytes, but they are the ambiguous ones
    // the mode exists to disambiguate. Reporting event types or all keys as
    // escape codes turns everything into escapes, by definition.
    let report_all_keys = (config.kitty_flags & 8) != 0;
    let report_events = (config.kitty_flags & 2) != 0;
    let only_shift = (event.mods - Mods::SHIFT).is_empty();
    if disambiguate && text_key && only_shift && !report_all_keys && !report_events {
        return legacy_bytes.to_vec();
    }

    if disambiguate {
        if let Some(s) = mod_str {
            format!("\x1b[{codepoint};{s}u").into_bytes()
        } else {
            format!("\x1b[{codepoint}u").into_bytes()
        }
    } else if event.mods.contains(Mods::ALT) && config.alt_esc_prefix {
        // The alt-prefixed output is `ESC` plus exactly one byte -- not the
        // original bytes with `ESC` stuck on the front. When the key's own
        // bytes aren't a single byte (a non-ASCII character), we fall back
        // to the unshifted codepoint if it fits in one; otherwise there is
        // nothing to prefix and alt is left to do nothing rather than
        // mangling multi-byte UTF-8 with a raw `ESC` in front of it.
        let byte = if legacy_bytes.len() == 1 {
            Some(legacy_bytes[0])
        } else {
            event.unshifted.and_then(|u| u8::try_from(u as u32).ok())
        };
        match byte {
            Some(b) => vec![0x1b, b],
            None => legacy_bytes.to_vec(),
        }
    } else {
        legacy_bytes.to_vec()
    }
}
