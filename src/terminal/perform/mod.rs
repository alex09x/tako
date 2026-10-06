/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub(crate) mod csi;
pub(crate) mod csi_private;
pub(crate) mod cursor_left;
pub(crate) mod execute;
pub(crate) mod osc;
pub(crate) mod osc_iterm;
pub(crate) mod osc_palette;
pub(crate) mod osc_shell;
pub(crate) mod params;
pub(crate) mod print;

use crate::parser::Perform;
use crate::terminal::state::Terminal;

impl Perform for Terminal {
    fn print(&mut self, ch: char) {
        self.perform_print(ch);
    }

    fn print_slice(&mut self, bytes: &[u8]) {
        self.perform_print_slice(bytes);
    }

    fn execute(&mut self, byte: u8) {
        self.perform_execute(byte);
    }

    fn hook(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        self.perform_hook(params, params_sep, intermediates, ignore, action);
    }

    fn put(&mut self, byte: u8) {
        self.perform_put(byte);
    }

    fn unhook(&mut self) {
        self.perform_unhook();
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        self.perform_osc_dispatch(params, bell_terminated);
    }

    fn csi_dispatch(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        csi::perform_csi_dispatch(self, params, params_sep, intermediates, ignore, action);
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        self.perform_esc_dispatch(intermediates, ignore, byte);
    }

    fn apc_dispatch(&mut self, data: &[u8]) {
        self.perform_apc_dispatch(data);
    }
}
