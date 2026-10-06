/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! C ABI for hosts that link the engine directly (a Go service over cgo is
//! the first consumer; the `prod_vt_*` names are its header's).
//!
//! Ownership rules: every `*_out` buffer is
//! heap-allocated here and must be released with [`prod_vt_buffer_free`];
//! the handle from [`prod_vt_new`] must be released with
//! [`prod_vt_free`]. Every function tolerates NULL pointers by returning
//! failure (0) rather than dereferencing them.
//!
//! These are C entry points: the pointer contract above is the C caller's,
//! documented here rather than expressed as `unsafe fn`, which would change
//! nothing for C and only burden the Rust tests that drive the ABI.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod checkpoint;
pub mod checkpoint_v2;
pub mod render;
pub mod snapshot;
pub mod terminal;
pub mod types;

pub use checkpoint::*;
pub use checkpoint_v2::*;
pub use snapshot::*;
pub use terminal::*;
pub use types::*;

#[cfg(test)]
mod tests;
