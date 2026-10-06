/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::{EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt, is_control};
use super::{is_control_utf8, is_pure_ctrl_c_press};

use super::kitty_table::{KittyEntry, kitty_entry};

/// The layout-independent codepoint a key represents -- upstream's
/// `Key.codepoint()`, used as the "base layout key" alternate. Only
/// `Key::Char` carries one; every named key in `kitty_entry`'s table already
/// has a fixed protocol code and never reports a base-layout alternate.
fn key_base_codepoint(key: Key) -> Option<u32> {
    match key {
        Key::Char(c) => Some(c as u32),
        _ => None,
    }
}

/// The shifted form of an ASCII symbol/digit on a US QWERTY layout --
/// there's no general rule for these the way there is for letters. Unicode
/// case-folding covers letters, including non-Latin scripts.
fn us_shifted(c: char) -> char {
    match c {
        '`' => '~',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        _ => c.to_uppercase().next().unwrap_or(c),
    }
}

/// Perform Kitty keyboard protocol encoding of the key event.
///
/// Ported from upstream's `kitty()`. Structure
/// mirrors upstream closely: find the key's table entry (or fall back to its
/// unshifted codepoint), handle dead-key/composing/plain-text preprocessing,
/// then build and encode the CSI u sequence.
pub(crate) fn encode_kitty(event: KeyEvent, config: EncodeConfig) -> Vec<u8> {
    let report_events = (config.kitty_flags & 2) != 0;
    let report_alternates = (config.kitty_flags & 4) != 0;
    let report_all = (config.kitty_flags & 8) != 0;
    let report_associated = (config.kitty_flags & 16) != 0;

    // We only process "press" events unless report_events is active. Enter,
    // backspace and tab additionally never report release events unless
    // report_all is set too, so a program relying on a single release does
    // not spuriously see one for these.
    if !event.press && !event.repeat {
        if !report_events {
            return Vec::new();
        }
        if !report_all && matches!(event.key, Key::Enter | Key::Backspace | Key::Tab) {
            return Vec::new();
        }
    }

    let binding_mods = event.mods.binding();
    let utf8 = event.utf8();

    // Find this key's entry, falling back to its unshifted codepoint when
    // it isn't a functional/predefined key (e.g. a plain letter).
    let entry = kitty_entry(event.key).or_else(|| {
        event.unshifted.map(|u| KittyEntry {
            code: u as u32,
            final_byte: b'u',
            modifier: false,
        })
    });

    // When composing, only plain modifier-key events are sent.
    if event.composing {
        match &entry {
            Some(e) if e.modifier => {}
            _ => return Vec::new(),
        }
    } else {
        // IME confirmation still sends an enter/backspace key, so if we have
        // committed text we send it directly rather than the key's normal
        // sequence -- unless the text is itself a single control character,
        // which means this isn't actually dead-key text.
        if let Some(text) = &utf8
            && !text.is_empty()
            && !is_control_utf8(text)
        {
            match event.key {
                Key::Backspace => return Vec::new(),
                Key::Enter => return text.as_bytes().to_vec(),
                _ => {}
            }
        }

        if !report_all {
            // Enter, Tab and Backspace still generate their legacy bytes so
            // a user can type `reset` after a program that set this mode
            // crashes without clearing it.
            if binding_mods.is_empty() {
                match event.key {
                    Key::Enter => return b"\r".to_vec(),
                    Key::Tab => return b"\t".to_vec(),
                    Key::Backspace => return b"\x7f".to_vec(),
                    _ => {}
                }
            }

            // Ctrl+C remains ETX when an application has not explicitly
            // requested every key as CSI-u. This narrowly preserves terminal
            // interrupt/cancel for a visible mobile Ctrl+C key in an
            // alternate-screen prompt; shifted and modified variants, event
            // releases, and every non-C control key retain normal Kitty
            // encoding.
            if is_pure_ctrl_c_press(&event) {
                return vec![0x03];
            }

            // Plain text goes straight to the terminal rather than through
            // a CSI sequence -- and unlike the enter/tab/backspace shortcut
            // above, shift alone does not block this, UNLESS the app asked
            // for report_alternates: an app that wants base-vs-shifted
            // separation needs the CSI form to get it, but one that
            // doesn't just wants the text. Without this exception, a
            // protocol-aware shell (fish, by default) that gets `CSI
            // 97;2u` for shift+a has no way to recover the text and drops
            // the event -- shift used to type nothing at all because of
            // this distinction being missed.
            let text_binding_mods = if report_alternates {
                binding_mods
            } else {
                binding_mods - Mods::SHIFT
            };
            if let Some(text) = &utf8
                && text_binding_mods.is_empty()
                && event.press
                && !text.is_empty()
                && !text.chars().any(|c| is_control(c as u32))
            {
                return text.as_bytes().to_vec();
            }
        }
    }

    let Some(entry) = entry else {
        // No table entry and no unshifted codepoint: this is pure composed
        // text with no key behind it (e.g. IME), so send it as-is.
        return match &utf8 {
            Some(text) if !text.is_empty() => text.as_bytes().to_vec(),
            _ => Vec::new(),
        };
    };

    // A bare modifier key only gets a sequence under report_all.
    if entry.modifier && !report_all {
        return Vec::new();
    }

    let mut kitty_mods = 0u32;
    if event.mods.contains(Mods::SHIFT) {
        kitty_mods |= 1;
    }
    if event.mods.contains(Mods::ALT) {
        kitty_mods |= 2;
    }
    if event.mods.contains(Mods::CTRL) {
        kitty_mods |= 4;
    }
    if event.mods.contains(Mods::SUPER) {
        kitty_mods |= 8;
    }
    if event.mods.contains(Mods::CAPS_LOCK) {
        kitty_mods |= 64;
    }
    if event.mods.contains(Mods::NUM_LOCK) {
        kitty_mods |= 128;
    }
    let mods_int = kitty_mods + 1;

    // Kitty omits the ":1" for a plain press (event_val 0 and 1 behave
    // identically below); only repeat/release change the encoding.
    let event_val: u8 = if report_events {
        if !event.press {
            3
        } else if event.repeat {
            2
        } else {
            1
        }
    } else {
        0
    };

    // What this exact keypress produced as text: the host's own text when
    // it gave us one, else derived from `unshifted` -- shifted/uppercased
    // when shift OR caps lock is held (either one makes a real layout
    // produce the shifted form), otherwise the layout's plain output.
    // Upstream always has this from a real multi-codepoint `event.utf8`
    // string; single-codepoint derivation covers every test and every real
    // key event, which never carries more than one committed codepoint
    // outside of dead-key/IME commits (handled separately, above).
    let produced = event.text.clone().or_else(|| {
        event.unshifted.map(|u| {
            if event.mods.contains(Mods::SHIFT) || event.mods.contains(Mods::CAPS_LOCK) {
                us_shifted(u).to_string()
            } else {
                u.to_string()
            }
        })
    });
    let cp1 = produced
        .as_ref()
        .and_then(|s| s.chars().next())
        .map(|c| c as u32);

    let mut alternates: [Option<u32>; 2] = [None, None];
    if report_alternates && !is_control(entry.code) {
        if let Some(cp1) = cp1 {
            // Only real shift, not caps lock, reports a shifted alternate --
            // upstream gates this on `seq.mods.shift` specifically.
            if cp1 != entry.code && event.mods.contains(Mods::SHIFT) {
                alternates[0] = Some(cp1);
            }
            if let Some(base) = key_base_codepoint(event.key)
                && base != entry.code
                && cp1 != base
            {
                alternates[1] = Some(base);
            }
        } else if let Some(base) = key_base_codepoint(event.key)
            && base != entry.code
        {
            alternates[1] = Some(base);
        }
    }

    let mut text: Option<String> = None;
    if report_associated && event_val != 3 {
        let alt_prevents_text = match config.macos_option_as_alt {
            OptionAsAlt::Left | OptionAsAlt::Right => event.mods.contains(Mods::ALT), // sides not tracked
            OptionAsAlt::True => true,
            OptionAsAlt::False => false,
        };
        let prevents_text = (event.mods.contains(Mods::ALT) && alt_prevents_text)
            || event.mods.contains(Mods::CTRL)
            || event.mods.contains(Mods::SUPER);
        if !prevents_text {
            text = produced;
        }
    }

    kitty_sequence_encode(
        entry.code,
        entry.final_byte,
        mods_int,
        event_val,
        alternates,
        text.as_deref(),
    )
}

/// The Kitty CSI u/CSI-special sequence formatter in isolation, ported from
/// upstream's `KittySequence.encode`. `pub`
/// because upstream's own `KittySequence: ...` tests exercise this directly
/// rather than through the full `kitty()` pipeline -- see
/// `tests/parity_key_kitty.rs`.
///
/// `mods_int` is upstream's `KittyMods.seqInt()` (the "1 + bitmask" value,
/// never 0); `event_val` is 0 for no event reported, 1 for press, 2 for
/// repeat, 3 for release -- 0 and 1 behave identically, matching upstream's
/// `Event.none`/`Event.press`.
pub fn kitty_sequence_encode(
    key: u32,
    final_byte: u8,
    mods_int: u32,
    event_val: u8,
    alternates: [Option<u32>; 2],
    text: Option<&str>,
) -> Vec<u8> {
    if final_byte == b'u' || final_byte == b'~' {
        kitty_encode_full(key, final_byte, mods_int, event_val, alternates, text)
    } else {
        kitty_encode_special(final_byte, mods_int, event_val)
    }
}

fn kitty_encode_full(
    key: u32,
    final_byte: u8,
    mods_int: u32,
    event_val: u8,
    alternates: [Option<u32>; 2],
    text: Option<&str>,
) -> Vec<u8> {
    let mut out = format!("\x1b[{key}");
    if let Some(shifted) = alternates[0] {
        out.push_str(&format!(":{shifted}"));
    }
    if let Some(base) = alternates[1] {
        if alternates[0].is_none() {
            out.push_str(&format!("::{base}"));
        } else {
            out.push_str(&format!(":{base}"));
        }
    }

    let mut emit_prior = false;
    if event_val > 1 {
        out.push_str(&format!(";{mods_int}:{event_val}"));
        emit_prior = true;
    } else if mods_int > 1 {
        out.push_str(&format!(";{mods_int}"));
        emit_prior = true;
    }

    if let Some(text) = text {
        let mut count = 0;
        for cp in text.chars() {
            if is_control(cp as u32) {
                continue;
            }
            if count == 0 {
                if !emit_prior {
                    out.push(';');
                }
                out.push(';');
            } else {
                out.push(':');
            }
            out.push_str(&(cp as u32).to_string());
            count += 1;
        }
    }

    out.push(final_byte as char);
    out.into_bytes()
}

fn kitty_encode_special(final_byte: u8, mods_int: u32, event_val: u8) -> Vec<u8> {
    if event_val > 1 {
        return format!("\x1b[1;{mods_int}:{event_val}{}", final_byte as char).into_bytes();
    }
    if mods_int > 1 {
        return format!("\x1b[1;{mods_int}{}", final_byte as char).into_bytes();
    }
    format!("\x1b[{}", final_byte as char).into_bytes()
}
