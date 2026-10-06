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
mod fixture;
#[cfg(feature = "ssh")]
mod interactive_lifecycle;
#[cfg(feature = "ssh")]
mod password_and_prompts;
#[cfg(feature = "ssh")]
mod server;
