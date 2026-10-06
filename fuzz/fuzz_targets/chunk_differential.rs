/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#![no_main]
//! Differential fuzz target: compares single-feed vs arbitrary chunked feeds.
//! Ensures that parser and terminal state is independent of chunk boundaries.

use libfuzzer_sys::fuzz_target;
use tako_core_fuzz::{test_chunking_differential, ChunkingInput};

fuzz_target!(|input: ChunkingInput| {
    test_chunking_differential(&input);
});
