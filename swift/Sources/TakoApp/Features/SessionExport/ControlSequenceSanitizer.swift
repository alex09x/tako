/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Sanitizer that strips all escape sequences and dangerous control characters
/// from untrusted scrollback text before restoring into a terminal session (C9).
public enum ControlSequenceSanitizer {

    /// Drops all ANSI/VT escape sequences (CSI, OSC, DCS, APC, PM, Esc-single),
    /// DEL characters, and non-printable control codes (< 0x20 except \n, \r, \t).
    public static func dropControlSequences(from text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        while i < n {
            let s = scalars[i]
            if s.value == 0x1B { // ESC (0x1B)
                i += 1
                if i >= n { break }
                let next = scalars[i]
                if next.value == 0x5B { // '[' CSI (Control Sequence Introducer)
                    i += 1
                    // Parameter bytes: 0x30–0x3F ('0'–'?')
                    // Intermediate bytes: 0x20–0x2F (' '–'/')
                    while i < n && scalars[i].value >= 0x20 && scalars[i].value <= 0x3F {
                        i += 1
                    }
                    // Final byte: 0x40–0x7E ('@'–'~')
                    if i < n && scalars[i].value >= 0x40 && scalars[i].value <= 0x7E {
                        i += 1
                    }
                } else if next.value == 0x5D { // ']' OSC (Operating System Command)
                    i += 1
                    // Consume until String Terminator: ST (\u{1b}\) or BEL (\u{07})
                    while i < n {
                        if scalars[i].value == 0x07 {
                            i += 1
                            break
                        } else if scalars[i].value == 0x1B && i + 1 < n && scalars[i + 1].value == 0x5C {
                            i += 2
                            break
                        }
                        i += 1
                    }
                } else if next.value == 0x50 || next.value == 0x5F || next.value == 0x5E {
                    // 'P' DCS, '_' APC, '^' PM
                    i += 1
                    // Consume until String Terminator: ST (\u{1b}\) or BEL (\u{07})
                    while i < n {
                        if scalars[i].value == 0x07 {
                            i += 1
                            break
                        } else if scalars[i].value == 0x1B && i + 1 < n && scalars[i + 1].value == 0x5C {
                            i += 2
                            break
                        }
                        i += 1
                    }
                } else if next.value == 0x28 || next.value == 0x29 || next.value == 0x2A || next.value == 0x2B {
                    // Character set designation (e.g. Esc ( B, Esc ) 0)
                    i += 1
                    if i < n { i += 1 }
                } else {
                    // Single character escape (e.g. Esc M, Esc c, Esc =, Esc >)
                    i += 1
                }
            } else if s.value < 0x20 {
                // Drop all C0 control characters EXCEPT safe whitespace: \n (0x0A), \r (0x0D), \t (0x09)
                if s.value == 0x0A || s.value == 0x0D || s.value == 0x09 {
                    result.append(Character(s))
                }
                i += 1
            } else if (s.value >= 0x80 && s.value <= 0x9F) || s.value == 0x7F {
                // Drop DEL (0x7F) and 8-bit C1 controls (0x80–0x9F, e.g. 0x9B CSI, 0x9D OSC)
                i += 1
            } else {
                result.append(Character(s))
                i += 1
            }
        }

        return result
    }
}
