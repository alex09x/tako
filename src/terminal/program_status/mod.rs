/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Program Status Protocol (`OSC 7501`, revision 0.4) state table and drain.

mod apply;
pub(crate) mod parse;
#[cfg(test)]
mod tests;

use std::collections::{HashMap, VecDeque};

use crate::terminal::checkpoint::map_spine;

/// Exact capability reply written to the PTY for `OSC 7501 ; ? ST`.
pub const CAPABILITY_REPLY: &str =
    "\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\";

pub const MAX_SEQUENCE_BYTES: usize = 4096;
pub const MAX_KEY_BYTES: usize = 16;
pub const MAX_MSG_ENCODED_BYTES: usize = 2732;
pub const MAX_MSG_DECODED_BYTES: usize = 2048;
pub const MAX_TITLE_ENCODED_BYTES: usize = 256;
pub const MAX_TITLE_DECODED_BYTES: usize = 192;
pub const MAX_APP_BYTES: usize = 32;
pub const MAX_ID_BYTES: usize = 128;
pub const MAX_ID_SEGMENT_BYTES: usize = 32;
pub const MAX_ID_DEPTH: usize = 8;
pub const MAX_RECORDS: usize = 256;
pub const MAX_PENDING_STATUS_UPDATES: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ProgramStatusState {
    Idle = 1,
    Working = 2,
    Done = 3,
    Blocked = 4,
    Error = 5,
}

impl ProgramStatusState {
    pub(crate) fn priority_tier(self) -> u8 {
        match self {
            Self::Blocked => 5,
            Self::Working => 4,
            Self::Error => 3,
            Self::Done => 2,
            Self::Idle => 1,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ProgramStatusBlockedKind {
    Permission = 1,
    Question = 2,
    Auth = 3,
}

impl ProgramStatusBlockedKind {
    pub(crate) fn priority_rank(self) -> u8 {
        match self {
            Self::Permission => 3,
            Self::Auth => 2,
            Self::Question => 1,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ProgramStatusRemovalReason {
    ExplicitClear = 1,
    PromptReturn = 2,
    ProcessExit = 3,
    Interrupted = 4,
    Acknowledged = 5,
    HardReset = 6,
    Evicted = 7,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgramStatusRecord {
    pub id: String,
    pub state: ProgramStatusState,
    pub kind: Option<ProgramStatusBlockedKind>,
    pub progress: Option<u8>,
    pub app: Option<String>,
    pub resolved_app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
    pub revision: u64,
}

impl ProgramStatusRecord {
    pub(crate) fn heap_bytes(&self) -> u64 {
        (self.id.capacity() as u64)
            .saturating_add(self.app.as_ref().map_or(0, |s| s.capacity() as u64))
            .saturating_add(
                self.resolved_app
                    .as_ref()
                    .map_or(0, |s| s.capacity() as u64),
            )
            .saturating_add(self.title.as_ref().map_or(0, |s| s.capacity() as u64))
            .saturating_add(self.msg.as_ref().map_or(0, |s| s.capacity() as u64))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProgramStatusMutation {
    Upserted {
        record: ProgramStatusRecord,
    },
    Removed {
        id: String,
        previous: ProgramStatusRecord,
        reason: ProgramStatusRemovalReason,
    },
    Reset {
        removed_count: u32,
        reason: ProgramStatusRemovalReason,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgramStatusUpdate {
    pub revision: u64,
    pub mutations: Vec<ProgramStatusMutation>,
    pub effective: Option<ProgramStatusRecord>,
}

impl ProgramStatusUpdate {
    pub(crate) fn heap_bytes(&self) -> u64 {
        let mut bytes = (self.mutations.capacity() as u64)
            .saturating_mul(std::mem::size_of::<ProgramStatusMutation>() as u64);
        for m in &self.mutations {
            match m {
                ProgramStatusMutation::Upserted { record } => {
                    bytes = bytes.saturating_add(record.heap_bytes());
                }
                ProgramStatusMutation::Removed { id, previous, .. } => {
                    bytes = bytes
                        .saturating_add(id.capacity() as u64)
                        .saturating_add(previous.heap_bytes());
                }
                ProgramStatusMutation::Reset { .. } => {}
            }
        }
        if let Some(eff) = &self.effective {
            bytes = bytes.saturating_add(eff.heap_bytes());
        }
        bytes
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgramStatusSnapshot {
    pub revision: u64,
    pub osc7501_active: bool,
    pub effective: Option<ProgramStatusRecord>,
    pub records: Vec<ProgramStatusRecord>,
}

/// Bounded pull-on-feed batch of `OSC 7501` updates.
///
/// When `has_more` is `true`, the caller must continue draining in the same
/// serialized turn. When a single burst exceeded [`MAX_PENDING_STATUS_UPDATES`],
/// `overflow_coalesced` is `true`, `overflow_from_revision` marks the first
/// dropped update revision, and `resync_snapshot` carries the latest
/// authoritative [`ProgramStatusSnapshot`] for immediate resynchronization.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgramStatusDrainBatch {
    pub snapshot_revision: u64,
    pub updates: Vec<ProgramStatusUpdate>,
    pub has_more: bool,
    pub overflow_coalesced: bool,
    pub overflow_from_revision: u64,
    pub resync_snapshot: Option<ProgramStatusSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StoredRecord {
    pub(crate) id: String,
    pub(crate) state: ProgramStatusState,
    pub(crate) kind: Option<ProgramStatusBlockedKind>,
    pub(crate) progress: Option<u8>,
    pub(crate) app: Option<String>,
    pub(crate) title: Option<String>,
    pub(crate) msg: Option<String>,
    pub(crate) revision: u64,
    pub(crate) lru_tick: u64,
}

impl StoredRecord {
    pub(crate) fn same_semantics(&self, other: &StoredRecord) -> bool {
        self.state == other.state
            && self.kind == other.kind
            && self.progress == other.progress
            && self.app == other.app
            && self.title == other.title
            && self.msg == other.msg
    }
}

#[derive(Debug, Clone)]
pub(crate) struct ProgramStatusTable {
    pub(crate) records: HashMap<String, StoredRecord>,
    pub(crate) pending_updates: VecDeque<ProgramStatusUpdate>,
    pub(crate) overflow_from_revision: Option<u64>,
    pub(crate) events_emitted_since_take: usize,
    pub(crate) revision: u64,
    pub(crate) lru_clock: u64,
    pub(crate) osc7501_active: bool,
    pub(crate) probe_reply_enabled: bool,
}

impl Default for ProgramStatusTable {
    fn default() -> Self {
        Self::new()
    }
}

impl ProgramStatusTable {
    pub(crate) fn new() -> Self {
        Self {
            records: HashMap::new(),
            pending_updates: VecDeque::new(),
            overflow_from_revision: None,
            events_emitted_since_take: 0,
            revision: 0,
            lru_clock: 0,
            osc7501_active: false,
            probe_reply_enabled: true,
        }
    }

    pub(crate) fn next_lru_tick(&mut self) -> u64 {
        self.lru_clock = self.lru_clock.saturating_add(1);
        self.lru_clock
    }

    pub(crate) fn bump_revision(&mut self) -> u64 {
        self.revision = self.revision.saturating_add(1);
        self.revision
    }

    pub(crate) fn record_update(&mut self, update: ProgramStatusUpdate) -> bool {
        if self.pending_updates.len() >= MAX_PENDING_STATUS_UPDATES
            && let Some(dropped) = self.pending_updates.pop_front()
        {
            self.overflow_from_revision.get_or_insert(dropped.revision);
        }
        let within_cap = self.overflow_from_revision.is_none();
        self.pending_updates.push_back(update);
        within_cap
    }

    pub(crate) fn discard_pending_updates(&mut self) {
        self.pending_updates.clear();
        self.overflow_from_revision = None;
        self.events_emitted_since_take = 0;
    }

    pub(crate) fn drain_updates(&mut self, max_updates: usize) -> ProgramStatusDrainBatch {
        if max_updates == 0 {
            let overflow_from_revision = self.overflow_from_revision.unwrap_or(0);
            return ProgramStatusDrainBatch {
                snapshot_revision: self.revision,
                updates: Vec::new(),
                has_more: !self.pending_updates.is_empty(),
                overflow_coalesced: self.overflow_from_revision.is_some(),
                overflow_from_revision,
                resync_snapshot: self.overflow_from_revision.map(|_| self.snapshot()),
            };
        }
        if let Some(gap_rev) = self.overflow_from_revision.take() {
            self.pending_updates.clear();
            return ProgramStatusDrainBatch {
                snapshot_revision: self.revision,
                updates: Vec::new(),
                has_more: false,
                overflow_coalesced: true,
                overflow_from_revision: gap_rev,
                resync_snapshot: Some(self.snapshot()),
            };
        }
        let count = max_updates.min(self.pending_updates.len());
        let mut updates = Vec::with_capacity(count);
        for _ in 0..count {
            if let Some(u) = self.pending_updates.pop_front() {
                updates.push(u);
            }
        }
        ProgramStatusDrainBatch {
            snapshot_revision: self.revision,
            updates,
            has_more: !self.pending_updates.is_empty(),
            overflow_coalesced: false,
            overflow_from_revision: 0,
            resync_snapshot: None,
        }
    }

    pub(crate) fn resolve_app_for(&self, id: &str, explicit_app: Option<&str>) -> Option<String> {
        if let Some(app) = explicit_app {
            return Some(app.to_string());
        }
        if !id.is_empty() {
            let mut cursor = id;
            while let Some((parent, _)) = cursor.rsplit_once('/') {
                if let Some(app) = self.records.get(parent).and_then(|r| r.app.as_ref()) {
                    return Some(app.clone());
                }
                cursor = parent;
            }
            if let Some(app) = self.records.get("").and_then(|r| r.app.as_ref()) {
                return Some(app.clone());
            }
        }
        None
    }

    pub(crate) fn materialize(&self, stored: &StoredRecord) -> ProgramStatusRecord {
        ProgramStatusRecord {
            id: stored.id.clone(),
            state: stored.state,
            kind: stored.kind,
            progress: stored.progress,
            app: stored.app.clone(),
            resolved_app: self.resolve_app_for(&stored.id, stored.app.as_deref()),
            title: stored.title.clone(),
            msg: stored.msg.clone(),
            revision: stored.revision,
        }
    }

    pub(crate) fn compute_effective(&self) -> Option<ProgramStatusRecord> {
        let best = self.records.values().max_by(|a, b| {
            let tier_cmp = a.state.priority_tier().cmp(&b.state.priority_tier());
            if tier_cmp != std::cmp::Ordering::Equal {
                return tier_cmp;
            }
            if a.state == ProgramStatusState::Blocked {
                let kind_a = a.kind.map_or(0, ProgramStatusBlockedKind::priority_rank);
                let kind_b = b.kind.map_or(0, ProgramStatusBlockedKind::priority_rank);
                let kind_cmp = kind_a.cmp(&kind_b);
                if kind_cmp != std::cmp::Ordering::Equal {
                    return kind_cmp;
                }
            }
            a.revision.cmp(&b.revision)
        })?;
        Some(self.materialize(best))
    }

    pub(crate) fn snapshot(&self) -> ProgramStatusSnapshot {
        let mut list: Vec<ProgramStatusRecord> =
            self.records.values().map(|r| self.materialize(r)).collect();
        list.sort_by(|a, b| a.id.cmp(&b.id));
        ProgramStatusSnapshot {
            revision: self.revision,
            osc7501_active: self.osc7501_active,
            effective: self.compute_effective(),
            records: list,
        }
    }

    pub(crate) fn retained_capacity_bytes(&self) -> u64 {
        let entry_sz = std::mem::size_of::<(String, StoredRecord)>() as u64;
        let mut total = map_spine(self.records.capacity() as u64, entry_sz);
        for (k, v) in &self.records {
            total = total
                .saturating_add(k.capacity() as u64)
                .saturating_add(v.id.capacity() as u64)
                .saturating_add(v.app.as_ref().map_or(0, |s| s.capacity() as u64))
                .saturating_add(v.title.as_ref().map_or(0, |s| s.capacity() as u64))
                .saturating_add(v.msg.as_ref().map_or(0, |s| s.capacity() as u64));
        }
        total = total.saturating_add(
            (self.pending_updates.capacity() as u64)
                .saturating_mul(std::mem::size_of::<ProgramStatusUpdate>() as u64),
        );
        for u in &self.pending_updates {
            total = total.saturating_add(u.heap_bytes());
        }
        total
    }
}
