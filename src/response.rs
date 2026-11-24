/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::collections::VecDeque;

/// Maximum number of discrete terminal replies buffered before explicit overflow.
pub const MAX_QUEUED_REPLIES: usize = 256;
/// Maximum aggregate byte payload buffered across queued terminal replies.
pub const MAX_QUEUED_REPLY_BYTES: usize = 65_536;

/// Protocol classification of a terminal-generated PTY reply.
///
/// Allows multi-client hosts (such as a canonical server paired with attached UI
/// clients) to apply selective reply authority for `OSC 7501 ; ?` capability
/// probes without globally disabling `DA1`/`DA2`/`DSR`/`CPR` replies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TerminalReplyClass {
    StandardDevice = 1,
    ProgramStatusCapability = 2,
}

/// One ordered, consume-once reply item produced by the terminal parser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClassifiedReply {
    pub seq: u64,
    pub class: TerminalReplyClass,
    pub bytes: Vec<u8>,
}

/// Result of a bounded consume-once drain from [`ResponseQueue`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClassifiedReplyDrain {
    pub replies: Vec<ClassifiedReply>,
    pub has_more: bool,
    pub overflow_dropped_count: u32,
}

/// Single consume-once FIFO queue of terminal-generated PTY replies.
///
/// Both legacy flat drains ([`Self::take`]) and typed classified drains
/// ([`Self::drain_classified`]) pop from the same underlying `VecDeque`, so
/// mixing or transitioning between the two paths can never emit the same reply
/// twice. Replies are never coalesced; exceeding [`MAX_QUEUED_REPLIES`] or
/// [`MAX_QUEUED_REPLY_BYTES`] preserves existing queued items in FIFO order and
/// increments `overflow_dropped_count` so callers observe explicit backpressure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResponseQueue {
    items: VecDeque<ClassifiedReply>,
    queued_bytes: usize,
    next_seq: u64,
    overflow_dropped_count: u32,
}

impl ResponseQueue {
    pub fn new() -> Self {
        Self {
            items: VecDeque::new(),
            queued_bytes: 0,
            next_seq: 1,
            overflow_dropped_count: 0,
        }
    }

    /// Heap this queue holds, by capacity.
    pub fn retained_capacity_bytes(&self) -> u64 {
        let spine = (self.items.capacity() as u64)
            .saturating_mul(std::mem::size_of::<ClassifiedReply>() as u64);
        let payloads = self
            .items
            .iter()
            .fold(0u64, |acc, r| acc.saturating_add(r.bytes.capacity() as u64));
        spine.saturating_add(payloads)
    }

    /// Push a standard device reply (`DA`, `DSR`, `CPR`, `XTVERSION`, etc.).
    pub fn push_str(&mut self, s: &str) {
        let _ = self.push_classified(TerminalReplyClass::StandardDevice, s.as_bytes());
    }

    /// Push a classified reply into the FIFO queue. Returns `false` and records
    /// an explicit overflow count if the queue's item or byte budget is full.
    pub fn push_classified(&mut self, class: TerminalReplyClass, bytes: &[u8]) -> bool {
        if bytes.is_empty() {
            return true;
        }
        if self.items.len() >= MAX_QUEUED_REPLIES
            || self.queued_bytes.saturating_add(bytes.len()) > MAX_QUEUED_REPLY_BYTES
        {
            self.overflow_dropped_count = self.overflow_dropped_count.saturating_add(1);
            return false;
        }
        let seq = self.next_seq;
        self.next_seq = self.next_seq.saturating_add(1);
        self.queued_bytes += bytes.len();
        self.items.push_back(ClassifiedReply {
            seq,
            class,
            bytes: bytes.to_vec(),
        });
        true
    }

    /// Consume up to `max_items` classified replies in FIFO order.
    pub fn drain_classified(&mut self, max_items: usize) -> ClassifiedReplyDrain {
        if max_items == 0 {
            return ClassifiedReplyDrain {
                replies: Vec::new(),
                has_more: !self.items.is_empty(),
                overflow_dropped_count: self.overflow_dropped_count,
            };
        }
        let count = max_items.min(self.items.len());
        let mut replies = Vec::with_capacity(count);
        for _ in 0..count {
            if let Some(item) = self.items.pop_front() {
                self.queued_bytes = self.queued_bytes.saturating_sub(item.bytes.len());
                replies.push(item);
            }
        }
        let overflow_dropped_count = std::mem::take(&mut self.overflow_dropped_count);
        ClassifiedReplyDrain {
            replies,
            has_more: !self.items.is_empty(),
            overflow_dropped_count,
        }
    }

    /// Legacy flat consume-once drain: concatenates and removes all queued
    /// replies from the same FIFO queue without erasing sticky overflow loss.
    ///
    /// Callers using `take()` / `prod_vt_drain_responses` must inspect overflow
    /// loss via [`Self::take_overflow_dropped_count`] (`prod_vt_take_reply_overflow_count`)
    /// or [`Self::drain_classified`] (`prod_vt_drain_classified_replies`).
    pub fn take(&mut self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.queued_bytes);
        while let Some(item) = self.items.pop_front() {
            out.extend_from_slice(&item.bytes);
        }
        self.queued_bytes = 0;
        out
    }

    /// Consume and reset sticky reply-queue overflow count accumulated since the
    /// previous classified drain, explicit overflow check, or hard reset.
    pub fn take_overflow_dropped_count(&mut self) -> u32 {
        std::mem::take(&mut self.overflow_dropped_count)
    }

    pub fn clear(&mut self) {
        self.items.clear();
        self.queued_bytes = 0;
        self.overflow_dropped_count = 0;
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty() && self.overflow_dropped_count == 0
    }
}

impl Default for ResponseQueue {
    fn default() -> Self {
        Self::new()
    }
}

pub fn da1_response() -> String {
    "\x1b[?62;22c".to_string()
}

pub fn da2_response() -> String {
    "\x1b[>1;0;0c".to_string()
}

pub fn cursor_position_report(row1: usize, col1: usize) -> String {
    format!("\x1b[{row1};{col1}R")
}

pub fn device_status_ok() -> String {
    "\x1b[0n".to_string()
}

pub fn xtversion_response(name: &str) -> String {
    format!("\x1bP>|{}\x1b\\", name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_da1_and_da2_and_cpr_and_dsr_and_xtversion() {
        assert_eq!(da1_response(), "\x1b[?62;22c");
        assert_eq!(da2_response(), "\x1b[>1;0;0c");
        assert_eq!(cursor_position_report(1, 1), "\x1b[1;1R");
        assert_eq!(cursor_position_report(24, 80), "\x1b[24;80R");
        assert_eq!(device_status_ok(), "\x1b[0n");
        assert_eq!(
            xtversion_response("tako-core 0.1.0"),
            "\x1bP>|tako-core 0.1.0\x1b\\"
        );
    }

    #[test]
    fn test_response_queue_consume_once_and_overflow() {
        let mut queue = ResponseQueue::default();
        assert!(queue.is_empty());
        assert!(queue.push_classified(TerminalReplyClass::ProgramStatusCapability, b"probe"));
        queue.push_str("-da1");

        let first = queue.drain_classified(1);
        assert_eq!(first.replies.len(), 1);
        assert_eq!(first.replies[0].seq, 1);
        assert_eq!(
            first.replies[0].class,
            TerminalReplyClass::ProgramStatusCapability
        );
        assert!(first.has_more);
        assert_eq!(first.overflow_dropped_count, 0);

        // Legacy take() consumes only the remaining second item — never duplicates item 1.
        assert_eq!(queue.take(), b"-da1");
        assert!(queue.is_empty());

        for _ in 0..MAX_QUEUED_REPLIES {
            assert!(queue.push_classified(TerminalReplyClass::StandardDevice, b"x"));
        }
        assert!(!queue.push_classified(TerminalReplyClass::ProgramStatusCapability, b"y"));
        let drained = queue.drain_classified(MAX_QUEUED_REPLIES);
        assert_eq!(drained.replies.len(), MAX_QUEUED_REPLIES);
        assert_eq!(drained.overflow_dropped_count, 1);
        assert!(!drained.has_more);
    }
}
