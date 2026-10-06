/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::Terminal;

/// Feeds `input` to a `cols` x `rows` terminal and checks the screen and the
/// cursor, as (row, column).
#[track_caller]
pub(crate) fn check(
    cols: usize,
    rows: usize,
    input: &[&str],
    want: &[&str],
    cursor: (usize, usize),
) {
    let mut term = Terminal::new(cols, rows);
    for part in input {
        term.feed(part.as_bytes());
    }
    let screen: Vec<String> = (0..rows)
        .map(|r| {
            term.viewport_row(r)
                .iter()
                .filter(|c| !c.is_wide_spacer)
                .map(|c| if c.char == '\0' { ' ' } else { c.char })
                .collect()
        })
        .collect();
    let want: Vec<String> = want.iter().map(|s| s.to_string()).collect();
    assert_eq!(screen, want, "screen");
    assert_eq!(term.cursor(), cursor, "cursor (row, column)");
}
