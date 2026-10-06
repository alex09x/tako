/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{CellAttrs, Color};
use crate::terminal::Terminal;

/// Render one row as ANSI: SGR runs plus the row's text.
pub(crate) fn row_ansi(term: &Terminal, row: usize, out: &mut Vec<u8>) {
    let cols = term.active_grid().cols();
    let cells = term.viewport_row(row);
    let mut last: Option<(Color, Color, CellAttrs)> = None;
    let mut trailing_blanks = 0usize;
    let mut line: Vec<u8> = Vec::with_capacity(cols * 2);
    for cell in cells.iter() {
        if cell.is_wide_spacer {
            continue;
        }
        let ch = if cell.char == '\0' { ' ' } else { cell.char };
        let style = (cell.fg, cell.bg, cell.attrs);
        if last != Some(style) {
            line.extend_from_slice(sgr_for(style).as_bytes());
            last = Some(style);
        }
        if ch == ' ' && cell.attrs.is_empty() && cell.bg == Color::Default {
            trailing_blanks += 1;
        } else {
            trailing_blanks = 0;
        }
        let mut buf = [0u8; 4];
        line.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
        line.extend_from_slice(term.active_grid().grapheme(cell).as_bytes());
    }
    // Trim trailing default-styled blanks; they carry no information and
    // bloat every frame the Go side ships to its UI.
    line.truncate(line.len() - trailing_blanks.min(line.len()));
    out.extend_from_slice(&line);
    if last.is_some() {
        out.extend_from_slice(b"\x1b[0m");
    }
}

pub(crate) fn sgr_for((fg, bg, attrs): (Color, Color, CellAttrs)) -> String {
    let mut parts: Vec<String> = vec!["0".into()];
    if attrs.contains(CellAttrs::BOLD) {
        parts.push("1".into());
    }
    if attrs.contains(CellAttrs::DIM) {
        parts.push("2".into());
    }
    if attrs.contains(CellAttrs::ITALIC) {
        parts.push("3".into());
    }
    if attrs.contains(CellAttrs::UNDERLINE) {
        parts.push("4".into());
    }
    if attrs.contains(CellAttrs::BLINK) {
        parts.push("5".into());
    }
    if attrs.contains(CellAttrs::REVERSE) {
        parts.push("7".into());
    }
    if attrs.contains(CellAttrs::HIDDEN) {
        parts.push("8".into());
    }
    if attrs.contains(CellAttrs::STRIKETHROUGH) {
        parts.push("9".into());
    }
    match fg {
        Color::Default => {}
        Color::Indexed(n) if n < 8 => parts.push((30 + n as u16).to_string()),
        Color::Indexed(n) if n < 16 => parts.push((90 + n as u16 - 8).to_string()),
        Color::Indexed(n) => parts.push(format!("38;5;{}", n)),
        Color::Rgb(r, g, b) => parts.push(format!("38;2;{};{};{}", r, g, b)),
    }
    match bg {
        Color::Default => {}
        Color::Indexed(n) if n < 8 => parts.push((40 + n as u16).to_string()),
        Color::Indexed(n) if n < 16 => parts.push((100 + n as u16 - 8).to_string()),
        Color::Indexed(n) => parts.push(format!("48;5;{}", n)),
        Color::Rgb(r, g, b) => parts.push(format!("48;2;{};{};{}", r, g, b)),
    }
    format!("\x1b[{}m", parts.join(";"))
}
