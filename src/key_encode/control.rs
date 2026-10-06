/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::{Mods, OptionAsAlt};

/// The C0 byte a key produces with control held, or `None` when it produces
/// none and the caller should fall through to CSI u.
///
/// Ported from upstream's `ctrlSeq`. Two parts of
/// it are not obvious and both matter:
///
/// The typed character is not always the one to map. On a Cyrillic layout the
/// `c` key types U+0441, and every terminal still sends 0x03 for it -- so
/// when the text is not a single byte, the key's *unshifted* codepoint is
/// used instead. That only holds when control is the only modifier, because
/// with shift there is no way to know what the layout would have produced.
///
/// `ctrl+shift+m` deliberately does not produce 0x0D. Leaving shift set makes
/// the final check fail, and the caller encodes CSI u instead, which is what
/// lets a program tell `ctrl+m` from `ctrl+shift+m`. Upstream notes this
/// diverges from fixterms and matches Kitty.
///
/// `pub` because upstream's own `ctrlseq: ...` tests exercise this function
/// in isolation (checking only whether it recognizes a combination, not
/// what the full `encode()` pipeline eventually does with a `None`) -- see
/// `tests/parity_key_ctrlseq.rs`.
pub fn ctrl_seq(
    text: &str,
    unshifted: Option<char>,
    physical: Option<char>,
    mods: Mods,
) -> Option<u8> {
    if !mods.contains(Mods::CTRL) {
        return None;
    }
    // Alt does not decide whether this is a control sequence; the ESC prefix
    // is handled separately.
    let mut unset = mods - Mods::ALT;

    let bytes = text.as_bytes();
    let mut ch: u8 = if bytes.len() == 1 {
        bytes[0]
    } else {
        // A layout whose key types a non-ASCII character: fall back to the
        // key itself, and only when control is all that is held.
        let base = physical.or(unshifted)?;
        let byte = u8::try_from(base as u32).ok()?;
        if unset != Mods::CTRL {
            return None;
        }
        byte
    };

    // Shift outside the letter range does not block a control sequence, so
    // `ctrl+shift+-` still gives 0x1F. `@` is fixterms' awkward exception.
    if unset.contains(Mods::SHIFT) && !ch.is_ascii_uppercase() && ch != b'@' {
        unset -= Mods::SHIFT;
    }

    // An upper-case letter is mapped through the unshifted key, which is how
    // caps lock ends up meaning the same as no shift at all.
    //
    // Upstream relies on the host always reporting an unshifted codepoint.
    // Ours are not all able to -- the scripting and intent paths have only
    // the character -- so a bare upper-case letter falls back to its own
    // lower case rather than silently losing `ctrl+A`.
    if ch.is_ascii_uppercase() {
        ch = match unshifted.and_then(|base| u8::try_from(base as u32).ok()) {
            Some(byte) => byte,
            None => ch.to_ascii_lowercase(),
        };
    }

    if unset != Mods::CTRL {
        return None;
    }

    // Kitty's table. `i`, `m` and `[` are deliberately absent: fixterms says
    // they go out as CSI u so they stay distinguishable from tab, enter and
    // escape.
    Some(match ch {
        b' ' => 0,
        b'/' => 31,
        b'0' => 48,
        b'1' => 49,
        b'2' => 0,
        b'3' => 27,
        b'4' => 28,
        b'5' => 29,
        b'6' => 30,
        b'7' => 31,
        b'8' => 127,
        b'9' => 57,
        b'?' => 127,
        b'@' => 0,
        b'\\' => 28,
        b']' => 29,
        b'^' => 30,
        b'_' => 31,
        b'~' => 30,
        b'a'..=b'h' => ch - b'a' + 1,
        b'j'..=b'l' => ch - b'a' + 1,
        b'n'..=b'z' => ch - b'a' + 1,
        _ => return None,
    })
}

/// xterm's "modifyOtherKeys" state 2, ported from upstream's inline block
/// in `legacy()`. `None` when the combination doesn't need modifying (the
/// caller falls through to its normal encoding).
pub(crate) fn modify_other_keys(
    c: char,
    mods: Mods,
    macos_option_as_alt: OptionAsAlt,
) -> Option<Vec<u8>> {
    let mut mods_binding = mods.binding();
    // The macOS option key only counts as a real modifier here when the
    // config says it should be treated as alt; otherwise it produced a
    // composed character and isn't "used" for this purpose. We don't track
    // which physical side (left/right) was held, so Left/Right both count
    // as if the option key in question was the held one.
    if !matches!(
        macos_option_as_alt,
        OptionAsAlt::True | OptionAsAlt::Left | OptionAsAlt::Right
    ) {
        mods_binding -= Mods::ALT;
    }

    let cp = c as u32;
    let should_modify =
        (0x40..=0x7F).contains(&cp) || !(mods_binding - Mods::SHIFT).is_empty() || c == ' ';
    if !should_modify {
        return None;
    }

    let code = 1 + mods_binding.bits();
    Some(format!("\x1b[27;{code};{cp}~").into_bytes())
}

/// The fixterms CSI u fallback for ctrl+key combinations `ctrl_seq` refuses
/// (see its doc comment): letters with no C0 byte of their own, and
/// ctrl+shift+letter, which must stay distinguishable from plain
/// ctrl+letter. Ported from upstream's `csiu:` block in `legacy()`.
pub(crate) fn fixterms_csi_u(c: char, unshifted: Option<char>, mods: Mods) -> Vec<u8> {
    // Kitty-style behavior (which upstream deliberately follows over strict
    // fixterms): a shifted uppercase letter is lowercased here, which is
    // what lets programs detect shifted letters for keybindings.
    let fixterms_char = if c.is_ascii_uppercase() && mods.contains(Mods::SHIFT) {
        c.to_ascii_lowercase() as u32
    } else {
        c as u32
    };

    // Shift only survives into the mods field when the unshifted codepoint
    // matches what we're sending -- otherwise shift was already "used" to
    // produce this character and reporting it again would be redundant.
    let mut out_mods = mods;
    if unshifted.map(|u| u as u32) != Some(fixterms_char) {
        out_mods -= Mods::SHIFT;
    }

    let code = 1 + out_mods.binding().bits();
    format!("\x1b[{fixterms_char};{code}u").into_bytes()
}
