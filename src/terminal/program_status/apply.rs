/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::borrow::Cow;

use crate::response::TerminalReplyClass;
use crate::terminal::events::TerminalEvent;
use crate::terminal::state::Terminal;

use super::parse::{ParsedAction, parse_report, trim_ascii};
use super::{
    CAPABILITY_REPLY, MAX_RECORDS, MAX_SEQUENCE_BYTES, ProgramStatusDrainBatch,
    ProgramStatusMutation, ProgramStatusRecord, ProgramStatusRemovalReason, ProgramStatusSnapshot,
    ProgramStatusState, ProgramStatusTable, ProgramStatusUpdate, StoredRecord,
};

fn is_subtree_member(record_id: &str, target_id: &str) -> bool {
    record_id == target_id
        || (record_id.starts_with(target_id)
            && record_id.as_bytes().get(target_id.len()) == Some(&b'/'))
}

impl ProgramStatusTable {
    pub(crate) fn hard_reset(&mut self) -> Option<ProgramStatusUpdate> {
        self.osc7501_active = false;
        let removed_count = self.records.len() as u32;
        if removed_count == 0 {
            return None;
        }
        self.records.clear();
        let revision = self.bump_revision();
        Some(ProgramStatusUpdate {
            revision,
            mutations: vec![ProgramStatusMutation::Reset {
                removed_count,
                reason: ProgramStatusRemovalReason::HardReset,
            }],
            effective: None,
        })
    }

    pub(crate) fn remove_matching<F>(
        &mut self,
        reason: ProgramStatusRemovalReason,
        mut predicate: F,
    ) -> Option<ProgramStatusUpdate>
    where
        F: FnMut(&StoredRecord) -> bool,
    {
        let mut matching_ids: Vec<String> = self
            .records
            .values()
            .filter(|r| predicate(r))
            .map(|r| r.id.clone())
            .collect();
        if matching_ids.is_empty() {
            return None;
        }
        matching_ids.sort();
        let mut pre_snapshots: Vec<(String, ProgramStatusRecord)> =
            Vec::with_capacity(matching_ids.len());
        for id in &matching_ids {
            if let Some(stored) = self.records.get(id) {
                pre_snapshots.push((id.clone(), self.materialize(stored)));
            }
        }
        for (id, _) in &pre_snapshots {
            self.records.remove(id);
        }
        let revision = self.bump_revision();
        let mutations = pre_snapshots
            .into_iter()
            .map(|(id, previous)| ProgramStatusMutation::Removed {
                id,
                previous,
                reason,
            })
            .collect();
        Some(ProgramStatusUpdate {
            revision,
            mutations,
            effective: self.compute_effective(),
        })
    }
}

impl Terminal {
    pub(crate) fn emit_program_status_stream_update(&mut self, update: ProgramStatusUpdate) {
        let _ = self.program_status.record_update(update.clone());
        if self.program_status.events_emitted_since_take < super::MAX_PENDING_STATUS_UPDATES {
            self.program_status.events_emitted_since_take += 1;
            self.events
                .push(TerminalEvent::ProgramStatusChanged(update));
        }
    }

    pub(crate) fn handle_osc_7501(&mut self, params: &[&[u8]], bell_terminated: bool) {
        if params.len() < 2 {
            return;
        }
        let raw_payload_len: usize =
            params.iter().map(|p| p.len()).sum::<usize>() + params.len().saturating_sub(1);
        let terminator_bytes = if bell_terminated { 1 } else { 2 };
        let total_sequence_bytes = 2 + raw_payload_len + terminator_bytes;
        if total_sequence_bytes > MAX_SEQUENCE_BYTES {
            return;
        }

        if params.len() == 2 && trim_ascii(params[1]) == b"?" {
            if self.program_status.probe_reply_enabled {
                let _ = self.response.push_classified(
                    TerminalReplyClass::ProgramStatusCapability,
                    CAPABILITY_REPLY.as_bytes(),
                );
            }
            return;
        }

        let body: Cow<'_, [u8]> = if params.len() == 2 {
            Cow::Borrowed(params[1])
        } else {
            Cow::Owned(params[1..].join(&b';'))
        };

        let Some(action) = parse_report(&body) else {
            return;
        };

        self.program_status.osc7501_active = true;

        match action {
            ParsedAction::Clear { id } => {
                if id.is_empty() {
                    let removed_count = self.program_status.records.len() as u32;
                    if removed_count == 0 {
                        return;
                    }
                    self.program_status.records.clear();
                    let revision = self.program_status.bump_revision();
                    self.emit_program_status_stream_update(ProgramStatusUpdate {
                        revision,
                        mutations: vec![ProgramStatusMutation::Reset {
                            removed_count,
                            reason: ProgramStatusRemovalReason::ExplicitClear,
                        }],
                        effective: None,
                    });
                } else if let Some(update) = self
                    .program_status
                    .remove_matching(ProgramStatusRemovalReason::ExplicitClear, |r| {
                        is_subtree_member(&r.id, &id)
                    })
                {
                    self.emit_program_status_stream_update(update);
                }
            }
            ParsedAction::Upsert {
                id,
                state,
                kind,
                progress,
                app,
                title,
                msg,
            } => {
                let candidate = StoredRecord {
                    id: id.clone(),
                    state,
                    kind,
                    progress,
                    app,
                    title,
                    msg,
                    revision: 0,
                    lru_tick: 0,
                };

                if let Some(existing) = self.program_status.records.get(&id)
                    && existing.same_semantics(&candidate)
                {
                    let tick = self.program_status.next_lru_tick();
                    if let Some(entry) = self.program_status.records.get_mut(&id) {
                        entry.lru_tick = tick;
                    }
                    return;
                }

                let mut mutations = Vec::with_capacity(2);
                if !self.program_status.records.contains_key(&id)
                    && self.program_status.records.len() >= MAX_RECORDS
                    && let Some(evict_id) = self
                        .program_status
                        .records
                        .values()
                        .min_by_key(|r| r.lru_tick)
                        .map(|r| r.id.clone())
                {
                    if let Some(evicted_stored) = self.program_status.records.get(&evict_id) {
                        let prev = self.program_status.materialize(evicted_stored);
                        mutations.push(ProgramStatusMutation::Removed {
                            id: evict_id.clone(),
                            previous: prev,
                            reason: ProgramStatusRemovalReason::Evicted,
                        });
                    }
                    self.program_status.records.remove(&evict_id);
                }

                let revision = self.program_status.bump_revision();
                let lru_tick = self.program_status.next_lru_tick();
                let stored = StoredRecord {
                    revision,
                    lru_tick,
                    ..candidate
                };
                self.program_status.records.insert(id.clone(), stored);
                if let Some(inserted) = self.program_status.records.get(&id) {
                    let record = self.program_status.materialize(inserted);
                    mutations.push(ProgramStatusMutation::Upserted { record });
                }
                let effective = self.program_status.compute_effective();
                self.emit_program_status_stream_update(ProgramStatusUpdate {
                    revision,
                    mutations,
                    effective,
                });
            }
        }
    }

    pub(crate) fn on_program_status_prompt_mark(&mut self) {
        if let Some(update) =
            self.program_status
                .remove_matching(ProgramStatusRemovalReason::PromptReturn, |r| {
                    matches!(
                        r.state,
                        ProgramStatusState::Working
                            | ProgramStatusState::Blocked
                            | ProgramStatusState::Idle
                    )
                })
        {
            self.emit_program_status_stream_update(update);
        }
    }

    pub(crate) fn on_program_status_hard_reset(&mut self) {
        if let Some(update) = self.program_status.hard_reset() {
            self.emit_program_status_stream_update(update);
        }
    }

    pub fn program_status_snapshot(&self) -> ProgramStatusSnapshot {
        self.program_status.snapshot()
    }

    pub fn is_program_status_probe_reply_enabled(&self) -> bool {
        self.program_status.probe_reply_enabled
    }

    pub fn set_program_status_probe_reply_enabled(&mut self, enabled: bool) {
        self.program_status.probe_reply_enabled = enabled;
    }

    pub fn drain_program_status_updates(&mut self, max_updates: usize) -> ProgramStatusDrainBatch {
        self.program_status.drain_updates(max_updates)
    }

    pub fn discard_program_status_updates(&mut self) {
        self.program_status.discard_pending_updates();
    }

    pub fn program_status_process_exited(&mut self) -> Option<ProgramStatusUpdate> {
        let update =
            self.program_status
                .remove_matching(ProgramStatusRemovalReason::ProcessExit, |r| {
                    matches!(
                        r.state,
                        ProgramStatusState::Working
                            | ProgramStatusState::Blocked
                            | ProgramStatusState::Idle
                    )
                })?;
        let _ = self.program_status.record_update(update.clone());
        Some(update)
    }

    pub fn program_status_interrupted(&mut self) -> Option<ProgramStatusUpdate> {
        let update =
            self.program_status
                .remove_matching(ProgramStatusRemovalReason::Interrupted, |r| {
                    matches!(
                        r.state,
                        ProgramStatusState::Working | ProgramStatusState::Blocked
                    )
                })?;
        let _ = self.program_status.record_update(update.clone());
        Some(update)
    }

    pub fn program_status_acknowledged(&mut self) -> Option<ProgramStatusUpdate> {
        let update =
            self.program_status
                .remove_matching(ProgramStatusRemovalReason::Acknowledged, |r| {
                    matches!(
                        r.state,
                        ProgramStatusState::Done | ProgramStatusState::Error
                    )
                })?;
        let _ = self.program_status.record_update(update.clone());
        Some(update)
    }

    /// Consume up to `max_items` classified replies in exact FIFO order.
    pub fn drain_classified_replies(
        &mut self,
        max_items: usize,
    ) -> crate::response::ClassifiedReplyDrain {
        self.response.drain_classified(max_items)
    }
}
