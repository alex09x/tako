/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::reader::Reader;
use super::types::{
    CELL_BYTES, CheckpointError, GRID_ROW_SPINE, MAX_DIM, MAX_SCROLLBACK_LEN,
    MIN_BYTES_PER_SCROLLBACK_ROW, SCROLLBACK_ROW_SPINE,
};
use super::writer::Writer;
use crate::grid::{Grid, RowOwner, ScrollbackRow, SemanticPrompt};

pub(crate) fn owner_tag(owner: RowOwner) -> (u8, u64) {
    match owner {
        RowOwner::Empty => (0, 0),
        RowOwner::Unowned => (1, 0),
        RowOwner::Mixed => (2, 0),
        RowOwner::Command(id) => (3, id),
    }
}

pub(crate) fn write_opt_u64(w: &mut Writer, v: Option<u64>) {
    w.write_bool(v.is_some());
    w.write_u64(v.unwrap_or(0));
}

pub(crate) fn read_opt_u64(r: &mut Reader<'_>) -> Result<Option<u64>, CheckpointError> {
    let present = r.read_bool()?;
    let v = r.read_u64()?;
    Ok(present.then_some(v))
}

pub(crate) fn write_opt_string(w: &mut Writer, v: Option<&str>) {
    w.write_bool(v.is_some());
    if let Some(v) = v {
        w.write_string(v);
    }
}

pub(crate) fn read_opt_string(r: &mut Reader<'_>) -> Result<Option<String>, CheckpointError> {
    if r.read_bool()? {
        Ok(Some(r.read_string_budgeted()?))
    } else {
        Ok(None)
    }
}

/// A grid's grapheme clusters (v3): a count, then line, column, the text
/// after the cell's character and whether it is drawn wide. The cells carry
/// only their first character; this is the rest.
pub(crate) fn write_clusters(w: &mut Writer, grid: &Grid) {
    let clusters = grid.clusters();
    w.write_u32(clusters.len() as u32);
    for (line, col, extra, wide) in clusters {
        w.write_u32(line as u32);
        w.write_u32(col as u32);
        w.write_string(extra);
        w.write_bool(wide);
    }
}

/// [`write_clusters`]' block, applied to the grid it was written from. A
/// cluster naming a cell the grid does not have is corrupt data, not
/// something to skip.
pub(crate) fn read_clusters(r: &mut Reader<'_>, grid: &mut Grid) -> Result<(), CheckpointError> {
    let count = r.read_u32()? as usize;
    // line, column, a length prefix and the flag: 13 bytes at the least.
    r.check_count(count, 13)?;
    for _ in 0..count {
        let line = r.read_u32()? as usize;
        let col = r.read_u32()? as usize;
        let extra = r.read_string_budgeted()?;
        let wide = r.read_bool()?;
        if !grid.restore_cluster(line, col, &extra, wide) {
            return Err(CheckpointError::InvalidData(
                "grapheme cluster names no cell",
            ));
        }
    }
    Ok(())
}

/// One grid's slice of the container: capacity, eviction counter, scrollback,
/// then the live rows.
pub(crate) fn write_grid(w: &mut Writer, grid: &Grid, rows: usize, version: u32) {
    w.write_u32(grid.scrollback_capacity() as u32);
    w.write_u64(grid.history_evicted() as u64);
    w.write_u32(grid.scrollback_rows().len() as u32);
    for row in grid.scrollback_rows() {
        w.write_bool(row.wrapped);
        if version >= 5 {
            w.write_u8(match row.semantic {
                SemanticPrompt::Unset => 0,
                SemanticPrompt::Prompt => 1,
                SemanticPrompt::PromptContinuation => 2,
            });
        }
        w.write_u32(row.cells.len() as u32);
        w.write_cells(&row.cells);
    }
    for r in 0..rows {
        w.write_bool(grid.is_line_wrapped(r));
        w.write_u8(match grid.row_semantic_prompt(r) {
            SemanticPrompt::Unset => 0,
            SemanticPrompt::Prompt => 1,
            SemanticPrompt::PromptContinuation => 2,
        });
        w.write_cells(grid.row_cells(r));
    }
}

/// Read a grid and its scrollback from the checkpoint reader.
pub(crate) fn read_grid(
    r: &mut Reader<'_>,
    cols: usize,
    rows: usize,
    version: u32,
) -> Result<(Grid, usize), CheckpointError> {
    let cap = r.read_u32()? as usize;
    if cap > MAX_SCROLLBACK_LEN {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    let evicted = r.read_u64()? as usize;
    let sb_len = r.read_u32()? as usize;
    if sb_len > MAX_SCROLLBACK_LEN {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(sb_len, MIN_BYTES_PER_SCROLLBACK_ROW)?;
    r.charge_spine(sb_len, SCROLLBACK_ROW_SPINE)?;
    let mut sb = Vec::with_capacity(sb_len);
    for _ in 0..sb_len {
        let wrapped = r.read_bool()?;
        let semantic = if version >= 5 {
            match r.read_u8()? {
                0 => SemanticPrompt::Unset,
                1 => SemanticPrompt::Prompt,
                2 => SemanticPrompt::PromptContinuation,
                _ => return Err(CheckpointError::InvalidData("invalid semantic prompt")),
            }
        } else {
            SemanticPrompt::Unset
        };
        let cells_len = r.read_u32()? as usize;
        if cells_len > MAX_DIM {
            return Err(CheckpointError::AllocationLimitExceeded);
        }
        r.charge((cells_len as u64).saturating_mul(CELL_BYTES))?;
        let cells = r.read_cells(cells_len)?;
        let owner = RowOwner::of_cells(&cells);
        sb.push(ScrollbackRow {
            cells,
            wrapped,
            owner,
            semantic,
        });
    }
    r.charge(
        (rows as u64)
            .saturating_mul(cols as u64)
            .saturating_mul(CELL_BYTES),
    )?;
    r.charge_spine(rows, GRID_ROW_SPINE)?;
    let mut grid_cells = Vec::with_capacity(rows);
    let mut grid_wrapped = Vec::with_capacity(rows);
    let mut grid_sem = Vec::with_capacity(rows);
    for _ in 0..rows {
        grid_wrapped.push(r.read_bool()?);
        grid_sem.push(match r.read_u8()? {
            0 => SemanticPrompt::Unset,
            1 => SemanticPrompt::Prompt,
            2 => SemanticPrompt::PromptContinuation,
            _ => return Err(CheckpointError::InvalidData("invalid semantic prompt")),
        });
        grid_cells.push(r.read_cells(cols)?);
    }
    let grid = Grid::from_raw_parts(
        cols,
        rows,
        cap,
        evicted,
        grid_cells,
        grid_wrapped,
        grid_sem,
        sb,
    );
    Ok((grid, sb_len))
}
