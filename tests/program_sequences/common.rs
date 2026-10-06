/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use tako_core::terminal::Terminal;

pub fn t(cols: usize, rows: usize) -> Terminal {
    Terminal::new(cols, rows)
}

pub fn feed(term: &mut Terminal, data: impl AsRef<[u8]>) {
    term.feed(data.as_ref());
    let _ = term.take_output();
}

pub fn feeds(term: &mut Terminal, data: impl AsRef<[u8]>) {
    feed(term, data);
}
