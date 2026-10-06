/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{Parser, Perform, State};

impl Parser {
    pub(super) fn advance_osc<P: Perform>(&mut self, performer: &mut P, byte: u8) -> Option<State> {
        match byte {
            0x07 => {
                self.utf8_need = 0;
                self.dispatch_osc(performer, true);
                Some(State::Ground)
            }
            0x18 | 0x1A => {
                self.utf8_need = 0;
                Some(State::Ground)
            }
            0x1B => {
                self.utf8_need = 0;
                Some(State::Escape)
            }
            0x20..=0x7F => {
                self.utf8_need = 0;
                self.push_osc(byte);
                None
            }
            0xC2..=0xDF => {
                self.utf8_need = 1;
                self.push_osc(byte);
                None
            }
            0xE0..=0xEF => {
                self.utf8_need = 2;
                self.push_osc(byte);
                None
            }
            0xF0..=0xF4 => {
                self.utf8_need = 3;
                self.push_osc(byte);
                None
            }
            0x80..=0xBF => {
                if self.utf8_need > 0 {
                    self.utf8_need -= 1;
                    self.push_osc(byte);
                    None
                } else if byte == 0x9C {
                    self.dispatch_osc(performer, false);
                    Some(State::Ground)
                } else {
                    self.push_osc(byte);
                    None
                }
            }
            _ => {
                self.utf8_need = 0;
                if byte >= 0x80 {
                    self.push_osc(byte);
                }
                None
            }
        }
    }

    pub(super) fn advance_apc<P: Perform>(&mut self, performer: &mut P, byte: u8) -> Option<State> {
        match byte {
            0x18 | 0x1A => {
                self.utf8_need = 0;
                Some(State::Ground)
            }
            0x1B => {
                self.utf8_need = 0;
                Some(State::Escape)
            }
            0x20..=0x7F => {
                self.utf8_need = 0;
                self.push_apc(byte);
                None
            }
            0xC2..=0xDF => {
                self.utf8_need = 1;
                self.push_apc(byte);
                None
            }
            0xE0..=0xEF => {
                self.utf8_need = 2;
                self.push_apc(byte);
                None
            }
            0xF0..=0xF4 => {
                self.utf8_need = 3;
                self.push_apc(byte);
                None
            }
            0x80..=0xBF => {
                if self.utf8_need > 0 {
                    self.utf8_need -= 1;
                    self.push_apc(byte);
                    None
                } else if byte == 0x9C {
                    self.dispatch_apc(performer);
                    Some(State::Ground)
                } else {
                    self.push_apc(byte);
                    None
                }
            }
            _ => {
                self.utf8_need = 0;
                if byte >= 0x80 {
                    self.push_apc(byte);
                }
                None
            }
        }
    }
}
