/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

// ----------------------------------------------------------------------------
// Regression Case 14: every declared count is bounded before it allocates
// ----------------------------------------------------------------------------

/// A forged out-of-range tab-stop column count is rejected by the same bound
/// the geometry gets, before it reserves anything.
#[test]
fn test_forged_tab_cols_is_rejected_before_allocating() {
    use tako_core::terminal::checkpoint::{self, CheckpointError, MAX_DIM};

    let mut term = Terminal::new(200, 50);
    term.feed(b"forged tab cols");
    let valid = term.export_checkpoint().unwrap();

    // Where the decoder itself found the field -- no offset arithmetic that
    // could drift from the format.
    let (_, offsets) = checkpoint::import_traced(&valid).expect("the honest checkpoint imports");
    assert_eq!(
        u32::from_le_bytes(
            valid[offsets.tab_cols..offsets.tab_cols + 4]
                .try_into()
                .unwrap()
        ),
        200,
        "export writes tab_cols == cols"
    );

    // A count the payload can still satisfy bitset-wise, but far past MAX_DIM.
    let mut forged = valid.clone();
    forged[offsets.tab_cols..offsets.tab_cols + 4].copy_from_slice(&30_000u32.to_le_bytes());
    let forged = reseal(forged);
    assert!(
        Terminal::verify_checkpoint(&forged),
        "header and CRC still check out"
    );

    let mut dest = Terminal::new(20, 6);
    dest.feed(b"DESTINATION");
    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: 30_000,
            rows: 50
        })
    );
    const { assert!(30_000 > MAX_DIM) };
    assert_eq!(row_text(&dest, 0), "DESTINATION", "fail-intact");

    // And a count that would drive a gigabyte allocation is refused too.
    let mut huge = valid.clone();
    huge[offsets.tab_cols..offsets.tab_cols + 4].copy_from_slice(&1_000_000_000u32.to_le_bytes());
    assert!(matches!(
        dest.import_checkpoint(&reseal(huge)),
        Err(CheckpointError::DimensionOutOfBounds { .. })
    ));
}

/// A forged scrollback row count cannot outrun the payload that declares it.
#[test]
fn test_forged_scrollback_count_is_bounded_by_the_payload() {
    use tako_core::terminal::checkpoint::CheckpointError;

    let mut term = Terminal::new(80, 24);
    term.feed(b"scrollback bound");
    let valid = term.export_checkpoint().unwrap();

    // The primary grid's scrollback length is the third u32 after the
    // geometry/margins block; find it by value rather than by arithmetic.
    let payload = &valid[20..];
    let cap_off = payload
        .windows(4)
        .position(|w| w == 10_000u32.to_le_bytes())
        .expect("scrollback capacity is in the payload");
    let sb_len_off = 20 + cap_off + 4 + 8;
    assert_eq!(
        u32::from_le_bytes(valid[sb_len_off..sb_len_off + 4].try_into().unwrap()),
        0,
        "a fresh terminal has no scrollback"
    );

    let mut forged = valid.clone();
    forged[sb_len_off..sb_len_off + 4].copy_from_slice(&900_000u32.to_le_bytes());
    let forged = reseal(forged);

    let mut dest = Terminal::new(20, 6);
    dest.feed(b"DESTINATION");
    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::UnexpectedEof)
    );
    assert_eq!(row_text(&dest, 0), "DESTINATION", "fail-intact");
}

// ----------------------------------------------------------------------------
// Regression Case 15: explicit version negotiation
// ----------------------------------------------------------------------------

#[test]
fn test_version_negotiation_is_explicit() {
    use tako_core::terminal::checkpoint::CheckpointError;

    assert_eq!(Terminal::checkpoint_version(), 6);
    // v1, v2, v3, v4, and v5 stay readable -- a peer holding an older container is not
    // forced to discard it -- while v6 is what this build writes.
    assert!(Terminal::checkpoint_supports(1));
    assert!(Terminal::checkpoint_supports(2));
    assert!(Terminal::checkpoint_supports(3));
    assert!(Terminal::checkpoint_supports(4));
    assert!(Terminal::checkpoint_supports(5));
    assert!(Terminal::checkpoint_supports(6));
    assert!(!Terminal::checkpoint_supports(0));
    assert!(!Terminal::checkpoint_supports(7));
    assert!(!Terminal::checkpoint_supports(u32::MAX));

    assert_eq!(prod_vt_checkpoint_version(), 6);
    assert_eq!(prod_vt_checkpoint_supports(1), 1);
    assert_eq!(prod_vt_checkpoint_supports(2), 1);
    assert_eq!(prod_vt_checkpoint_supports(3), 1);
    assert_eq!(prod_vt_checkpoint_supports(4), 1);
    assert_eq!(prod_vt_checkpoint_supports(5), 1);
    assert_eq!(prod_vt_checkpoint_supports(6), 1);
    assert_eq!(prod_vt_checkpoint_supports(7), 0);

    let mut term = Terminal::new(40, 10);
    term.feed(b"negotiate");
    let valid = term.export_checkpoint().unwrap();

    // A container from a newer peer: intact, correctly checksummed, and
    // unreadable here. That has to come back as a version failure, not as
    // corruption -- the two call for different decisions.
    let mut newer = valid.clone();
    newer[4..8].copy_from_slice(&7u32.to_le_bytes());
    let newer = reseal(newer);

    let mut dest = Terminal::new(20, 6);
    dest.feed(b"DESTINATION");
    assert_eq!(
        dest.import_checkpoint(&newer),
        Err(CheckpointError::UnsupportedVersion(7))
    );
    assert_eq!(
        Terminal::inspect_checkpoint(&newer),
        Err(CheckpointError::UnsupportedVersion(7))
    );
    assert_eq!(row_text(&dest, 0), "DESTINATION", "fail-intact");

    // Corruption is still corruption, and says so differently.
    let mut corrupt = valid.clone();
    let last = corrupt.len() - 1;
    corrupt[last] ^= 0xFF;
    assert!(matches!(
        dest.import_checkpoint(&corrupt),
        Err(CheckpointError::ChecksumMismatch { .. })
    ));

    // Inspect reports what an honest container declares, without decoding it.
    let info = Terminal::inspect_checkpoint(&valid).unwrap();
    assert_eq!((info.version, info.cols, info.rows), (6, 40, 10));
    assert_eq!(info.payload_len as usize, valid.len() - 20);

    let mut c_version = 0u32;
    let mut c_cols = 0u32;
    let mut c_rows = 0u32;
    let mut c_len = 0u32;
    assert_eq!(
        prod_vt_checkpoint_inspect(
            valid.as_ptr(),
            valid.len(),
            &mut c_version,
            &mut c_cols,
            &mut c_rows,
            &mut c_len,
        ),
        1
    );
    assert_eq!((c_version, c_cols, c_rows), (6, 40, 10));
    assert_eq!(
        prod_vt_checkpoint_inspect(
            newer.as_ptr(),
            newer.len(),
            &mut c_version,
            &mut c_cols,
            &mut c_rows,
            &mut c_len,
        ),
        0
    );
}

// ----------------------------------------------------------------------------
// Regression Case 16: fail-intact, proven by comparing exports
// ----------------------------------------------------------------------------

#[test]
fn test_rejected_import_leaves_the_destination_byte_identical() {
    let mut dest = Terminal::new(60, 20);
    dest.feed(b"\x1b[31mred\x1b[m normal\r\nsecond line\x1b]0;title\x07\x1b[3;4H\x1b[2");
    let before = dest.export_checkpoint().unwrap();

    let mut good = Terminal::new(40, 10);
    good.feed(b"a valid but unrelated state");
    let valid = good.export_checkpoint().unwrap();

    let rejects: Vec<Vec<u8>> = vec![
        Vec::new(),
        vec![1, 2, 3, 4, 5],
        valid[..valid.len() / 2].to_vec(),
        {
            let mut v = valid.clone();
            v[0..4].copy_from_slice(b"BAD!");
            v
        },
        {
            let mut v = valid.clone();
            v[4..8].copy_from_slice(&7u32.to_le_bytes());
            reseal(v)
        },
        {
            let mut v = valid.clone();
            let last = v.len() - 1;
            v[last] ^= 0xFF;
            v
        },
        {
            let mut v = valid.clone();
            v[20..24].copy_from_slice(&99_999u32.to_le_bytes());
            reseal(v)
        },
    ];

    for (i, blob) in rejects.iter().enumerate() {
        assert!(
            dest.import_checkpoint(blob).is_err(),
            "blob {i} must be rejected"
        );
        assert_eq!(
            dest.export_checkpoint().unwrap(),
            before,
            "blob {i}: a rejected import must leave the destination byte-identical"
        );
    }

    // And a good one still lands.
    dest.import_checkpoint(&valid).unwrap();
    assert_eq!(dest.export_checkpoint().unwrap(), valid);
}

// ----------------------------------------------------------------------------
// Regression Case 17: the allocation budget is denominated in measured bytes
// ----------------------------------------------------------------------------

#[test]
fn test_cell_size_and_allocation_budget_arithmetic() {
    use tako_core::grid::Cell;
    use tako_core::terminal::checkpoint::{
        CELL_BYTES, HEADER_SIZE, MAX_CONTAINER_LEN, MAX_IMPORT_ALLOC_BYTES, MAX_PAYLOAD_LEN,
    };

    // The budget arithmetic is in bytes, so the figure has to be the measured
    // one. A wire cap is not a memory cap: at 32 bytes a cell, 4e7 cells is
    // ~1.22 GiB and a 10000x10000 grid is ~3 GiB, from a payload that run
    // length encodes to a few kilobytes.
    assert_eq!(std::mem::size_of::<Cell>(), 32);
    assert_eq!(CELL_BYTES, 32);
    // The wire cap is the container, not the payload: a 64 MiB budget that
    // both sides measure the same way leaves the payload 20 bytes short of it.
    assert_eq!(MAX_CONTAINER_LEN, 64 * 1024 * 1024);
    assert_eq!(MAX_PAYLOAD_LEN, MAX_CONTAINER_LEN - HEADER_SIZE);
    assert_eq!(MAX_IMPORT_ALLOC_BYTES, 512 * 1024 * 1024);
    assert_eq!(10_000u64 * 10_000 * CELL_BYTES, 3_200_000_000);

    // A grid that would decode past the budget is refused, however small the
    // payload that declares it is.
    let mut term = Terminal::new(4000, 4000);
    term.feed(b"budget");
    let cost = 4000u64 * 4000 * CELL_BYTES * 2; // primary + alternate
    assert!(cost > MAX_IMPORT_ALLOC_BYTES);
    assert!(
        matches!(
            term.export_checkpoint(),
            Err(tako_core::terminal::checkpoint::CheckpointError::TooLarge { .. })
        ),
        "export refuses a state it could not import back"
    );

    // A big-but-legal grid does round-trip, and its wire size is a fraction of
    // the heap it decodes into: 1200x400 cells is 15.36 MiB of `Cell` per
    // grid, 30.72 MiB for the pair, from the much smaller payload measured
    // here.
    let mut big = Terminal::new(1200, 400);
    big.feed(b"large but legal");
    let ckpt = big
        .export_checkpoint()
        .expect("1200x400 is inside the budget");
    let mut restored = Terminal::new(1200, 400);
    restored.feed(b"the destination this import replaces");

    // Peak accounting, measured rather than assumed: the destination's own
    // state is still live while the replacement is decoded, so the peak spans
    // the staged decode, the wire buffer, and the old state that has not been
    // dropped yet.
    let rss_before = peak_rss_bytes();
    restored.import_checkpoint(&ckpt).unwrap();
    let rss_after = peak_rss_bytes();
    let cells_per_pair = 2 * 1200u64 * 400 * CELL_BYTES;
    println!(
        "import peak accounting: payload {} B, decoded cells {} B/pair, \
         retained old state {} B/pair, process peak RSS {} -> {} B (delta {} B)",
        ckpt.len(),
        cells_per_pair,
        cells_per_pair,
        rss_before,
        rss_after,
        rss_after.saturating_sub(rss_before),
    );
    assert_eq!(restored.export_checkpoint().unwrap(), ckpt);
    assert!(
        (ckpt.len() as u64) < 1200 * 400 * CELL_BYTES,
        "payload {} bytes vs {} bytes of cells per grid",
        ckpt.len(),
        1200 * 400 * CELL_BYTES
    );
    // Two live copies of the pair, plus the payload and decode temporaries.
    // The bound is what the budget promises, not a hope: nothing in the import
    // path holds a third copy.
    assert!(
        rss_after.saturating_sub(rss_before) < 4 * cells_per_pair,
        "peak grew by {} B, more than two live copies plus slack",
        rss_after.saturating_sub(rss_before)
    );
}
