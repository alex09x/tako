/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::commands::read_commands;
use super::grid::{write_opt_string, write_opt_u64};
use super::reader::Reader;
use super::types::CheckpointError;
use super::writer::Writer;
use crate::grid::{Grid, RowOwner};

/// One record as `write_commands` lays it out: id, status, code, no
/// cwd, no input, not truncated, no time.
struct Rec(u64, u8, i32);

fn block(
    runs: &[(u8, u64, u32)],
    pen: Option<u64>,
    next: Option<u64>,
    running: Option<u64>,
    recs: &[Rec],
) -> Vec<u8> {
    let mut w = Writer::with_capacity(256, usize::MAX);
    w.write_u32(runs.len() as u32);
    for &(tag, id, n) in runs {
        w.write_u8(tag);
        w.write_u64(id);
        w.write_u32(n);
    }
    write_opt_u64(&mut w, pen);
    write_opt_u64(&mut w, next);
    write_opt_u64(&mut w, running);
    w.write_u32(recs.len() as u32);
    for Rec(id, status, code) in recs {
        w.write_u64(*id);
        w.write_u8(*status);
        w.write_u32(*code as u32);
        write_opt_string(&mut w, None);
        write_opt_string(&mut w, None);
        w.write_bool(false);
        write_opt_u64(&mut w, None);
    }
    write_opt_string(&mut w, None);
    write_opt_u64(&mut w, None);
    w.write_u32(0);
    w.buf
}

/// Decode against a 4x2 grid with no history: the runs must cover 2 rows.
fn decode(bytes: &[u8]) -> Result<(), CheckpointError> {
    let mut grid = Grid::new(4, 2);
    read_commands(&mut Reader::new(bytes), &mut grid, 0, 4).map(|_| ())
}

fn rejected(bytes: &[u8]) -> bool {
    matches!(decode(bytes), Err(CheckpointError::InvalidData(_)))
}

#[test]
fn a_consistent_block_decodes_and_applies_its_owners() {
    let bytes = block(
        &[(3, 1, 1), (0, 0, 1)],
        Some(1),
        Some(2),
        Some(1),
        &[Rec(1, 0, 0)],
    );
    let mut grid = Grid::new(4, 2);
    let state = read_commands(&mut Reader::new(&bytes), &mut grid, 0, 4).unwrap();
    assert_eq!(grid.row_owner(0), RowOwner::Command(1));
    assert_eq!(grid.row_owner(1), RowOwner::Empty);
    assert_eq!(grid.pen_owner(), Some(1));
    assert_eq!(state.log.running(), Some(1));
}

#[test]
fn runs_must_cover_the_rows_exactly_and_be_positive() {
    assert!(rejected(&block(&[(0, 0, 1)], None, Some(1), None, &[])));
    assert!(rejected(&block(&[(0, 0, 3)], None, Some(1), None, &[])));
    assert!(rejected(&block(
        &[(0, 0, 2), (0, 0, 0)],
        None,
        Some(1),
        None,
        &[]
    )));
    assert!(rejected(&block(
        &[(0, 0, u32::MAX), (0, 0, u32::MAX)],
        None,
        Some(1),
        None,
        &[]
    )));
    assert!(rejected(&block(&[(9, 0, 2)], None, Some(1), None, &[])));
    assert!(rejected(&block(&[(1, 7, 2)], None, Some(1), None, &[])));
}

#[test]
fn dangling_owner_ids_are_rejected() {
    assert!(decode(&block(&[(3, 1, 2)], None, Some(2), None, &[])).is_ok());
    assert!(decode(&block(&[(3, 999, 2)], None, None, None, &[])).is_ok());

    assert!(rejected(&block(&[(3, 0, 2)], None, Some(1), None, &[])));
    assert!(rejected(&block(&[(3, 1, 2)], None, Some(1), None, &[])));
    assert!(rejected(&block(&[(3, 9, 2)], None, Some(1), None, &[])));
}

#[test]
fn ids_must_be_unique_ascending_and_below_the_next_id() {
    let ok = [(0, 0, 2)];
    assert!(rejected(&block(
        &ok,
        None,
        Some(9),
        None,
        &[Rec(2, 1, 0), Rec(2, 1, 0)]
    )));
    assert!(rejected(&block(
        &ok,
        None,
        Some(9),
        None,
        &[Rec(3, 1, 0), Rec(2, 1, 0)]
    )));
    assert!(rejected(&block(&ok, None, Some(2), None, &[Rec(2, 1, 0)])));
    assert!(rejected(&block(&ok, None, Some(9), None, &[Rec(0, 1, 0)])));
    assert!(rejected(&block(&ok, None, Some(0), None, &[])));
    assert!(decode(&block(&ok, None, None, None, &[Rec(u64::MAX, 1, 0)])).is_ok());
}

#[test]
fn the_running_command_must_agree_with_the_table_and_the_pen() {
    let ok = [(0, 0, 2)];
    assert!(rejected(&block(&ok, None, Some(9), None, &[Rec(1, 0, 0)])));
    assert!(rejected(&block(
        &ok,
        Some(1),
        Some(9),
        Some(1),
        &[Rec(1, 3, 0)]
    )));
    assert!(rejected(&block(&ok, Some(4), Some(9), Some(4), &[])));
    assert!(rejected(&block(
        &ok,
        None,
        Some(9),
        Some(1),
        &[Rec(1, 0, 0)]
    )));
    assert!(rejected(&block(
        &ok,
        Some(2),
        Some(9),
        Some(1),
        &[Rec(1, 0, 0), Rec(2, 1, 0)]
    )));
    assert!(rejected(&block(&ok, None, Some(9), None, &[Rec(1, 7, 0)])));
}

#[test]
fn a_count_the_payload_cannot_hold_is_refused_before_allocating() {
    let mut bytes = block(&[(0, 0, 2)], None, Some(1), None, &[]);
    let at = 4 + 13 + 9 * 3;
    bytes[at..at + 4].copy_from_slice(&u32::MAX.to_le_bytes());
    assert!(matches!(
        decode(&bytes),
        Err(CheckpointError::UnexpectedEof)
    ));
}
