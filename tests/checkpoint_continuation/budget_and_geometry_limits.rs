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
// Regression Case 17: the negotiated cap is the cap on the blob, and 0 means
// "no caller limit"
// ----------------------------------------------------------------------------

/// A transport that says it will carry N bytes has to be handed at most N
/// bytes. The 20-byte container header is part of what gets transmitted, so a
/// cap that excludes it is a cap the caller cannot rely on: at the wire
/// ceiling it would hand a 64 MiB channel 64 MiB + 20.
#[test]
fn test_export_cap_covers_the_container_header() {
    use tako_core::terminal::checkpoint::{CheckpointError, HEADER_SIZE, MAX_PAYLOAD_LEN};

    let mut term = Terminal::new(80, 24);
    term.feed(b"the cap covers the header");
    let full = term.export_checkpoint().unwrap();
    let exact = full.len() as u64;
    assert!(exact > HEADER_SIZE as u64);

    // Exactly enough is enough, and what comes back fits.
    let at_cap = term
        .export_checkpoint_limited(exact)
        .expect("a cap equal to the blob is enough");
    assert_eq!(at_cap, full);
    assert!(at_cap.len() as u64 <= exact);

    // One byte less is not, and the reported size is the whole blob -- header
    // included -- so a caller can size its next attempt from it.
    match term.export_checkpoint_limited(exact - 1) {
        Err(CheckpointError::TooLarge { size, limit }) => {
            assert_eq!(size, exact, "the reported size counts the header");
            assert_eq!(limit, exact - 1);
        }
        other => panic!("expected TooLarge one byte under the blob, got {other:?}"),
    }

    // Every cap at or above the exact size returns something within it; every
    // cap below it refuses. No cap ever yields an oversized blob.
    for cap in (exact - 4)..(exact + 4) {
        match term.export_checkpoint_limited(cap) {
            Ok(blob) => assert!(
                blob.len() as u64 <= cap,
                "cap {cap} produced {} bytes",
                blob.len()
            ),
            Err(CheckpointError::TooLarge { size, limit }) => {
                assert_eq!(size, exact);
                assert_eq!(limit, cap);
                assert!(cap < exact);
            }
            other => panic!("unexpected result at cap {cap}: {other:?}"),
        }
    }

    // A refusal at the boundary mutated nothing.
    assert_eq!(term.export_checkpoint().unwrap(), full);

    // 0 is "no caller limit": the library ceiling alone, not a limit of zero.
    assert_eq!(
        term.export_checkpoint_limited(0)
            .expect("0 means the ceiling"),
        full
    );
    // And a cap above the ceiling is clamped to it, not honoured.
    assert_eq!(term.export_checkpoint_limited(u64::MAX).unwrap(), full);
    assert!(full.len() <= MAX_PAYLOAD_LEN);

    // The C ABI carries both semantics.
    let vt = prod_vt_new(80, 24, 100);
    prod_vt_write(vt, b"the cap covers the header".as_ptr(), 25);
    let via_zero = unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, 0, o, l)) }
        .expect("0 exports at the ceiling through the C ABI");
    assert!(Terminal::verify_checkpoint(&via_zero));
    let exact_c = via_zero.len() as u64;
    let at_cap_c =
        unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, exact_c, o, l)) }
            .expect("a cap equal to the blob is enough through the C ABI");
    assert_eq!(at_cap_c.len() as u64, exact_c);
    assert_eq!(
        unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, exact_c - 1, o, l)) },
        None,
        "one byte under the blob refuses through the C ABI too"
    );
    prod_vt_free(vt);
}

// ----------------------------------------------------------------------------
// Regression Case 18: the cumulative allocation budget actually refuses
// ----------------------------------------------------------------------------

/// A wire cap is not a memory cap. Geometry is the cheapest lever there is:
/// 10000x10000 passes every dimension bound (both are exactly MAX_DIM) yet
/// declares 3.2 GB of cells from a payload of about 1.3 KB. Reporting peak
/// usage would not stop it; the budget has to refuse.
#[test]
fn test_forged_geometry_is_refused_by_the_allocation_budget() {
    use tako_core::terminal::checkpoint::{
        CELL_BYTES, CheckpointError, MAX_DIM, MAX_IMPORT_ALLOC_BYTES,
    };

    let mut term = Terminal::new(80, 24);
    term.feed(b"honest source");
    let valid = term.export_checkpoint().unwrap();
    assert!(
        valid.len() < 64 * 1024,
        "the forgery is tiny: {}",
        valid.len()
    );

    // cols and rows are the first two u32 of the payload.
    let mut forged = valid.clone();
    forged[20..24].copy_from_slice(&(MAX_DIM as u32).to_le_bytes());
    forged[24..28].copy_from_slice(&(MAX_DIM as u32).to_le_bytes());
    let forged = reseal(forged);
    assert!(
        Terminal::verify_checkpoint(&forged),
        "magic, version, length and CRC all still check out"
    );

    // The declared grid is within every dimension bound and still far past the
    // memory budget -- which is the whole point of having a separate one.
    let declared = (MAX_DIM as u64) * (MAX_DIM as u64) * CELL_BYTES;
    assert!(
        declared > MAX_IMPORT_ALLOC_BYTES,
        "{declared} vs {MAX_IMPORT_ALLOC_BYTES}"
    );

    let mut dest = Terminal::new(60, 20);
    dest.feed(b"DESTINATION\r\nsecond line");
    let before = dest.export_checkpoint().unwrap();

    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::AllocationLimitExceeded)
    );

    // Fail-intact, byte for byte -- not merely "still has some text".
    assert_eq!(dest.export_checkpoint().unwrap(), before);
    assert_eq!(row_text(&dest, 0), "DESTINATION");
    assert_eq!(row_text(&dest, 1), "second line");

    // A second attempt is refused identically, and the honest checkpoint the
    // forgery was built from still imports.
    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::AllocationLimitExceeded)
    );
    dest.import_checkpoint(&valid)
        .expect("the honest checkpoint still imports");
    assert_eq!(row_text(&dest, 0), "honest source");
}

/// Export must refuse exactly what import refuses.
///
/// `MAX_DIM` bounds the importer, but nothing bounded the exporter: a terminal
/// one column past it produced a blob that verified, carried an honest CRC, and
/// then failed at `import_checkpoint` with `DimensionOutOfBounds`. That is a
/// success return on an un-importable checkpoint -- the exact asymmetry the
/// container exists to remove -- and a caller that trusted the export had
/// already dropped the source state by the time the restore failed.
///
/// The fix refuses at export. Nothing resizes: the terminal is a legal
/// 10001-column terminal before the call and an untouched one after it.
#[test]
fn test_export_refuses_geometry_its_own_importer_would_reject() {
    use tako_core::terminal::checkpoint::{CheckpointError, MAX_DIM};

    // At the bound: exports, imports, round-trips. The guard must not be a
    // blanket refusal of large terminals.
    let mut at_bound = Terminal::new(MAX_DIM, 1);
    assert_eq!(at_bound.active_grid().cols(), MAX_DIM);
    at_bound.feed(b"widest legal terminal");
    let blob = at_bound
        .export_checkpoint()
        .expect("a terminal exactly at MAX_DIM is exportable");
    assert!(Terminal::verify_checkpoint(&blob));
    let mut dest = Terminal::new(MAX_DIM, 1);
    dest.import_checkpoint(&blob)
        .expect("and importable, which is the point of the bound");
    assert_eq!(row_text(&dest, 0), "widest legal terminal");

    // One column past it. The engine builds it happily -- this is not an
    // invalid terminal, only an unrepresentable checkpoint.
    let mut past = Terminal::new(MAX_DIM + 1, 1);
    assert_eq!(past.active_grid().cols(), MAX_DIM + 1);
    past.feed(b"one column too wide");

    assert_eq!(
        past.export_checkpoint(),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: MAX_DIM + 1,
            rows: 1
        }),
        "export must refuse what import would reject, not emit a blob and let \
         the restore discover it"
    );
    assert_eq!(
        past.export_checkpoint_limited(0),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: MAX_DIM + 1,
            rows: 1
        })
    );

    // The refusal did not touch the terminal: same geometry, same contents,
    // still usable.
    assert_eq!(past.active_grid().cols(), MAX_DIM + 1);
    assert_eq!(past.active_grid().rows(), 1);
    assert_eq!(row_text(&past, 0), "one column too wide");
    past.feed(b" still alive");
    assert_eq!(row_text(&past, 0), "one column too wide still alive");

    // Too tall is refused the same way.
    let too_tall = Terminal::new(1, MAX_DIM + 1);
    assert_eq!(
        too_tall.export_checkpoint(),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: 1,
            rows: MAX_DIM + 1
        })
    );

    // And the C surface reports the same refusal rather than handing back a
    // buffer: a failed export yields no allocation to free.
    {
        let vt = prod_vt_new((MAX_DIM + 1) as u16, 1, 0);
        assert!(!vt.is_null());
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        assert_eq!(
            prod_vt_checkpoint_export(vt, &mut ptr, &mut len),
            0,
            "the C export must fail for geometry its importer would reject"
        );
        assert!(ptr.is_null(), "a failed export must not hand back a buffer");
        assert_eq!(len, 0);
        prod_vt_free(vt);
    }
}

/// Build a version-1 container out of a version-2 one.
/// A selection is the surface's, not the engine's, and it does not travel in a
/// checkpoint.
///
/// v1 serialized it, so a restore installed the *source's* highlight on the
/// destination -- over rows that selection never described -- and decoded four
/// grid coordinates straight off the wire with nothing validating them. v2
/// stops writing the block and reads past a v1 one. The destination's own
/// selection is therefore cleared exactly when the import succeeds, and
/// survives untouched when it fails.
#[test]
fn test_selection_does_not_travel_in_a_checkpoint() {
    use tako_core::terminal::SelectionMode;
    use tako_core::terminal::checkpoint::CheckpointError;

    let mut source = Terminal::new(40, 6);
    source.feed(b"source line one\r\nsource line two");
    source.start_selection(0, 0, SelectionMode::Linear);
    source.extend_selection(0, 10);
    assert!(source.has_selection(), "the source really does have one");

    let blob = source.export_checkpoint().unwrap();

    // Since v2 no container carries it: a selected and an unselected source
    // of otherwise identical state produce the identical container.
    let mut unselected = Terminal::new(40, 6);
    unselected.feed(b"source line one\r\nsource line two");
    assert!(!unselected.has_selection());
    assert_eq!(
        blob,
        unselected.export_checkpoint().unwrap(),
        "the selection must not be observable in the bytes at all"
    );

    // A successful import clears the destination's selection.
    let mut dest = Terminal::new(40, 6);
    dest.feed(b"DESTINATION one\r\nDESTINATION two");
    dest.start_selection(1, 2, SelectionMode::Rectangular);
    dest.extend_selection(1, 9);
    assert!(dest.has_selection());

    dest.import_checkpoint(&blob)
        .expect("the current version imports");
    assert!(
        !dest.has_selection(),
        "a restored surface has nothing selected: the rows underneath the old \
         selection are gone"
    );
    assert_eq!(dest.selection_range(), None);
    assert_eq!(row_text(&dest, 0), "source line one");

    // A failed import leaves the destination's selection exactly as it was.
    let mut intact = Terminal::new(40, 6);
    intact.feed(b"KEEP ME");
    intact.start_selection(0, 1, SelectionMode::Linear);
    intact.extend_selection(0, 4);
    let range_before = intact.selection_range();
    assert!(range_before.is_some());

    let mut corrupt = blob.clone();
    let last = corrupt.len() - 1;
    corrupt[last] ^= 0xFF;
    assert!(matches!(
        intact.import_checkpoint(&corrupt),
        Err(CheckpointError::ChecksumMismatch { .. })
    ));
    assert!(intact.has_selection(), "fail-intact includes the selection");
    assert_eq!(intact.selection_range(), range_before);
    assert_eq!(row_text(&intact, 0), "KEEP ME");

    // A genuine v1 container still imports -- and its selection is dropped
    // rather than installed. The coordinates are deliberately absurd: under
    // v1 they were decoded and stored without a bound.
    // v1 is v2 plus the selection, so it is built from a v2 export; v3's own
    // tail comes after where v1's selection sat.
    let v2 = source.export_checkpoint_version(2, 0).unwrap();
    let v1 = as_v1_with_selection(&v2, (u32::MAX, u32::MAX), (u32::MAX - 1, 7), 1);
    assert!(Terminal::verify_checkpoint(&v1));
    assert_eq!(Terminal::inspect_checkpoint(&v1).unwrap().version, 1);

    let mut from_v1 = Terminal::new(40, 6);
    from_v1.start_selection(0, 0, SelectionMode::Linear);
    from_v1.extend_selection(0, 3);
    from_v1
        .import_checkpoint(&v1)
        .expect("a v1 container is still readable");
    assert_eq!(row_text(&from_v1, 0), "source line one");
    assert!(
        !from_v1.has_selection(),
        "the v1 selection is read past, not restored"
    );

    // A v1 container that claims a selection and then stops short is a
    // truncated payload, not a silently accepted one.
    let mut truncated = v1.clone();
    truncated.truncate(truncated.len() - 4);
    let truncated_len = (truncated.len() - 20) as u32;
    truncated[12..16].copy_from_slice(&truncated_len.to_le_bytes());
    let truncated = reseal(truncated);
    let mut victim = Terminal::new(40, 6);
    victim.feed(b"UNTOUCHED");
    assert_eq!(
        victim.import_checkpoint(&truncated),
        Err(CheckpointError::UnexpectedEof)
    );
    assert_eq!(row_text(&victim, 0), "UNTOUCHED");
}
