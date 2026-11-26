/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! The host setting `bold-is-bright`: bold text in one of the eight basic
//! colours is drawn in its bright counterpart, as Terminal.app, iTerm2,
//! Alacritty and Ghostty can.

use super::Palette;

impl Palette {
    /// Whether bold text in a basic colour (0-7) draws in its bright pair.
    pub fn bold_is_bright(&self) -> bool {
        self.bold_is_bright
    }

    /// Host setting `bold-is-bright`. Off by default; programs cannot set it.
    pub fn set_bold_is_bright(&mut self, enabled: bool) {
        self.bold_is_bright = enabled;
    }

    /// Takes `other`'s host settings: a reset or a restored checkpoint keeps
    /// what the host configured.
    pub(crate) fn keep_host_settings(&mut self, other: &Palette) {
        self.bold_is_bright = other.bold_is_bright;
    }

    /// The palette entry a cell's indexed foreground is drawn with: `index`
    /// itself, or with `bold-is-bright` on and a bold cell in colour 0-7,
    /// its bright counterpart `index + 8`. Entries 8-255, the default
    /// foreground and RGB colours are never changed.
    pub fn foreground_index(&self, index: u8, bold: bool) -> u8 {
        if self.bold_is_bright && bold && index < 8 {
            index + 8
        } else {
            index
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Palette;

    #[test]
    fn off_by_default_keeps_every_index() {
        let palette = Palette::new();
        assert!(!palette.bold_is_bright());
        for index in 0..=255u8 {
            assert_eq!(palette.foreground_index(index, true), index);
            assert_eq!(palette.foreground_index(index, false), index);
        }
    }

    #[test]
    fn on_brightens_only_bold_basic_colours() {
        let mut palette = Palette::new();
        palette.set_bold_is_bright(true);
        for index in 0..8u8 {
            assert_eq!(palette.foreground_index(index, true), index + 8);
            assert_eq!(palette.foreground_index(index, false), index);
        }
        for index in 8..=255u8 {
            assert_eq!(palette.foreground_index(index, true), index);
        }
    }

    #[test]
    fn a_checkpoint_palette_starts_off() {
        let mut palette = Palette::new();
        palette.set_bold_is_bright(true);
        let restored = Palette::from_colors(*palette.colors());
        assert!(!restored.bold_is_bright());
    }
}
