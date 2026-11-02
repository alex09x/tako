/*
 * tako — Replace host palette bases without discarding program colors
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{Palette, default_color};

impl Palette {
    /// A host theme is a replacement, including entries it leaves at the
    /// built-in default. OSC overrides keep their live values until reset.
    pub(crate) fn replace_base(&mut self, entries: &[(u8, (u8, u8, u8))]) {
        for index in 0..=u8::MAX {
            self.set_base(index, default_color(index));
        }
        for &(index, rgb) in entries {
            self.set_base(index, rgb);
        }
    }
}
