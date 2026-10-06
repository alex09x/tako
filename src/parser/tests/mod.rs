/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

mod batch;
mod dispatch;
mod osc;
mod utf8;

use crate::parser::*;

#[derive(Debug, PartialEq, Clone)]
pub enum Action {
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

pub struct MockPerformer {
    pub actions: Vec<Action>,
}

impl Perform for MockPerformer {
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

pub(crate) fn parse_str(s: &str) -> MockPerformer {
    let mut parser = Parser::new();
    let mut performer = MockPerformer {
        actions: Vec::new(),
    };
    for b in s.bytes() {
        parser.advance(&mut performer, b);
    }
    performer
}
