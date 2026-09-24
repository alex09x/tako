#![no_main]
//! Stateful terminal fuzz target: exercises sequences of interleaved feed,
//! resize, viewport scrolling, selection (linear, rectangular, word, line),
//! clear, styling, and public readbacks.

use libfuzzer_sys::fuzz_target;
use tako_core_fuzz::{apply_ops, TerminalOpInput};

fuzz_target!(|input: TerminalOpInput| {
    apply_ops(&input);
});
