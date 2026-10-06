/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/// `params[idx]`, defaulting to `default` when absent. Used where an
/// explicit `0` is meaningful (e.g. erase-in-display/-line).
#[inline]
pub(crate) fn param_or_default(params: &[u16], idx: usize, default: u16) -> u16 {
    params.get(idx).copied().unwrap_or(default)
}

/// `params[idx]`, defaulting to `default` when absent *or* explicitly `0`
/// (xterm treats an explicit 0 the same as "not given" for these).
#[inline]
pub(crate) fn param_nonzero_or(params: &[u16], idx: usize, default: u16) -> u16 {
    match params.get(idx).copied() {
        Some(0) | None => default,
        Some(v) => v,
    }
}
