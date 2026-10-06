/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

mod control;
mod kitty;
mod kitty_table;
mod legacy;
mod types;

#[cfg(test)]
mod tests;

pub use control::ctrl_seq;
use kitty::encode_kitty;
pub use kitty::kitty_sequence_encode;
use legacy::encode_legacy;
use types::is_control;
pub use types::{EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt};

/// True for a string that is exactly one control character -- upstream's
/// `isControlUtf8`, used to tell a real dead-key/IME text commit (which
/// wins over a key's default bytes) from a host echoing a bare control
/// byte back as "text" (which should not).
pub(crate) fn is_control_utf8(s: &str) -> bool {
    let mut chars = s.chars();
    matches!((chars.next(), chars.next()), (Some(c), None) if is_control(c as u32))
}

/// The legacy terminal interrupt byte is retained only for a literal Ctrl+C
/// key press. This compatibility exception lets hosts with a visible Ctrl+C
/// key cancel an interactive prompt after it enables Kitty disambiguation,
/// while applications that request report-all still receive CSI-u.
pub(crate) fn is_pure_ctrl_c_press(event: &KeyEvent) -> bool {
    event.press
        && event.mods.binding() == Mods::CTRL
        && (matches!(event.key, Key::Char('c') | Key::Char('C'))
            || matches!(event.unshifted, Some('c') | Some('C'))
            || matches!(event.physical, Some('c') | Some('C')))
}

pub fn encode(event: KeyEvent, config: EncodeConfig) -> Vec<u8> {
    if config.kitty_flags != 0 {
        return encode_kitty(event, config);
    }
    encode_legacy(event, config)
}
