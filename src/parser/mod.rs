/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
mod advance;
mod ascii;
mod strings;
mod types;

use ascii::scan_printable_ascii_run;
pub use types::{
    MAX_APC_RAW_BYTES, MAX_OSC_PARAMS, MAX_OSC_RAW_BYTES, ParserSnapshot, ParserView, Perform,
    State,
};

pub struct Parser {
    pub state: State,
    pub(super) intermediates: smallvec::SmallVec<[u8; 2]>,
    pub(super) params: smallvec::SmallVec<[u16; 16]>,
    pub(super) params_sep: u32, // Bitset: 1 if preceded by ':', 0 if ';'
    pub(super) ignore: bool,
    pub(super) osc_raw: Vec<u8>,
    pub(super) apc_raw: Vec<u8>,
    pub(super) utf8_need: u8,
    pub(super) utf8_cp: u32,
}

impl Default for Parser {
    fn default() -> Self {
        Self::new()
    }
}

impl Parser {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            intermediates: smallvec::SmallVec::new(),
            params: smallvec::SmallVec::new(),
            params_sep: 0,
            ignore: false,
            osc_raw: Vec::new(),
            apc_raw: Vec::new(),
            utf8_need: 0,
            utf8_cp: 0,
        }
    }

    #[inline(always)]
    pub(super) fn push_osc(&mut self, byte: u8) {
        if self.osc_raw.len() < MAX_OSC_RAW_BYTES {
            self.osc_raw.push(byte);
        }
    }

    #[inline(always)]
    pub(super) fn push_apc(&mut self, byte: u8) {
        if self.apc_raw.len() < MAX_APC_RAW_BYTES {
            self.apc_raw.push(byte);
        }
    }

    /// The same state [`Self::snapshot`] copies, borrowed instead of cloned.
    ///
    /// `snapshot` exists to be *stored*, so it owns its buffers. Measuring or
    /// serializing a checkpoint only reads them, and an in-flight OSC or APC
    /// payload is bounded by nothing but the host's input -- so going through
    /// `snapshot` there made the cost of asking "how big is this checkpoint?"
    /// proportional to the payload. This view costs nothing.
    pub fn view(&self) -> ParserView<'_> {
        ParserView {
            state: self.state,
            intermediates: &self.intermediates,
            params: &self.params,
            params_sep: self.params_sep,
            ignore: self.ignore,
            osc_raw: &self.osc_raw,
            apc_raw: &self.apc_raw,
            utf8_need: self.utf8_need,
            utf8_cp: self.utf8_cp,
        }
    }

    /// Heap this parser holds, counted by *capacity* rather than length.
    ///
    /// `osc_raw` and `apc_raw` are cleared with `Vec::clear`, which drops the
    /// length and keeps the allocation: a parser that has just finished an
    /// 8 MiB OSC still owns 8 MiB of heap while reporting a length of zero.
    /// Anything reasoning about the memory a live terminal occupies has to ask
    /// this, not `len()`.
    pub fn retained_capacity_bytes(&self) -> u64 {
        let inter = if self.intermediates.spilled() {
            self.intermediates.capacity() as u64
        } else {
            0
        };
        let params = if self.params.spilled() {
            (self.params.capacity() as u64).saturating_mul(2)
        } else {
            0
        };
        (self.osc_raw.capacity() as u64)
            .saturating_add(self.apc_raw.capacity() as u64)
            .saturating_add(inter)
            .saturating_add(params)
    }

    pub fn snapshot(&self) -> ParserSnapshot {
        ParserSnapshot {
            state: self.state,
            intermediates: self.intermediates.clone(),
            params: self.params.clone(),
            params_sep: self.params_sep,
            ignore: self.ignore,
            osc_raw: self.osc_raw.clone(),
            apc_raw: self.apc_raw.clone(),
            utf8_need: self.utf8_need,
            utf8_cp: self.utf8_cp,
        }
    }

    pub fn restore(&mut self, snap: ParserSnapshot) {
        self.state = snap.state;
        self.intermediates = snap.intermediates;
        self.params = snap.params;
        self.params_sep = snap.params_sep;
        self.ignore = snap.ignore;
        self.osc_raw = snap.osc_raw;
        self.apc_raw = snap.apc_raw;
        self.utf8_need = snap.utf8_need;
        self.utf8_cp = snap.utf8_cp;
    }

    pub(super) fn push_param(&mut self, digit: u8) {
        let val = (digit - b'0') as u16;
        if let Some(last) = self.params.last_mut() {
            *last = last.saturating_mul(10).saturating_add(val);
        } else {
            self.params.push(val);
        }
    }

    pub(super) fn new_param(&mut self, is_colon: bool) {
        if self.params.is_empty() {
            self.params.push(0);
        }
        if self.params.len() < 16 {
            if is_colon {
                self.params_sep |= 1 << (self.params.len() - 1);
            }
            self.params.push(0);
        }
    }

    pub(super) fn push_intermediate(&mut self, byte: u8) {
        if self.intermediates.len() < 16 {
            self.intermediates.push(byte);
        } else {
            self.ignore = true;
        }
    }

    pub(super) fn clear(&mut self) {
        self.intermediates.clear();
        self.params.clear();
        self.params_sep = 0;
        self.ignore = false;
        self.utf8_need = 0;
    }

    #[inline]
    pub(super) fn reset_osc_buffer(&mut self) {
        if self.osc_raw.capacity() > 64 * 1024 {
            self.osc_raw = Vec::new();
        } else {
            self.osc_raw.clear();
        }
    }

    #[inline]
    pub(super) fn reset_apc_buffer(&mut self) {
        if self.apc_raw.capacity() > 64 * 1024 {
            self.apc_raw = Vec::new();
        } else {
            self.apc_raw.clear();
        }
    }

    /// Advance through a byte slice, batching printable ASCII while the
    /// parser is in its ground state. Escape/control/UTF-8 boundaries still
    /// go through `advance`, so parser state and error handling are identical
    /// to feeding one byte at a time.
    pub fn advance_bytes<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) {
        let mut offset = 0;
        while offset < bytes.len() {
            if self.state == State::Ground && self.utf8_need == 0 {
                let start = offset;
                offset = Self::printable_ascii_run_end(bytes, offset);
                if offset - start > 1 {
                    performer.print_slice(&bytes[start..offset]);
                    continue;
                }
                offset = start;
            }

            self.advance(performer, bytes[offset]);
            offset += 1;
        }
    }

    #[inline(always)]
    fn printable_ascii_run_end(bytes: &[u8], start: usize) -> usize {
        scan_printable_ascii_run(bytes, start)
    }

    pub(super) fn dispatch_osc<P: Perform>(&mut self, performer: &mut P, bell: bool) {
        let mut params = Vec::new();
        let mut current_start = 0;
        let mut excess = false;
        for (i, &b) in self.osc_raw.iter().enumerate() {
            if b == b';' {
                if params.len() >= MAX_OSC_PARAMS {
                    excess = true;
                    break;
                }
                params.push(&self.osc_raw[current_start..i]);
                current_start = i + 1;
            }
        }
        if !excess && current_start <= self.osc_raw.len() {
            if params.len() >= MAX_OSC_PARAMS {
                excess = true;
            } else {
                params.push(&self.osc_raw[current_start..]);
            }
        }
        if !excess {
            performer.osc_dispatch(&params, bell);
        }
        self.reset_osc_buffer();
    }

    pub(super) fn dispatch_apc<P: Perform>(&mut self, performer: &mut P) {
        performer.apc_dispatch(&self.apc_raw);
        self.reset_apc_buffer();
    }
}

#[cfg(test)]
mod tests;
