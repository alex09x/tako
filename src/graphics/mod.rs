/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Kitty Graphics Protocol support.
//!
//! Upstream speaks the Kitty Graphics Protocol
//! (<https://sw.kovidgoyal.net/kitty/graphics-protocol/>) over APC escape
//! sequences of the form:
//!
//! ```text
//! ESC _ G <control-data> ; <payload> ESC \
//! ```
//!
//! where `<control-data>` is a comma-separated list of `key=value` pairs and
//! `<payload>` is (for the direct transmission medium) base64-encoded image
//! data.
//!
//! This module is deliberately grid-agnostic: it only owns the image store,
//! the placement records, and the chunk-assembly buffers. Escape-sequence
//! framing lives in the parser, which hands us the already-split control data
//! and payload bytes.
//!
//! Coverage is the core transmit/display/delete flow. Animation frames
//! (`a=f`/`a=a`), shared-memory (`t=s`) and file-based (`t=f`/`t=t`)
//! transmission are not implemented; they are reported as
//! [`GraphicsResponse::Unsupported`] rather than treated as an error.

pub mod commands;
pub mod dimensions;
pub mod state;
pub mod types;

pub use dimensions::*;
pub use state::*;
pub use types::*;

#[cfg(test)]
mod tests;
