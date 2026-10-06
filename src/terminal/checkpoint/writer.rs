/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::HEADER_SIZE;
use crate::grid::{Cell, Color};

pub struct Writer {
    pub(crate) buf: Vec<u8>,
    pub(crate) count: usize,
    pub(crate) limit: usize,
    pub(crate) retain: bool,
}

impl Writer {
    /// `limit` bounds the WHOLE container -- header included.
    pub fn with_capacity(cap: usize, limit: usize) -> Self {
        Self {
            buf: Vec::with_capacity(cap.min(limit)),
            count: 0,
            limit,
            retain: true,
        }
    }

    /// A writer that keeps nothing. Measures a container without ever holding one.
    pub fn counting(limit: usize) -> Self {
        Self {
            buf: Vec::new(),
            count: 0,
            limit,
            retain: false,
        }
    }

    /// Reserve the container header slot and charge it to the count.
    pub fn reserve_header(&mut self) {
        self.count = HEADER_SIZE;
        if self.retain && HEADER_SIZE <= self.limit {
            self.buf.resize(HEADER_SIZE, 0);
        }
    }

    #[inline]
    pub fn push(&mut self, bytes: &[u8]) {
        let next = self.count.saturating_add(bytes.len());
        if self.retain && next <= self.limit {
            self.buf.extend_from_slice(bytes);
        }
        self.count = next;
    }

    #[inline]
    pub fn overflowed(&self) -> bool {
        self.count > self.limit
    }

    #[inline]
    pub fn write_u8(&mut self, val: u8) {
        self.push(&[val]);
    }

    #[inline]
    pub fn write_u16(&mut self, val: u16) {
        self.push(&val.to_le_bytes());
    }

    #[inline]
    pub fn write_u32(&mut self, val: u32) {
        self.push(&val.to_le_bytes());
    }

    #[inline]
    pub fn write_u64(&mut self, val: u64) {
        self.push(&val.to_le_bytes());
    }

    #[inline]
    pub fn write_bool(&mut self, val: bool) {
        self.write_u8(if val { 1 } else { 0 });
    }

    pub fn write_bytes(&mut self, bytes: &[u8]) {
        self.write_u32(bytes.len() as u32);
        self.push(bytes);
    }

    pub fn write_string(&mut self, s: &str) {
        self.write_bytes(s.as_bytes());
    }

    pub fn write_color(&mut self, c: Color) {
        match c {
            Color::Default => self.write_u8(0),
            Color::Indexed(n) => {
                self.write_u8(1);
                self.write_u8(n);
            }
            Color::Rgb(r, g, b) => {
                self.write_u8(2);
                self.write_u8(r);
                self.write_u8(g);
                self.write_u8(b);
            }
        }
    }

    pub fn write_single_cell_content(&mut self, cell: &Cell) {
        self.write_u32(cell.char as u32);
        self.write_color(cell.fg);
        self.write_color(cell.bg);
        self.write_u16(cell.attrs.bits());
        let mut flags = 0u8;
        if cell.is_wide_spacer {
            flags |= 1 << 0;
        }
        if cell.protected {
            flags |= 1 << 1;
        }
        if cell.is_wide_spacer_head {
            flags |= 1 << 2;
        }
        if cell.underline_color != Color::Default {
            flags |= 1 << 3;
        }
        if cell.hyperlink.is_some() {
            flags |= 1 << 4;
        }
        self.write_u8(flags);
        self.write_u8(cell.underline_style);
        if cell.underline_color != Color::Default {
            self.write_color(cell.underline_color);
        }
        if let Some(id) = cell.hyperlink {
            self.write_u32(id);
        }
    }

    pub fn write_cells(&mut self, cells: &[Cell]) {
        let mut idx = 0;
        let default_cell = Cell::default();
        while idx < cells.len() {
            let cell = &cells[idx];
            if *cell == default_cell {
                let start = idx;
                while idx < cells.len() && cells[idx] == default_cell && (idx - start) < 65535 {
                    idx += 1;
                }
                let count = idx - start;
                if count == 1 {
                    self.write_u8(0x00);
                } else {
                    self.write_u8(0x01);
                    self.write_u16(count as u16);
                }
            } else {
                let start = idx;
                while idx < cells.len() && cells[idx] == *cell && (idx - start) < 65535 {
                    idx += 1;
                }
                let count = idx - start;
                if count == 1 {
                    self.write_u8(0x02);
                    self.write_single_cell_content(cell);
                } else {
                    self.write_u8(0x03);
                    self.write_u16(count as u16);
                    self.write_single_cell_content(cell);
                }
            }
        }
    }
}
