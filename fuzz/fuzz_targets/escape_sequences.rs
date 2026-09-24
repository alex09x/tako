#![no_main]
//! Escape sequence stress target: exercises primary/alternate screen buffers,
//! CSI, OSC, DCS, APC, SGR, DECSCUSR, margins, tabstops, hyperlinks, and
//! Kitty keyboard/graphics byte streams.

use libfuzzer_sys::fuzz_target;
use tako_core::terminal::Terminal;
use tako_core_fuzz::{assert_safe_readback, build_escape_stream, EscapeStreamInput};

fuzz_target!(|input: EscapeStreamInput| {
    let (cols, rows, bytes) = build_escape_stream(&input);
    let mut term = Terminal::new(cols, rows);
    term.feed(&bytes);
    assert_safe_readback(&mut term);
});
