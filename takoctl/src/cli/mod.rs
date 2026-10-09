/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

mod control;
mod diagnose;
mod helpers;
mod inspect;
mod layout;
mod parser;
mod review;
mod session;
mod types;
mod usage;

pub use helpers::{answer_limit, parse_duration, request, resolve_token};
pub use inspect::resolve;
pub use parser::parse;
pub use types::Options;
pub use usage::USAGE;
