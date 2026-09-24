//! DECDSR — the private device status reports, `CSI ? Ps n`.
//!
//! These ask about hardware a VT had and a terminal emulator does not: a
//! printer port, user-defined-key locks, a locator, macro memory. The honest
//! answer to nearly all of them is "not present", and giving it matters more
//! than it looks: a program that sends one of these and gets **nothing** does
//! not fall back, it blocks on the read. Silence is the one answer a terminal
//! must never give here. esctest hit exactly that — eleven tests, every one
//! failing with "Timeout waiting to read".
//!
//! The values follow xterm's `charproc.c`. Where a reply's shape depends on
//! the declared VT level, it follows ours: `da1_response` reports 62, a
//! VT220, so DECXCPR omits the page parameter and the keyboard report stops
//! after the language. Raising the primary DA later means revisiting those
//! two, and nothing else here.

use super::Terminal;

/// Private DSR codes, named as the VT manuals name them.
mod code {
    /// Operating status.
    pub const STATUS: u16 = 5;
    /// Extended cursor position report, `CSI ? Pl ; Pc [; Pp] R`.
    pub const XCPR: u16 = 6;
    /// Printer port status.
    pub const PRINTER: u16 = 15;
    /// User-defined keys locked or unlocked.
    pub const UDK: u16 = 25;
    /// Keyboard language, status and type.
    pub const KEYBOARD: u16 = 26;
    /// Locator availability.
    pub const LOCATOR_STATUS: u16 = 55;
    /// Locator type (mouse, tablet).
    pub const LOCATOR_TYPE: u16 = 56;
    /// Macro space, answered without the private prefix.
    pub const MACRO_SPACE: u16 = 62;
    /// Macro memory checksum, answered as a DCS.
    pub const MACRO_CHECKSUM: u16 = 63;
    /// Communication link integrity.
    pub const INTEGRITY: u16 = 75;
    /// Multiple-session (TDSMP) configuration.
    pub const MULTI_SESSION: u16 = 85;
    /// Colour scheme, an xterm/contour extension rather than a DEC one.
    pub const COLOR_SCHEME: u16 = 996;
}

impl Terminal {
    /// Answers `CSI ? Ps n`. Returns true when `ps` was recognised, so the
    /// caller can tell an unimplemented report from a deliberate silence.
    pub(super) fn report_private_dsr(&mut self, params: &[u16]) -> bool {
        let ps = params.first().copied().unwrap_or(0);

        match ps {
            code::STATUS => self.response.push_str("\x1b[?0n"),

            code::XCPR => {
                let (row, col) = self.reported_cursor();
                self.response.push_str(&format!("\x1b[?{row};{col}R"));
            }

            // 13 is "no printer detected", which is the truth and stays the
            // truth; the other legal values describe a printer we will never
            // have.
            code::PRINTER => self.response.push_str("\x1b[?13n"),

            // We have no user-defined keys to lock, so they are never locked.
            code::UDK => self.response.push_str("\x1b[?20n"),

            // 27 introduces the report; 1 is North American. The status and
            // type fields are VT320/VT420 additions -- see the module note.
            code::KEYBOARD => self.response.push_str("\x1b[?27;1n"),

            // 53 is "no locator". The DEC locator is a different device from
            // the xterm mouse protocols we do implement, and nothing here
            // answers DECEFR/DECELR.
            code::LOCATOR_STATUS => self.response.push_str("\x1b[?53n"),

            // 57 introduces the report; 0 is "unknown", consistent with
            // having no locator at all.
            code::LOCATOR_TYPE => self.response.push_str("\x1b[?57;0n"),

            // DECMSR answers without the private prefix, with the count in
            // hex, and terminates with `*{`. No macro memory exists.
            code::MACRO_SPACE => self.response.push_str("\x1b[0000*{"),

            // DECCKSR shares DECRQCRA's reply shape. With no macro memory
            // there is nothing to checksum.
            code::MACRO_CHECKSUM => {
                let id = params.get(1).copied().unwrap_or(0);
                self.response.push_str(&format!("\x1bP{id}!~0000\x1b\\"));
            }

            // 70 is "no communication errors", which a pty cannot have.
            code::INTEGRITY => self.response.push_str("\x1b[?70n"),

            // 83 is "not configured for multiple sessions".
            code::MULTI_SESSION => self.response.push_str("\x1b[?83n"),

            code::COLOR_SCHEME => {
                // Only answered once the host has told us which scheme is in
                // use; guessing would be worse than staying quiet, and a
                // client of this extension expects it to be optional.
                if let Some(dark) = self.dark_scheme {
                    let v = if dark { 2 } else { 1 };
                    self.response.push_str(&format!("\x1b[?997;{v}n"));
                }
            }

            _ => return false,
        }

        true
    }

    /// The cursor position as a report should carry it: 1-based, and
    /// region-relative under origin mode.
    ///
    /// The cursor can sit outside the region — enabling DECOM does not move
    /// it, and margins can be set under it — so both axes saturate and clamp
    /// to 1 rather than underflow.
    pub(super) fn reported_cursor(&self) -> (usize, usize) {
        if self.modes.origin_mode {
            (
                (self.cursor.row + 1).saturating_sub(self.scroll_top).max(1),
                (self.cursor.col + 1)
                    .saturating_sub(self.h_margins().0)
                    .max(1),
            )
        } else {
            (self.cursor.row + 1, self.cursor.col + 1)
        }
    }
}
