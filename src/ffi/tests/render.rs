/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::ffi::core::TakoCore;
use crate::ffi::pack::collapse_row_ranges;
use crate::ffi::render_types::{FfiRenderFrameOverscan, FfiRowRange};
use crate::ffi::types::{MAX_OVERSCAN_ROWS, PACKED_CELL_SIZE};

#[test]
fn test_collapse_row_ranges_merges_runs_only() {
    assert_eq!(collapse_row_ranges(&[]), vec![]);
    assert_eq!(
        collapse_row_ranges(&[0, 1, 2, 7, 8, 11]),
        vec![
            FfiRowRange { start: 0, count: 3 },
            FfiRowRange { start: 7, count: 2 },
            FfiRowRange {
                start: 11,
                count: 1
            },
        ]
    );
}

#[test]
fn test_render_frame_delta_leaves_render_frame_behavior_intact() {
    let core = TakoCore::new(40, 10);
    core.feed(b"Hello, Tako FFI!\r\nLine 2".to_vec());

    let frame = core.render_frame();
    assert_eq!(frame.packed_cells.len(), 40 * 10 * PACKED_CELL_SIZE);
    assert!(frame.snapshot.damaged_rows.contains(&0));
    assert_eq!(frame.snapshot.cursor_row, 1);
    let again = core.render_frame();
    assert!(again.snapshot.damaged_rows.is_empty());
    assert_eq!(again.packed_cells, frame.packed_cells);
}

fn packed_row(frame: &FfiRenderFrameOverscan, row: u32) -> &[u8] {
    let stride = frame.snapshot.cols as usize * PACKED_CELL_SIZE;
    let start = row as usize * stride;
    &frame.packed_cells[start..start + stride]
}

#[test]
fn test_overscan_row_is_the_line_scrolling_down_would_reveal() {
    let core = TakoCore::new(20, 5);
    for i in 0..20 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    core.scroll_viewport_up(3);

    let frame = core.render_frame_overscan(1);
    assert_eq!(frame.overscan_rows, 1);
    assert_eq!(
        frame.packed_cells.len(),
        (frame.snapshot.rows as usize + 1) * frame.snapshot.cols as usize * PACKED_CELL_SIZE,
        "the payload must carry the viewport plus the rows it claims"
    );
    let overscan = packed_row(&frame, frame.snapshot.rows).to_vec();

    core.scroll_viewport_down(1);
    let revealed = core.render_frame_overscan(0);
    let last_visible = packed_row(&revealed, revealed.snapshot.rows - 1);

    assert_eq!(
        overscan, last_visible,
        "the overscan row must be the next real line, not a repeat or a blank"
    );
}

#[test]
fn test_at_the_tail_nothing_exists_below_the_viewport() {
    let core = TakoCore::new(20, 5);
    for i in 0..20 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    let frame = core.render_frame_overscan(1);
    assert_eq!(frame.snapshot.viewport_offset, 0);

    let blank = TakoCore::new(20, 5).render_frame_overscan(0);
    assert_eq!(
        packed_row(&frame, frame.snapshot.rows),
        packed_row(&blank, 0),
        "below the live screen there is no line, so the strip must draw as blank"
    );
}

#[test]
fn test_overscan_viewport_prefix_matches_render_frame_exactly() {
    let core = TakoCore::new(40, 8);
    core.feed(b"top\r\nmiddle\r\nbottom".to_vec());
    core.scroll_viewport_up(1);

    let plain = core.render_frame();
    let over = core.render_frame_overscan(1);

    let viewport_bytes = plain.packed_cells.len();
    assert_eq!(
        &over.packed_cells[..viewport_bytes],
        &plain.packed_cells[..],
        "a host ignoring the extra rows must see the frame it always saw"
    );
    assert_eq!(over.snapshot.rows, plain.snapshot.rows);
    assert_eq!(over.snapshot.cursor_row, plain.snapshot.cursor_row);
    assert_eq!(
        over.snapshot.viewport_offset,
        plain.snapshot.viewport_offset
    );
}

#[test]
fn test_overscan_frame_carries_the_same_epoch_as_the_plain_frame() {
    let core = TakoCore::new(20, 5);
    core.feed(b"before the import\r\n".to_vec());

    let before_plain = core.render_frame().epoch;
    let before_over = core.render_frame_overscan(1).epoch;
    assert_eq!(
        before_over, before_plain,
        "the overscan frame reported a different generation from the plain one"
    );

    let source = TakoCore::new(31, 7);
    source.feed(b"after the import\r\n".to_vec());
    let blob = source
        .checkpoint_export(0, 8 << 20)
        .expect("bounded export of a small terminal");
    core.checkpoint_import(blob).expect("honest checkpoint");

    let after_over = core.render_frame_overscan(1).epoch;
    assert_ne!(
        after_over, before_over,
        "an import replaced the engine without moving the overscan frame's epoch"
    );
    assert_eq!(
        after_over,
        core.render_frame().epoch,
        "the two frame calls disagree about which engine they came from"
    );
    assert_eq!(after_over, core.state_epoch());
}

#[test]
fn test_overscan_request_is_clamped_not_honored_unbounded() {
    let core = TakoCore::new(10, 4);
    let frame = core.render_frame_overscan(9_000);
    assert_eq!(frame.overscan_rows, MAX_OVERSCAN_ROWS);
    assert_eq!(
        frame.packed_cells.len(),
        (4 + MAX_OVERSCAN_ROWS as usize) * 10 * PACKED_CELL_SIZE
    );
}

#[test]
fn test_render_frame_payload_and_packed_size() {
    let core = TakoCore::new(80, 24);
    core.feed(b"Hello, Tako FFI!\r\nLine 2".to_vec());

    let frame = core.render_frame();
    assert_eq!(frame.snapshot.cols, 80);
    assert_eq!(frame.snapshot.rows, 24);
    assert_eq!(frame.snapshot.cursor_row, 1);
    assert_eq!(frame.snapshot.cursor_col, 6);
    assert!(frame.snapshot.cursor_visible);

    assert!(!frame.snapshot.damaged_rows.is_empty());

    let expected_packed_bytes = 80 * 24 * PACKED_CELL_SIZE;
    assert_eq!(frame.packed_cells.len(), expected_packed_bytes);

    let snap = core.snapshot();
    let packed = core.viewport_packed();
    assert_eq!(snap.cols, frame.snapshot.cols);
    assert_eq!(snap.rows, frame.snapshot.rows);
    assert_eq!(packed.len(), expected_packed_bytes);
}

#[test]
fn test_render_frame_single_lock_tearing_prevention() {
    let core = TakoCore::new(40, 10);
    core.feed(b"Test lock consistency".to_vec());

    let frame = core.render_frame();
    assert_eq!(frame.snapshot.cols, 40);
    assert_eq!(frame.snapshot.rows, 10);
    assert_eq!(frame.packed_cells.len(), 40 * 10 * PACKED_CELL_SIZE);
}
