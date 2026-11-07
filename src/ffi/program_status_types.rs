/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::core::{TakoCore, lock_recover};
use crate::response::{ClassifiedReply, ClassifiedReplyDrain, TerminalReplyClass};
use crate::terminal::{
    ProgramStatusBlockedKind, ProgramStatusDrainBatch, ProgramStatusMutation, ProgramStatusRecord,
    ProgramStatusRemovalReason, ProgramStatusSnapshot, ProgramStatusState, ProgramStatusUpdate,
};

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiTerminalReplyClass {
    StandardDevice,
    ProgramStatusCapability,
}

impl From<TerminalReplyClass> for FfiTerminalReplyClass {
    fn from(c: TerminalReplyClass) -> Self {
        match c {
            TerminalReplyClass::StandardDevice => Self::StandardDevice,
            TerminalReplyClass::ProgramStatusCapability => Self::ProgramStatusCapability,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiClassifiedReply {
    pub seq: u64,
    pub reply_class: FfiTerminalReplyClass,
    pub bytes: Vec<u8>,
}

impl From<ClassifiedReply> for FfiClassifiedReply {
    fn from(r: ClassifiedReply) -> Self {
        Self {
            seq: r.seq,
            reply_class: r.class.into(),
            bytes: r.bytes,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiClassifiedReplyDrain {
    pub replies: Vec<FfiClassifiedReply>,
    pub has_more: bool,
    pub overflow_dropped_count: u32,
}

impl From<ClassifiedReplyDrain> for FfiClassifiedReplyDrain {
    fn from(d: ClassifiedReplyDrain) -> Self {
        Self {
            replies: d.replies.into_iter().map(Into::into).collect(),
            has_more: d.has_more,
            overflow_dropped_count: d.overflow_dropped_count,
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiProgramStatusState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

impl From<ProgramStatusState> for FfiProgramStatusState {
    fn from(s: ProgramStatusState) -> Self {
        match s {
            ProgramStatusState::Idle => Self::Idle,
            ProgramStatusState::Working => Self::Working,
            ProgramStatusState::Done => Self::Done,
            ProgramStatusState::Blocked => Self::Blocked,
            ProgramStatusState::Error => Self::Error,
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiProgramStatusBlockedKind {
    Permission,
    Question,
    Auth,
}

impl From<ProgramStatusBlockedKind> for FfiProgramStatusBlockedKind {
    fn from(k: ProgramStatusBlockedKind) -> Self {
        match k {
            ProgramStatusBlockedKind::Permission => Self::Permission,
            ProgramStatusBlockedKind::Question => Self::Question,
            ProgramStatusBlockedKind::Auth => Self::Auth,
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiProgramStatusRemovalReason {
    ExplicitClear,
    PromptReturn,
    ProcessExit,
    Interrupted,
    Acknowledged,
    HardReset,
    Evicted,
}

impl From<ProgramStatusRemovalReason> for FfiProgramStatusRemovalReason {
    fn from(r: ProgramStatusRemovalReason) -> Self {
        match r {
            ProgramStatusRemovalReason::ExplicitClear => Self::ExplicitClear,
            ProgramStatusRemovalReason::PromptReturn => Self::PromptReturn,
            ProgramStatusRemovalReason::ProcessExit => Self::ProcessExit,
            ProgramStatusRemovalReason::Interrupted => Self::Interrupted,
            ProgramStatusRemovalReason::Acknowledged => Self::Acknowledged,
            ProgramStatusRemovalReason::HardReset => Self::HardReset,
            ProgramStatusRemovalReason::Evicted => Self::Evicted,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiProgramStatusRecord {
    pub id: String,
    pub state: FfiProgramStatusState,
    pub kind: Option<FfiProgramStatusBlockedKind>,
    pub progress: Option<u8>,
    pub app: Option<String>,
    pub resolved_app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
    pub revision: u64,
}

impl From<ProgramStatusRecord> for FfiProgramStatusRecord {
    fn from(r: ProgramStatusRecord) -> Self {
        Self {
            id: r.id,
            state: r.state.into(),
            kind: r.kind.map(Into::into),
            progress: r.progress,
            app: r.app,
            resolved_app: r.resolved_app,
            title: r.title,
            msg: r.msg,
            revision: r.revision,
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, PartialEq, Eq)]
pub enum FfiProgramStatusMutation {
    Upserted {
        record: FfiProgramStatusRecord,
    },
    Removed {
        id: String,
        previous: FfiProgramStatusRecord,
        reason: FfiProgramStatusRemovalReason,
    },
    Reset {
        removed_count: u32,
        reason: FfiProgramStatusRemovalReason,
    },
}

impl From<ProgramStatusMutation> for FfiProgramStatusMutation {
    fn from(m: ProgramStatusMutation) -> Self {
        match m {
            ProgramStatusMutation::Upserted { record } => Self::Upserted {
                record: record.into(),
            },
            ProgramStatusMutation::Removed {
                id,
                previous,
                reason,
            } => Self::Removed {
                id,
                previous: previous.into(),
                reason: reason.into(),
            },
            ProgramStatusMutation::Reset {
                removed_count,
                reason,
            } => Self::Reset {
                removed_count,
                reason: reason.into(),
            },
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiProgramStatusUpdate {
    pub revision: u64,
    pub mutations: Vec<FfiProgramStatusMutation>,
    pub effective: Option<FfiProgramStatusRecord>,
}

impl From<ProgramStatusUpdate> for FfiProgramStatusUpdate {
    fn from(u: ProgramStatusUpdate) -> Self {
        Self {
            revision: u.revision,
            mutations: u.mutations.into_iter().map(Into::into).collect(),
            effective: u.effective.map(Into::into),
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiProgramStatusSnapshot {
    pub revision: u64,
    pub osc7501_active: bool,
    pub effective: Option<FfiProgramStatusRecord>,
    pub records: Vec<FfiProgramStatusRecord>,
}

impl From<ProgramStatusSnapshot> for FfiProgramStatusSnapshot {
    fn from(s: ProgramStatusSnapshot) -> Self {
        Self {
            revision: s.revision,
            osc7501_active: s.osc7501_active,
            effective: s.effective.map(Into::into),
            records: s.records.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiProgramStatusDrainBatch {
    pub snapshot_revision: u64,
    pub updates: Vec<FfiProgramStatusUpdate>,
    pub has_more: bool,
    pub overflow_coalesced: bool,
    pub overflow_from_revision: u64,
    pub resync_snapshot: Option<FfiProgramStatusSnapshot>,
}

impl From<ProgramStatusDrainBatch> for FfiProgramStatusDrainBatch {
    fn from(b: ProgramStatusDrainBatch) -> Self {
        Self {
            snapshot_revision: b.snapshot_revision,
            updates: b.updates.into_iter().map(Into::into).collect(),
            has_more: b.has_more,
            overflow_coalesced: b.overflow_coalesced,
            overflow_from_revision: b.overflow_from_revision,
            resync_snapshot: b.resync_snapshot.map(Into::into),
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiProgramStatusLifecycle {
    ProcessExited,
    Interrupted,
    Acknowledged,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiProgramStatusLifecycleOutcome {
    pub update: FfiProgramStatusUpdate,
    pub snapshot: FfiProgramStatusSnapshot,
    pub epoch: u64,
}

#[uniffi::export]
impl TakoCore {
    pub fn program_status_snapshot(&self) -> FfiProgramStatusSnapshot {
        lock_recover(&self.inner).program_status_snapshot().into()
    }

    pub fn is_program_status_probe_reply_enabled(&self) -> bool {
        lock_recover(&self.inner).is_program_status_probe_reply_enabled()
    }

    pub fn set_program_status_probe_reply_enabled(&self, enabled: bool) {
        lock_recover(&self.inner).set_program_status_probe_reply_enabled(enabled);
    }

    pub fn drain_program_status_updates(&self, max_updates: u32) -> FfiProgramStatusDrainBatch {
        lock_recover(&self.inner)
            .drain_program_status_updates(max_updates as usize)
            .into()
    }

    pub fn drain_classified_replies(&self, max_replies: u32) -> FfiClassifiedReplyDrain {
        lock_recover(&self.inner)
            .drain_classified_replies(max_replies as usize)
            .into()
    }

    pub fn apply_program_status_lifecycle(
        &self,
        lifecycle: FfiProgramStatusLifecycle,
    ) -> Option<FfiProgramStatusLifecycleOutcome> {
        let mut engine = lock_recover(&self.inner);
        let update = match lifecycle {
            FfiProgramStatusLifecycle::ProcessExited => engine.program_status_process_exited()?,
            FfiProgramStatusLifecycle::Interrupted => engine.program_status_interrupted()?,
            FfiProgramStatusLifecycle::Acknowledged => engine.program_status_acknowledged()?,
        };
        engine.discard_program_status_updates();
        let snapshot = engine.program_status_snapshot().into();
        let epoch = engine.epoch;
        Some(FfiProgramStatusLifecycleOutcome {
            update: update.into(),
            snapshot,
            epoch,
        })
    }

    pub fn program_status_process_exited(&self) -> Option<FfiProgramStatusUpdate> {
        lock_recover(&self.inner)
            .program_status_process_exited()
            .map(Into::into)
    }

    pub fn program_status_interrupted(&self) -> Option<FfiProgramStatusUpdate> {
        lock_recover(&self.inner)
            .program_status_interrupted()
            .map(Into::into)
    }

    pub fn program_status_acknowledged(&self) -> Option<FfiProgramStatusUpdate> {
        lock_recover(&self.inner)
            .program_status_acknowledged()
            .map(Into::into)
    }
}
