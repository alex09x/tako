/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/// Maximum raw byte length permitted in an in-flight OSC sequence buffer (16 MiB).
pub const MAX_OSC_RAW_BYTES: usize = 16 * 1024 * 1024;
/// Maximum raw byte length permitted in an in-flight APC sequence buffer (68 MiB, accommodating Kitty graphics transfers up to the 64 MiB memory cap).
pub const MAX_APC_RAW_BYTES: usize = 68 * 1024 * 1024;
/// Maximum number of parameters permitted in an OSC sequence (1024).
pub const MAX_OSC_PARAMS: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiParam,
    CsiIntermediate,
    CsiIgnore,
    DcsEntry,
    DcsParam,
    DcsIntermediate,
    DcsPassthrough,
    DcsIgnore,
    OscString,
    SosPmApcString,
}

pub trait Perform {
    fn print(&mut self, c: char);
    /// Print a contiguous run of ground-state ASCII bytes. Implementors may
    /// batch this; the default is exactly equivalent to `print` per byte.
    fn print_slice(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.print(byte as char);
        }
    }
    fn execute(&mut self, byte: u8);
    fn hook(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    );
    fn put(&mut self, byte: u8);
    fn unhook(&mut self);
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool);
    fn csi_dispatch(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    );
    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8);
    fn apc_dispatch(&mut self, data: &[u8]) {
        let _ = data;
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParserSnapshot {
    pub state: State,
    pub intermediates: smallvec::SmallVec<[u8; 2]>,
    pub params: smallvec::SmallVec<[u16; 16]>,
    pub params_sep: u32,
    pub ignore: bool,
    pub osc_raw: Vec<u8>,
    pub apc_raw: Vec<u8>,
    pub utf8_need: u8,
    pub utf8_cp: u32,
}

/// A borrowed read of [`Parser`]'s serializable state. Same fields as
/// [`ParserSnapshot`], none of its copies.
pub struct ParserView<'a> {
    pub state: State,
    pub intermediates: &'a [u8],
    pub params: &'a [u16],
    pub params_sep: u32,
    pub ignore: bool,
    pub osc_raw: &'a [u8],
    pub apc_raw: &'a [u8],
    pub utf8_need: u8,
    pub utf8_cp: u32,
}
