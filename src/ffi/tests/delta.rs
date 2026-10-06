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
use crate::ffi::render_types::{FfiRenderFrameDelta, FfiResyncReason, FfiRowRange};
use crate::ffi::types::{FfiSelectionMode, PACKED_CELL_SIZE};

fn hydrate(cache: &mut Vec<u8>, delta: &FfiRenderFrameDelta) {
    let stride = delta.row_stride as usize;
    assert_eq!(delta.cell_stride as usize, PACKED_CELL_SIZE);
    assert_eq!(stride, delta.cols as usize * PACKED_CELL_SIZE);
    assert_eq!(
        delta.packed_cells.len(),
        delta.row_indices.len() * stride,
        "packed payload must be exactly the rows it names"
    );
    assert_eq!(
        delta.row_indices, delta.snapshot.damaged_rows,
        "the record must not disagree with its own snapshot"
    );
    assert_eq!(
        delta.row_indices,
        delta
            .row_ranges
            .iter()
            .flat_map(|r| r.start..r.start + r.count)
            .collect::<Vec<u32>>(),
        "ranges must expand back to the row list"
    );
    assert!(delta.row_indices.iter().all(|&r| r < delta.rows));

    if delta.full_resync {
        assert_eq!(delta.row_indices, (0..delta.rows).collect::<Vec<u32>>());
        assert_eq!(delta.base_version, 0);
        assert_ne!(delta.resync_reason, FfiResyncReason::Delta);
        *cache = delta.packed_cells.clone();
        return;
    }

    assert_eq!(delta.resync_reason, FfiResyncReason::Delta);
    assert_eq!(cache.len(), delta.rows as usize * stride);
    for (slot, &row) in delta.row_indices.iter().enumerate() {
        let src = &delta.packed_cells[slot * stride..(slot + 1) * stride];
        let dst = row as usize * stride;
        cache[dst..dst + stride].copy_from_slice(src);
    }
}

#[test]
fn test_render_frame_delta_first_frame_is_the_full_reference() {
    let core = TakoCore::new(20, 6);
    core.feed(b"first\r\nsecond".to_vec());

    let delta = core.render_frame_delta(0);

    assert!(delta.full_resync);
    assert_eq!(delta.resync_reason, FfiResyncReason::FirstFrame);
    assert_eq!(delta.frame_version, 1);
    assert_eq!(delta.base_version, 0);
    assert_eq!(delta.cols, 20);
    assert_eq!(delta.rows, 6);
    assert_eq!(delta.row_ranges, vec![FfiRowRange { start: 0, count: 6 }]);

    let mut cache = Vec::new();
    hydrate(&mut cache, &delta);
    assert_eq!(cache, core.viewport_packed());
    assert_eq!(cache.len(), 20 * 6 * PACKED_CELL_SIZE);
}

#[test]
fn test_render_frame_delta_one_and_two_row_changes_hydrate_to_reference() {
    let core = TakoCore::new(20, 6);
    core.feed(b"alpha\r\nbravo\r\ncharlie".to_vec());

    let first = core.render_frame_delta(0);
    let mut cache = Vec::new();
    hydrate(&mut cache, &first);
    assert_eq!(cache, core.viewport_packed());

    // One row changes.
    core.feed(b"\x1b[2;1Hdelta!".to_vec());
    let one = core.render_frame_delta(first.frame_version);
    assert!(!one.full_resync);
    assert_eq!(one.base_version, first.frame_version);
    assert_eq!(one.frame_version, first.frame_version + 1);
    assert!(one.row_indices.contains(&1));
    assert!(one.row_indices.len() < one.rows as usize);
    hydrate(&mut cache, &one);
    assert_eq!(cache, core.viewport_packed());

    // Two rows change, non-adjacent.
    core.feed(b"\x1b[1;1Hone\x1b[5;1Hfive".to_vec());
    let two = core.render_frame_delta(one.frame_version);
    assert!(!two.full_resync);
    assert!(two.row_indices.contains(&0) && two.row_indices.contains(&4));
    assert!(two.row_indices.len() < two.rows as usize);
    assert!(two.row_ranges.len() >= 2);
    hydrate(&mut cache, &two);
    assert_eq!(cache, core.viewport_packed());

    // Nothing changed at all.
    let idle = core.render_frame_delta(two.frame_version);
    assert!(!idle.full_resync);
    assert!(idle.row_indices.is_empty());
    assert!(idle.packed_cells.is_empty());
    hydrate(&mut cache, &idle);
    assert_eq!(cache, core.viewport_packed());
}

#[test]
fn test_render_frame_delta_empty_delta_still_carries_metadata() {
    let core = TakoCore::new(20, 6);
    core.feed(b"content".to_vec());
    let first = core.render_frame_delta(0);

    core.feed(b"\x1b]0;New Title\x07\x1b[?7l\x1b[?25l".to_vec());
    core.start_selection(1, 2, FfiSelectionMode::Linear);
    core.extend_selection(2, 5);

    let delta = core.render_frame_delta(first.frame_version);

    assert!(delta.row_indices.is_empty());
    assert!(delta.packed_cells.is_empty());
    assert!(!delta.full_resync);
    assert_eq!(delta.frame_version, first.frame_version + 1);
    assert_eq!(delta.snapshot.title, "New Title");
    assert!(!delta.snapshot.modes.autowrap);
    assert!(!delta.snapshot.cursor_visible);
    let selection = delta
        .snapshot
        .selection
        .expect("selection must be reported");
    assert_eq!((selection.start_row, selection.start_col), (1, 2));
    assert_eq!((selection.end_row, selection.end_col), (2, 5));
}

#[test]
fn test_render_frame_delta_resize_forces_resync() {
    let core = TakoCore::new(20, 6);
    core.feed(b"before resize".to_vec());
    let first = core.render_frame_delta(0);

    core.resize(30, 8);
    let delta = core.render_frame_delta(first.frame_version);

    assert!(delta.full_resync);
    assert_eq!(delta.resync_reason, FfiResyncReason::Resized);
    assert_eq!((delta.cols, delta.rows), (30, 8));
    assert_eq!(delta.row_stride, 30 * PACKED_CELL_SIZE as u32);

    let mut cache = Vec::new();
    hydrate(&mut cache, &delta);
    assert_eq!(cache, core.viewport_packed());
}

#[test]
fn test_render_frame_delta_viewport_scroll_forces_resync() {
    let core = TakoCore::new(20, 4);
    for line in 0..12 {
        core.feed(format!("line {line}\r\n").into_bytes());
    }
    let first = core.render_frame_delta(0);
    assert_eq!(first.snapshot.viewport_offset, 0);

    core.scroll_viewport_up(2);
    let scrolled = core.render_frame_delta(first.frame_version);

    assert!(scrolled.full_resync);
    assert_eq!(scrolled.resync_reason, FfiResyncReason::ViewportScrolled);
    assert_eq!(scrolled.snapshot.viewport_offset, 2);
    let mut cache = Vec::new();
    hydrate(&mut cache, &scrolled);
    assert_eq!(cache, core.viewport_packed());

    core.scroll_viewport_bottom();
    let back = core.render_frame_delta(scrolled.frame_version);
    assert!(back.full_resync);
    assert_eq!(back.resync_reason, FfiResyncReason::ViewportScrolled);
    hydrate(&mut cache, &back);
    assert_eq!(cache, core.viewport_packed());
}

#[test]
fn test_render_frame_delta_reset_forces_resync() {
    let core = TakoCore::new(20, 6);
    core.feed(b"stuff on screen".to_vec());
    let first = core.render_frame_delta(0);

    core.reset();
    let delta = core.render_frame_delta(first.frame_version);

    assert!(delta.full_resync);
    assert_eq!(delta.resync_reason, FfiResyncReason::Reset);
    let mut cache = Vec::new();
    hydrate(&mut cache, &delta);
    assert_eq!(cache, core.viewport_packed());

    core.feed(b"fresh".to_vec());
    let after = core.render_frame_delta(delta.frame_version);
    assert!(!after.full_resync);
    hydrate(&mut cache, &after);
    assert_eq!(cache, core.viewport_packed());
}

#[test]
fn test_render_frame_delta_alternate_screen_switch_forces_resync() {
    let core = TakoCore::new(20, 6);
    core.feed(b"primary text".to_vec());
    let first = core.render_frame_delta(0);

    core.feed(b"\x1b[?1049h".to_vec());
    let entered = core.render_frame_delta(first.frame_version);
    assert!(entered.full_resync);
    assert_eq!(entered.resync_reason, FfiResyncReason::ScreenSwitched);
    let mut cache = Vec::new();
    hydrate(&mut cache, &entered);
    assert_eq!(cache, core.viewport_packed());

    core.feed(b"\x1b[?1049l".to_vec());
    let left = core.render_frame_delta(entered.frame_version);
    assert!(left.full_resync);
    assert_eq!(left.resync_reason, FfiResyncReason::ScreenSwitched);
    hydrate(&mut cache, &left);
    assert_eq!(cache, core.viewport_packed());
}

#[test]
fn test_render_frame_delta_full_damage_is_a_resync_not_a_row_list() {
    let core = TakoCore::new(20, 6);
    core.feed(b"content".to_vec());
    let first = core.render_frame_delta(0);

    core.mark_all_damaged();
    let delta = core.render_frame_delta(first.frame_version);

    assert!(delta.full_resync);
    assert_eq!(delta.resync_reason, FfiResyncReason::FullDamage);
    assert_eq!(delta.row_ranges, vec![FfiRowRange { start: 0, count: 6 }]);
    let mut cache = Vec::new();
    hydrate(&mut cache, &delta);
    assert_eq!(cache, core.viewport_packed());
}

#[test]
fn test_render_frame_delta_stale_version_is_detectable() {
    let core = TakoCore::new(20, 6);
    core.feed(b"one".to_vec());
    let first = core.render_frame_delta(0);
    core.feed(b"\r\ntwo".to_vec());
    let second = core.render_frame_delta(first.frame_version);
    assert!(!second.full_resync);

    core.feed(b"\r\nthree".to_vec());
    let stale = core.render_frame_delta(first.frame_version);
    assert!(stale.full_resync);
    assert_eq!(stale.resync_reason, FfiResyncReason::VersionMismatch);
    let mut cache = Vec::new();
    hydrate(&mut cache, &stale);
    assert_eq!(cache, core.viewport_packed());

    assert!(first.frame_version < second.frame_version);
    assert!(second.frame_version < stale.frame_version);

    core.feed(b"\r\nfour".to_vec());
    let from_future = core.render_frame_delta(stale.frame_version + 99);
    assert!(from_future.full_resync);
    assert_eq!(from_future.resync_reason, FfiResyncReason::VersionMismatch);
}

#[test]
fn test_render_frame_delta_damage_ownership_never_leaves_a_reader_stale() {
    let core = TakoCore::new(20, 6);
    core.feed(b"shared core".to_vec());
    let first = core.render_frame_delta(0);
    let mut cache = Vec::new();
    hydrate(&mut cache, &first);

    core.feed(b"\x1b[3;1Hsecond renderer".to_vec());
    let frame = core.render_frame();
    assert!(frame.snapshot.damaged_rows.contains(&2));
    assert_eq!(frame.packed_cells, core.viewport_packed());

    let delta = core.render_frame_delta(first.frame_version);
    assert!(delta.full_resync);
    assert_eq!(delta.resync_reason, FfiResyncReason::DamageOwnershipLost);
    hydrate(&mut cache, &delta);
    assert_eq!(cache, core.viewport_packed());

    for drain in [0, 1] {
        let last = core.render_frame_delta(u64::MAX).frame_version;
        core.feed(b"\x1b[4;1Hmore".to_vec());
        if drain == 0 {
            core.take_damage();
        } else {
            core.snapshot();
        }
        let after = core.render_frame_delta(last);
        assert!(after.full_resync);
        assert_eq!(after.resync_reason, FfiResyncReason::DamageOwnershipLost);
    }

    core.feed(b"\x1b[5;1Hlate".to_vec());
    let _ = core.render_frame_delta(core.render_frame_delta(0).frame_version);
    assert_eq!(core.render_frame().packed_cells, core.viewport_packed());
}

#[test]
fn test_render_frame_delta_payload_bytes_one_row_vs_full_100x50() {
    let core = TakoCore::new(100, 50);
    core.feed(b"warm up the grid".to_vec());

    let full = core.render_frame_delta(0);
    assert!(full.full_resync);
    let full_bytes = 100 * 50 * PACKED_CELL_SIZE;
    assert_eq!(full.packed_cells.len(), full_bytes);
    assert_eq!(full.packed_cells.len(), core.viewport_packed().len());

    core.feed(b"\x1b[7;1Hjust this row".to_vec());
    let one_row = core.render_frame_delta(full.frame_version);
    assert!(!one_row.full_resync);
    assert_eq!(one_row.row_indices, vec![6]);
    let row_bytes = 100 * PACKED_CELL_SIZE;
    assert_eq!(one_row.packed_cells.len(), row_bytes);
    assert_eq!(one_row.packed_cells.len() * 50, full.packed_cells.len());

    assert_eq!(row_bytes, 1_600);
    assert_eq!(full_bytes, 80_000);
    let mut cache = full.packed_cells.clone();
    hydrate(&mut cache, &one_row);
    assert_eq!(cache, core.viewport_packed());
}
