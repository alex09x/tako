/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#![cfg(feature = "ssh")]

#[cfg(feature = "ssh")]
mod algorithms;
#[cfg(feature = "ssh")]
mod host_and_auth;
#[cfg(feature = "ssh")]
mod server;
#[cfg(feature = "ssh")]
mod session_lifecycle;
