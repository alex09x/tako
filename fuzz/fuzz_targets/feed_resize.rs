#![no_main]
//! Feeding interleaved with resizes exercises reflow, scrollback and the
//! wide-pair/spacer-head invariants, the trickiest arithmetic in the port.

use arbitrary::Arbitrary;
use libfuzzer_sys::fuzz_target;
use tako_core::terminal::Terminal;
use tako_core_fuzz::assert_safe_readback;

#[derive(Arbitrary, Debug)]
struct Input {
    cols: u8,
    rows: u8,
    chunks: Vec<(Vec<u8>, u8, u8)>,
}

fuzz_target!(|input: Input| {
    let mut term = Terminal::new(
        (input.cols as usize % 200).max(1),
        (input.rows as usize % 100).max(1),
    );
    for (bytes, cols, rows) in input.chunks.into_iter().take(16) {
        term.feed(&bytes);
        term.resize((cols as usize % 200).max(1), (rows as usize % 100).max(1));
        assert_safe_readback(&mut term);
    }
});
