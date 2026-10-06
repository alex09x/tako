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
    pub fn advance<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        let mut transition = None;
        let mut execute = false;

        match self.state {
            State::Ground => {
                if byte < 0x80 {
                    // A control/ASCII byte abandons any in-flight UTF-8
                    // sequence rather than corrupting the next one.
                    self.utf8_need = 0;
                }
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                    0x18 | 0x1A => {
                        execute = true;
                        transition = Some(State::Ground);
                    }
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x7F => performer.print(byte as char),
                    0xC2..=0xDF => {
                        self.utf8_need = 1;
                        self.utf8_cp = (byte & 0x1F) as u32;
                    }
                    0xE0..=0xEF => {
                        self.utf8_need = 2;
                        self.utf8_cp = (byte & 0x0F) as u32;
                    }
                    0xF0..=0xF4 => {
                        self.utf8_need = 3;
                        self.utf8_cp = (byte & 0x07) as u32;
                    }
                    0x80..=0xBF => {
                        if self.utf8_need > 0 {
                            self.utf8_cp = (self.utf8_cp << 6) | (byte & 0x3F) as u32;
                            self.utf8_need -= 1;
                            if self.utf8_need == 0 {
                                performer.print(char::from_u32(self.utf8_cp).unwrap_or('\u{FFFD}'));
                            }
                        } else {
                            performer.print('\u{FFFD}');
                        }
                    }
                    _ => performer.print('\u{FFFD}'), // 0xC0, 0xC1, 0xF5..=0xFF: invalid lead bytes.
                }
            }
            State::Escape => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                0x18 | 0x1A => {
                    execute = true;
                    transition = Some(State::Ground);
                }
                0x1B => transition = Some(State::Escape),
                0x20..=0x2F => {
                    self.push_intermediate(byte);
                    transition = Some(State::EscapeIntermediate);
                }
                0x30..=0x4F | 0x51..=0x57 | 0x59 | 0x5A | 0x5C | 0x60..=0x7E => {
                    performer.esc_dispatch(&self.intermediates, self.ignore, byte);
                    transition = Some(State::Ground);
                }
                0x50 => transition = Some(State::DcsEntry),
                0x5B => transition = Some(State::CsiEntry),
                0x5D => transition = Some(State::OscString),
                0x58 | 0x5E | 0x5F => transition = Some(State::SosPmApcString),
                _ => transition = Some(State::Ground),
            },
            State::EscapeIntermediate => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                0x18 | 0x1A => {
                    execute = true;
                    transition = Some(State::Ground);
                }
                0x1B => transition = Some(State::Escape),
                0x20..=0x2F => self.push_intermediate(byte),
                0x30..=0x7E => {
                    performer.esc_dispatch(&self.intermediates, self.ignore, byte);
                    transition = Some(State::Ground);
                }
                _ => transition = Some(State::Ground),
            },
            State::CsiEntry => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                0x18 | 0x1A => {
                    execute = true;
                    transition = Some(State::Ground);
                }
                0x1B => transition = Some(State::Escape),
                0x20..=0x2F => {
                    self.push_intermediate(byte);
                    transition = Some(State::CsiIntermediate);
                }
                0x30..=0x39 => {
                    self.params.push((byte - b'0') as u16);
                    transition = Some(State::CsiParam);
                }
                0x3A => {
                    self.new_param(true);
                    transition = Some(State::CsiParam);
                }
                0x3B => {
                    self.new_param(false);
                    transition = Some(State::CsiParam);
                }
                0x3C..=0x3F => {
                    self.push_intermediate(byte);
                    transition = Some(State::CsiParam);
                }
                0x40..=0x7E => {
                    performer.csi_dispatch(
                        &self.params,
                        self.params_sep,
                        &self.intermediates,
                        self.ignore,
                        byte as char,
                    );
                    transition = Some(State::Ground);
                }
                _ => transition = Some(State::Ground),
            },
            State::CsiParam => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                0x18 | 0x1A => {
                    execute = true;
                    transition = Some(State::Ground);
                }
                0x1B => transition = Some(State::Escape),
                0x20..=0x2F => {
                    self.push_intermediate(byte);
                    transition = Some(State::CsiIntermediate);
                }
                0x30..=0x39 => self.push_param(byte),
                0x3A => self.new_param(true),
                0x3B => self.new_param(false),
                0x3C..=0x3F => self.ignore = true,
                0x40..=0x7E => {
                    performer.csi_dispatch(
                        &self.params,
                        self.params_sep,
                        &self.intermediates,
                        self.ignore,
                        byte as char,
                    );
                    transition = Some(State::Ground);
                }
                _ => transition = Some(State::Ground),
            },
            State::CsiIntermediate => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                0x18 | 0x1A => {
                    execute = true;
                    transition = Some(State::Ground);
                }
                0x1B => transition = Some(State::Escape),
                0x20..=0x2F => self.push_intermediate(byte),
                0x30..=0x3F => self.ignore = true,
                0x40..=0x7E => {
                    performer.csi_dispatch(
                        &self.params,
                        self.params_sep,
                        &self.intermediates,
                        self.ignore,
                        byte as char,
                    );
                    transition = Some(State::Ground);
                }
                _ => transition = Some(State::Ground),
            },
            State::DcsEntry => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => transition = None, // ignore
                    0x18 | 0x1A | 0x1B => {
                        transition = Some(State::Escape);
                    }
                    0x20..=0x2F => {
                        self.push_intermediate(byte);
                        transition = Some(State::DcsIntermediate);
                    }
                    0x30..=0x39 => {
                        self.params.push((byte - b'0') as u16);
                        transition = Some(State::DcsParam);
                    }
                    0x3A | 0x3B => {
                        self.new_param(byte == 0x3A);
                        transition = Some(State::DcsParam);
                    }
                    0x3C..=0x3F => {
                        self.push_intermediate(byte);
                        transition = Some(State::DcsParam);
                    }
                    0x40..=0x7E => {
                        performer.hook(
                            &self.params,
                            self.params_sep,
                            &self.intermediates,
                            self.ignore,
                            byte as char,
                        );
                        transition = Some(State::DcsPassthrough);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::DcsParam => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => transition = None,
                0x18 | 0x1A | 0x1B => transition = Some(State::Escape),
                0x20..=0x2F => {
                    self.push_intermediate(byte);
                    transition = Some(State::DcsIntermediate);
                }
                0x30..=0x39 => self.push_param(byte),
                0x3A => self.new_param(true),
                0x3B => self.new_param(false),
                0x3C..=0x3F => self.ignore = true,
                0x40..=0x7E => {
                    performer.hook(
                        &self.params,
                        self.params_sep,
                        &self.intermediates,
                        self.ignore,
                        byte as char,
                    );
                    transition = Some(State::DcsPassthrough);
                }
                _ => transition = Some(State::Ground),
            },
            State::DcsIntermediate => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => transition = None,
                0x18 | 0x1A | 0x1B => transition = Some(State::Escape),
                0x20..=0x2F => self.push_intermediate(byte),
                0x30..=0x3F => self.ignore = true,
                0x40..=0x7E => {
                    performer.hook(
                        &self.params,
                        self.params_sep,
                        &self.intermediates,
                        self.ignore,
                        byte as char,
                    );
                    transition = Some(State::DcsPassthrough);
                }
                _ => transition = Some(State::Ground),
            },
            State::DcsPassthrough => match byte {
                0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.put(byte),
                0x18 | 0x1A => transition = Some(State::Ground),
                0x1B => transition = Some(State::Escape),
                0x20..=0x7E => performer.put(byte),
                _ => transition = Some(State::Ground),
            },
            State::DcsIgnore => match byte {
                0x18 | 0x1A => transition = Some(State::Ground),
                0x1B => transition = Some(State::Escape),
                _ => transition = None,
            },
            State::OscString => {
                transition = self.advance_osc(performer, byte);
            }
            State::SosPmApcString => {
                transition = self.advance_apc(performer, byte);
            }
            _ => transition = Some(State::Ground),
        }

        if execute {
            performer.execute(byte);
        }

        if let Some(next_state) = transition {
            // Exit actions
            if self.state == State::DcsPassthrough {
                performer.unhook();
            } else if self.state == State::OscString {
                if next_state == State::Escape {
                    // ST is ESC \. We will parse the '\' in Escape state, but Osc might be dispatched
                    self.dispatch_osc(performer, false);
                } else {
                    self.reset_osc_buffer();
                }
            } else if self.state == State::SosPmApcString {
                if next_state == State::Escape {
                    self.dispatch_apc(performer);
                } else {
                    self.reset_apc_buffer();
                }
            }

            // Enter actions
            if next_state == State::Escape
                || next_state == State::CsiEntry
                || next_state == State::DcsEntry
                || next_state == State::OscString
                || next_state == State::SosPmApcString
            {
                self.clear();
            }
            if next_state == State::OscString {
                self.reset_osc_buffer();
                self.utf8_need = 0;
            }
            if next_state == State::SosPmApcString {
                self.reset_apc_buffer();
                self.utf8_need = 0;
            }

            self.state = next_state;
        }
    }
}
