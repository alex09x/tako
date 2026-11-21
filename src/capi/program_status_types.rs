/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::os::raw::{c_char, c_int};

pub const PROD_VT_STATUS_STATE_NONE: u8 = 0;
pub const PROD_VT_STATUS_STATE_IDLE: u8 = 1;
pub const PROD_VT_STATUS_STATE_WORKING: u8 = 2;
pub const PROD_VT_STATUS_STATE_DONE: u8 = 3;
pub const PROD_VT_STATUS_STATE_BLOCKED: u8 = 4;
pub const PROD_VT_STATUS_STATE_ERROR: u8 = 5;

pub const PROD_VT_STATUS_KIND_NONE: u8 = 0;
pub const PROD_VT_STATUS_KIND_PERMISSION: u8 = 1;
pub const PROD_VT_STATUS_KIND_QUESTION: u8 = 2;
pub const PROD_VT_STATUS_KIND_AUTH: u8 = 3;

pub const PROD_VT_STATUS_REASON_NONE: u8 = 0;
pub const PROD_VT_STATUS_REASON_EXPLICIT_CLEAR: u8 = 1;
pub const PROD_VT_STATUS_REASON_PROMPT_RETURN: u8 = 2;
pub const PROD_VT_STATUS_REASON_PROCESS_EXIT: u8 = 3;
pub const PROD_VT_STATUS_REASON_INTERRUPTED: u8 = 4;
pub const PROD_VT_STATUS_REASON_ACKNOWLEDGED: u8 = 5;
pub const PROD_VT_STATUS_REASON_HARD_RESET: u8 = 6;
pub const PROD_VT_STATUS_REASON_EVICTED: u8 = 7;

pub const PROD_VT_STATUS_MUTATION_UPSERTED: u8 = 1;
pub const PROD_VT_STATUS_MUTATION_REMOVED: u8 = 2;
pub const PROD_VT_STATUS_MUTATION_RESET: u8 = 3;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct ProdVtUtf8View {
    pub ptr: *const c_char,
    pub len: usize,
    pub present: u8,
    pub reserved: [u8; 7],
}

impl ProdVtUtf8View {
    pub const NONE: Self = Self {
        ptr: std::ptr::null(),
        len: 0,
        present: 0,
        reserved: [0; 7],
    };
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct ProdVtProgramStatusRecord {
    pub revision: u64,
    pub state: u8,
    pub kind: u8,
    pub has_progress: u8,
    pub progress: u8,
    pub reserved: u32,
    pub id: ProdVtUtf8View,
    pub app: ProdVtUtf8View,
    pub resolved_app: ProdVtUtf8View,
    pub title: ProdVtUtf8View,
    pub msg: ProdVtUtf8View,
}

impl ProdVtProgramStatusRecord {
    pub const ZERO: Self = Self {
        revision: 0,
        state: PROD_VT_STATUS_STATE_NONE,
        kind: PROD_VT_STATUS_KIND_NONE,
        has_progress: 0,
        progress: 0,
        reserved: 0,
        id: ProdVtUtf8View::NONE,
        app: ProdVtUtf8View::NONE,
        resolved_app: ProdVtUtf8View::NONE,
        title: ProdVtUtf8View::NONE,
        msg: ProdVtUtf8View::NONE,
    };
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct ProdVtProgramStatusMutation {
    pub mutation_type: u8,
    pub reason: u8,
    pub reserved: u16,
    pub removed_count: u32,
    pub id: ProdVtUtf8View,
    pub record: ProdVtProgramStatusRecord,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct ProdVtProgramStatusUpdate {
    pub revision: u64,
    pub has_effective: c_int,
    pub reserved: u32,
    pub effective: ProdVtProgramStatusRecord,
    pub mutations: *const ProdVtProgramStatusMutation,
    pub mutations_len: usize,
}

#[repr(C)]
pub struct ProdVtProgramStatusSnapshot {
    pub abi_version: u32,
    pub osc7501_active: c_int,
    pub revision: u64,
    pub has_effective: c_int,
    pub reserved: u32,
    pub effective: ProdVtProgramStatusRecord,
    pub records: *const ProdVtProgramStatusRecord,
    pub records_len: usize,
}

#[repr(C)]
pub struct ProdVtProgramStatusDrainBatch {
    pub abi_version: u32,
    pub has_more: c_int,
    pub overflow_coalesced: c_int,
    pub has_resync_snapshot: c_int,
    pub snapshot_revision: u64,
    pub overflow_from_revision: u64,
    pub updates: *const ProdVtProgramStatusUpdate,
    pub updates_len: usize,
    pub resync_snapshot: ProdVtProgramStatusSnapshot,
}
