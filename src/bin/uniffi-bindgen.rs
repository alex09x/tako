/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// Helper binary that drives UniFFI's bindings generator (`uniffi generate ...`)
// against the compiled `tako_core` cdylib. Only built with the
// `uniffi-cli` feature enabled (see Cargo.toml / scripts/build-xcframework.sh).

fn main() {
    uniffi::uniffi_bindgen_main();
}
