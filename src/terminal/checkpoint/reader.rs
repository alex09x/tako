/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::{CheckpointError, MAX_IMPORT_ALLOC_BYTES};
use crate::grid::{Cell, CellAttrs, Color};

pub struct Reader<'a> {
    pub(crate) data: &'a [u8],
    pub(crate) pos: usize,
    /// Heap bytes this import has committed to so far, across every field.
    pub(crate) alloc: u64,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self::with_reservation(data, 0)
    }

    /// A reader that starts the budget already partly spent.
    pub fn with_reservation(data: &'a [u8], reserved: u64) -> Self {
        Self {
            data,
            pos: 0,
            alloc: reserved,
        }
    }

    #[inline]
    pub fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    /// Charge `bytes` against the cumulative budget *before* the allocation
    /// they pay for is made.
    pub fn charge(&mut self, bytes: u64) -> Result<(), CheckpointError> {
        self.alloc = self.alloc.saturating_add(bytes);
        if self.alloc > MAX_IMPORT_ALLOC_BYTES {
            return Err(CheckpointError::AllocationLimitExceeded);
        }
        Ok(())
    }

    /// Charge a container's own spine: `count` elements at `per_element`
    /// bytes, before the container is reserved.
    pub fn charge_spine(&mut self, count: usize, per_element: u64) -> Result<(), CheckpointError> {
        self.charge((count as u64).saturating_mul(per_element))
    }

    /// A declared element count is only credible if the payload still holds
    /// the minimum encoding of that many elements.
    pub fn check_count(&self, count: usize, min_bytes_each: usize) -> Result<(), CheckpointError> {
        match count.checked_mul(min_bytes_each) {
            Some(needed) if needed <= self.remaining() => Ok(()),
            _ => Err(CheckpointError::UnexpectedEof),
        }
    }

    /// A length-prefixed byte string bounded by what is actually left in the
    /// payload and charged against the cumulative budget.
    pub fn read_bytes_budgeted(&mut self) -> Result<&'a [u8], CheckpointError> {
        let len = self.read_u32()? as usize;
        if len > self.remaining() {
            return Err(CheckpointError::UnexpectedEof);
        }
        self.charge(len as u64)?;
        let slice = &self.data[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }

    pub fn read_string_budgeted(&mut self) -> Result<String, CheckpointError> {
        let bytes = self.read_bytes_budgeted()?;
        String::from_utf8(bytes.to_vec())
            .map_err(|_| CheckpointError::InvalidData("non-utf8 string in checkpoint"))
    }

    pub fn read_u8(&mut self) -> Result<u8, CheckpointError> {
        if self.pos >= self.data.len() {
            return Err(CheckpointError::UnexpectedEof);
        }
        let val = self.data[self.pos];
        self.pos += 1;
        Ok(val)
    }

    pub fn read_u16(&mut self) -> Result<u16, CheckpointError> {
        if self.remaining() < 2 {
            return Err(CheckpointError::UnexpectedEof);
        }
        let bytes = [self.data[self.pos], self.data[self.pos + 1]];
        self.pos += 2;
        Ok(u16::from_le_bytes(bytes))
    }

    pub fn read_u32(&mut self) -> Result<u32, CheckpointError> {
        if self.remaining() < 4 {
            return Err(CheckpointError::UnexpectedEof);
        }
        let bytes = [
            self.data[self.pos],
            self.data[self.pos + 1],
            self.data[self.pos + 2],
            self.data[self.pos + 3],
        ];
        self.pos += 4;
        Ok(u32::from_le_bytes(bytes))
    }

    pub fn read_u64(&mut self) -> Result<u64, CheckpointError> {
        if self.remaining() < 8 {
            return Err(CheckpointError::UnexpectedEof);
        }
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&self.data[self.pos..self.pos + 8]);
        self.pos += 8;
        Ok(u64::from_le_bytes(bytes))
    }

    pub fn read_bool(&mut self) -> Result<bool, CheckpointError> {
        Ok(self.read_u8()? != 0)
    }

    pub fn read_exact_bytes(&mut self, len: usize) -> Result<&'a [u8], CheckpointError> {
        if self.remaining() < len {
            return Err(CheckpointError::UnexpectedEof);
        }
        let slice = &self.data[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }

    pub fn read_color(&mut self) -> Result<Color, CheckpointError> {
        match self.read_u8()? {
            0 => Ok(Color::Default),
            1 => {
                let n = self.read_u8()?;
                Ok(Color::Indexed(n))
            }
            2 => {
                let r = self.read_u8()?;
                let g = self.read_u8()?;
                let b = self.read_u8()?;
                Ok(Color::Rgb(r, g, b))
            }
            _ => Err(CheckpointError::InvalidData("invalid color tag")),
        }
    }

    pub fn read_single_cell_content(&mut self) -> Result<Cell, CheckpointError> {
        let cp = self.read_u32()?;
        let ch = char::from_u32(cp).unwrap_or('\0');
        let fg = self.read_color()?;
        let bg = self.read_color()?;
        let attrs_bits = self.read_u16()?;
        let attrs = CellAttrs::from_bits_truncate(attrs_bits);
        let flags = self.read_u8()?;
        let is_wide_spacer = (flags & (1 << 0)) != 0;
        let protected = (flags & (1 << 1)) != 0;
        let is_wide_spacer_head = (flags & (1 << 2)) != 0;
        let has_underline_color = (flags & (1 << 3)) != 0;
        let has_hyperlink = (flags & (1 << 4)) != 0;
        let underline_style = self.read_u8()?;
        let underline_color = if has_underline_color {
            self.read_color()?
        } else {
            Color::Default
        };
        let hyperlink = if has_hyperlink {
            Some(self.read_u32()?)
        } else {
            None
        };
        Ok(Cell {
            char: ch,
            fg,
            bg,
            attrs,
            hyperlink,
            is_wide_spacer,
            protected,
            is_wide_spacer_head,
            underline_style,
            underline_color,
            grapheme: 0,
        })
    }

    pub fn read_cells(&mut self, expected_len: usize) -> Result<Vec<Cell>, CheckpointError> {
        let mut cells = Vec::with_capacity(expected_len);
        let default_cell = Cell::default();
        while cells.len() < expected_len {
            match self.read_u8()? {
                0x00 => {
                    cells.push(default_cell);
                }
                0x01 => {
                    let count = self.read_u16()? as usize;
                    if count == 0 || cells.len() + count > expected_len {
                        return Err(CheckpointError::InvalidData("run length exceeds row width"));
                    }
                    cells.resize(cells.len() + count, default_cell);
                }
                0x02 => {
                    let cell = self.read_single_cell_content()?;
                    cells.push(cell);
                }
                0x03 => {
                    let count = self.read_u16()? as usize;
                    if count == 0 || cells.len() + count > expected_len {
                        return Err(CheckpointError::InvalidData("run length exceeds row width"));
                    }
                    let cell = self.read_single_cell_content()?;
                    cells.resize(cells.len() + count, cell);
                }
                _ => return Err(CheckpointError::InvalidData("unknown cell opcode")),
            }
        }
        if cells.len() != expected_len {
            return Err(CheckpointError::InvalidData(
                "cells decoded length mismatch",
            ));
        }
        Ok(cells)
    }
}
