/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Where an OSC 1337 inline image is drawn. The image itself is stored at
//! the size it is encoded at; the size a program asks for becomes the
//! placement's cell box -- the `columns`/`rows` the Kitty protocol uses --
//! which both renderers fit the whole image into, keeping its aspect ratio.
//!
//! `width`/`height` in cells are exact. `Npx` is taken to the nearest whole
//! cell (at least 1): the placement has no pixel size. `auto`, `N%` and
//! anything else leave that side to the image. Stretching the image out of
//! its ratio (`preserveAspectRatio=0`) is not supported: it is drawn fitted.
//! A box is at most 1024 cells each way; one the image would be drawn taller
//! than that in is held to 1024 rows, which the image is then fitted inside.

use super::super::types::MAX_INLINE_IMAGE_ROW_SPAN;
use super::kitty_geometry::placement_spans;
use crate::graphics::PlacementOptions;

/// The most cells either side of a requested box may span.
const MAX_CELLS: u64 = MAX_INLINE_IMAGE_ROW_SPAN as u64;

/// One requested side.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Dim {
    Px(u64),
    Cells(u64),
}

impl Dim {
    /// `N` cells or `Npx`, N above 0; anything else is no request. A number
    /// too long for u64 is taken as the largest, then capped.
    pub(crate) fn parse(value: &str) -> Option<Self> {
        let number = |s: &str| -> Option<u64> {
            if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let n = s.parse::<u64>().unwrap_or(u64::MAX);
            (n > 0).then_some(n)
        };
        match value.strip_suffix("px") {
            Some(px) => number(px).map(Self::Px),
            None => number(value).map(Self::Cells),
        }
    }

    /// Whole cells of `cell` pixels: pixels to the nearest cell, at least 1.
    fn cells(self, cell: u32) -> u64 {
        let cell = (cell as u64).max(1);
        let n = match self {
            Self::Cells(n) => n,
            Self::Px(px) => (px.saturating_add(cell / 2) / cell).max(1),
        };
        n.min(MAX_CELLS)
    }
}

/// The placement's cell box (0 for a side left to the image) and the rows
/// the cursor moves down past it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct InlineBox {
    pub columns: u32,
    pub rows: u32,
    pub advance: usize,
}

/// The box for an image of `intrinsic` pixels (0 when unknown) on cells of
/// `cell` (width, height) pixels. The advance is the rows a Kitty placement
/// of the same box takes -- the box's rows when given, else the height the
/// columns scale the image to, else the image's own height -- so the cursor
/// lands below what the renderers draw. An image of unknown size advances
/// by the rows asked for, or one.
pub(crate) fn inline_box(
    intrinsic: (u32, u32),
    width: Option<Dim>,
    height: Option<Dim>,
    cell: (u32, u32),
) -> InlineBox {
    let columns = width.map_or(0, |d| d.cells(cell.0)) as u32;
    let mut rows = height.map_or(0, |d| d.cells(cell.1)) as u32;
    let spans = |rows| {
        let options = PlacementOptions {
            columns,
            rows,
            ..Default::default()
        };
        placement_spans(options, intrinsic, cell).1
    };
    let advance = if intrinsic.0 == 0 || intrinsic.1 == 0 {
        rows as usize
    } else {
        // A box the image would be drawn taller than the cap -- columns that
        // scale a tall image up, or a tall image at its own size -- is given
        // the cap as its height, so what is drawn ends where the cursor does.
        if spans(rows) > MAX_CELLS as usize {
            rows = MAX_CELLS as u32;
        }
        spans(rows)
    };
    InlineBox {
        columns,
        rows,
        advance: advance.clamp(1, MAX_CELLS as usize),
    }
}
