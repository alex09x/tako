/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub(crate) use tako_core::parser::{Parser, ParserSnapshot, Perform, State};
pub(crate) use tako_core::terminal::Terminal;

/// Action recorded by the test performer.
#[derive(Debug, PartialEq, Clone)]
pub(crate) enum Action {
    Print(char),
    PrintSlice(Vec<u8>),
    Execute(u8),
    Hook(Vec<u16>, u32, Vec<u8>, bool, char),
    Put(u8),
    Unhook,
    OscDispatch(Vec<Vec<u8>>, bool),
    CsiDispatch(Vec<u16>, u32, Vec<u8>, bool, char),
    EscDispatch(Vec<u8>, bool, u8),
    ApcDispatch(Vec<u8>),
}

/// A full recording performer that captures all callbacks including batch print and APC.
#[derive(Default)]
pub(crate) struct TestPerformer {
    pub(crate) actions: Vec<Action>,
}

impl Perform for TestPerformer {
    fn print(&mut self, c: char) {
        self.actions.push(Action::Print(c));
    }
    fn print_slice(&mut self, bytes: &[u8]) {
        self.actions.push(Action::PrintSlice(bytes.to_vec()));
    }
    fn execute(&mut self, byte: u8) {
        self.actions.push(Action::Execute(byte));
    }
    fn hook(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        self.actions.push(Action::Hook(
            params.to_vec(),
            params_sep,
            intermediates.to_vec(),
            ignore,
            action,
        ));
    }
    fn put(&mut self, byte: u8) {
        self.actions.push(Action::Put(byte));
    }
    fn unhook(&mut self) {
        self.actions.push(Action::Unhook);
    }
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        self.actions.push(Action::OscDispatch(
            params.iter().map(|s| s.to_vec()).collect(),
            bell_terminated,
        ));
    }
    fn csi_dispatch(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        self.actions.push(Action::CsiDispatch(
            params.to_vec(),
            params_sep,
            intermediates.to_vec(),
            ignore,
            action,
        ));
    }
    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        self.actions
            .push(Action::EscDispatch(intermediates.to_vec(), ignore, byte));
    }
    fn apc_dispatch(&mut self, data: &[u8]) {
        self.actions.push(Action::ApcDispatch(data.to_vec()));
    }
}

/// A performer that uses default trait implementations for print_slice and apc_dispatch.
#[derive(Default)]
pub(crate) struct DefaultTraitPerformer {
    pub(crate) printed_chars: Vec<char>,
    pub(crate) _executed: Vec<u8>,
}

impl Perform for DefaultTraitPerformer {
    fn print(&mut self, c: char) {
        self.printed_chars.push(c);
    }
    fn execute(&mut self, byte: u8) {
        self._executed.push(byte);
    }
    fn hook(
        &mut self,
        _params: &[u16],
        _params_sep: u32,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}
    fn csi_dispatch(
        &mut self,
        _params: &[u16],
        _params_sep: u32,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }
    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}
}
