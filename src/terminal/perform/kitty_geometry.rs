/*
 * tako — Terminal emulation engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::graphics::PlacementOptions;

/// The cell rectangle occupied by a Kitty image, used for cursor movement.
pub(crate) fn placement_spans(
    o: PlacementOptions,
    image: (u32, u32),
    cell: (u32, u32),
) -> (usize, usize) {
    let (cw, ch) = (u64::from(cell.0.max(1)), u64::from(cell.1.max(1)));
    let available_w = image.0.saturating_sub(o.source_x);
    let available_h = image.1.saturating_sub(o.source_y);
    let source_w = u64::from(
        if o.source_width == 0 {
            available_w
        } else {
            o.source_width.min(available_w)
        }
        .max(1),
    );
    let source_h = u64::from(
        if o.source_height == 0 {
            available_h
        } else {
            o.source_height.min(available_h)
        }
        .max(1),
    );
    let (width, height) = match (o.columns, o.rows) {
        (c, r) if c > 0 && r > 0 => (
            u64::from(c).saturating_mul(cw),
            u64::from(r).saturating_mul(ch),
        ),
        (c, 0) if c > 0 => {
            let w = u64::from(c).saturating_mul(cw);
            (w, w.saturating_mul(source_h).div_ceil(source_w))
        }
        (0, r) if r > 0 => {
            let h = u64::from(r).saturating_mul(ch);
            (h.saturating_mul(source_w).div_ceil(source_h), h)
        }
        _ => (source_w, source_h),
    };
    let columns = if o.columns > 0 {
        u64::from(o.columns)
    } else {
        width.saturating_add(u64::from(o.offset_x)).div_ceil(cw)
    };
    let rows = if o.rows > 0 {
        u64::from(o.rows)
    } else {
        height.saturating_add(u64::from(o.offset_y)).div_ceil(ch)
    };
    (
        columns.min(usize::MAX as u64) as usize,
        rows.min(usize::MAX as u64) as usize,
    )
}
