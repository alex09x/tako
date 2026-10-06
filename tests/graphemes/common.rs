/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use tako_core::ffi::{
    FfiGraphemeWidthMethod, FfiSelectionMode, PACKED_CELL_SIZE, PACKED_GRAPHEME, TakoCore,
};
pub use tako_core::terminal::{GraphemeWidthMethod, SelectionMode, Terminal};

pub struct Kind {
    pub name: &'static str,
    pub text: &'static str,
    /// Columns under grapheme-width-method=unicode.
    pub width: usize,
    /// Columns under grapheme-width-method=legacy: each codepoint's wcwidth.
    pub legacy_width: usize,
}

pub const KINDS: &[Kind] = &[
    // Open e with a combining tilde: no precomposed form.
    Kind {
        name: "IPA",
        text: "\u{025B}\u{0303}",
        width: 1,
        legacy_width: 1,
    },
    // Shin with qamats and shin dot.
    Kind {
        name: "Hebrew points",
        text: "\u{05E9}\u{05B8}\u{05C1}",
        width: 1,
        legacy_width: 1,
    },
    // Ka with the spacing vowel sign i.
    Kind {
        name: "Devanagari sign",
        text: "\u{0915}\u{093F}",
        width: 1,
        legacy_width: 2,
    },
    Kind {
        name: "stacked marks",
        text: "z\u{0336}\u{0337}\u{0338}\u{0335}",
        width: 1,
        legacy_width: 1,
    },
    Kind {
        name: "variation selector",
        text: "\u{2764}\u{FE0F}",
        width: 2,
        legacy_width: 1,
    },
    Kind {
        name: "ZWJ sequence",
        text: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        width: 2,
        legacy_width: 6,
    },
    Kind {
        name: "skin tone",
        text: "\u{1F44D}\u{1F3FD}",
        width: 2,
        legacy_width: 4,
    },
    Kind {
        name: "flag",
        text: "\u{1F1FA}\u{1F1F8}",
        width: 2,
        legacy_width: 2,
    },
];

pub fn feed(t: &mut Terminal, s: &str) {
    t.feed(s.as_bytes());
}

/// The text of the cluster in `(row, col)`.
pub fn cell_text(t: &Terminal, row: usize, col: usize) -> String {
    let grid = t.active_grid();
    let cell = grid.get(row, col).unwrap();
    let mut out = String::new();
    grid.push_cell_text(&mut out, cell);
    out
}

/// One visible row as text, trailing blanks trimmed.
pub fn line(t: &Terminal, row: usize) -> String {
    t.dump_text().lines().nth(row).unwrap_or("").to_string()
}

pub fn for_each_kind(check: impl Fn(&Kind)) {
    for kind in KINDS {
        check(kind);
    }
}
