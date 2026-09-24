use arbitrary::Arbitrary;
use tako_core::terminal::Terminal;

use crate::harness::{assert_observable_state_eq, assert_safe_readback};
use crate::ops::{clamp_cols, clamp_rows};

/// Input structure for the chunking differential fuzz target.
#[derive(Arbitrary, Debug, Clone)]
pub struct ChunkingInput {
    pub cols: u8,
    pub rows: u8,
    pub data: Vec<u8>,
    pub split_points: Vec<u16>,
}

/// Executes differential chunking test: feeds `input.data` all at once to `term_whole`
/// and in arbitrary slices to `term_chunked`, verifying that terminal observable state
/// matches exactly regardless of feed boundaries.
pub fn test_chunking_differential(input: &ChunkingInput) {
    let cols = clamp_cols(input.cols);
    let rows = clamp_rows(input.rows);

    let max_len = input.data.len().min(4096);
    let data = &input.data[..max_len];

    let mut term_whole = Terminal::new(cols, rows);
    let mut term_chunked = Terminal::new(cols, rows);

    // Feed single buffer
    term_whole.feed(data);

    // Feed chunked
    if !data.is_empty() {
        let mut split_indices = Vec::with_capacity(input.split_points.len() + 2);
        split_indices.push(0);
        split_indices.push(data.len());
        for &sp in input.split_points.iter().take(32) {
            let idx = (sp as usize) % (data.len() + 1);
            split_indices.push(idx);
        }
        split_indices.sort_unstable();
        split_indices.dedup();

        for w in split_indices.windows(2) {
            let start = w[0];
            let end = w[1];
            if start < end {
                term_chunked.feed(&data[start..end]);
            }
        }
    }

    assert_observable_state_eq(&term_whole, &term_chunked);
    assert_safe_readback(&mut term_whole);
    assert_safe_readback(&mut term_chunked);
}
