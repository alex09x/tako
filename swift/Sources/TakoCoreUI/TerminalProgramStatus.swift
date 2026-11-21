/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Classification of a consume-once reply produced by the terminal engine.
public enum TerminalReplyClass: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Standard terminal device replies (`DA1`, `DA2`, `DSR`, `CPR`, `XTVERSION`, `DECRQM`, `OSC` color/clipboard).
    case standardDevice
    /// `OSC 7501 ; ? ST` capability probe reply.
    case programStatusCapability

    init(ffi: FfiTerminalReplyClass) {
        switch ffi {
        case .standardDevice: self = .standardDevice
        case .programStatusCapability: self = .programStatusCapability
        }
    }
}

/// One consume-once reply emitted in FIFO parser order.
public struct TerminalClassifiedReply: Sendable, Equatable, Hashable {
    public let seq: UInt64
    public let replyClass: TerminalReplyClass
    public let bytes: Data

    public init(seq: UInt64, replyClass: TerminalReplyClass, bytes: Data) {
        self.seq = seq
        self.replyClass = replyClass
        self.bytes = bytes
    }

    init(ffi: FfiClassifiedReply) {
        self.seq = ffi.seq
        self.replyClass = TerminalReplyClass(ffi: ffi.replyClass)
        self.bytes = ffi.bytes
    }
}

/// Exhaustive delivery classification distinguishing lossless reply batches from bounded-queue overflow.
public enum TerminalReplyDeliveryOutcome: Sendable, Equatable, Hashable {
    case complete([TerminalClassifiedReply])
    case overflowLoss(preservedReplies: [TerminalClassifiedReply], droppedCount: UInt32)
}

/// Consume-once batch of classified replies drained from a single parser turn.
public struct TerminalClassifiedReplyBatch: Sendable, Equatable, Hashable {
    public let replies: [TerminalClassifiedReply]
    public let overflowDroppedCount: UInt32

    public init(replies: [TerminalClassifiedReply], overflowDroppedCount: UInt32 = 0) {
        self.replies = replies
        self.overflowDroppedCount = overflowDroppedCount
    }

    public var hasOverflowLoss: Bool { overflowDroppedCount > 0 }

    public var isEmpty: Bool { replies.isEmpty && overflowDroppedCount == 0 }

    public var deliveryOutcome: TerminalReplyDeliveryOutcome {
        if overflowDroppedCount > 0 {
            return .overflowLoss(preservedReplies: replies, droppedCount: overflowDroppedCount)
        }
        return .complete(replies)
    }

    public var combinedData: Data {
        var out = Data()
        out.reserveCapacity(replies.reduce(0) { $0 + $1.bytes.count })
        for item in replies {
            out.append(item.bytes)
        }
        return out
    }
}

/// `OSC 7501` program status states (rev 0.4).
public enum TerminalProgramStatusState: String, Sendable, Equatable, Hashable, CaseIterable {
    case idle
    case working
    case done
    case blocked
    case error

    init(ffi: FfiProgramStatusState) {
        switch ffi {
        case .idle: self = .idle
        case .working: self = .working
        case .done: self = .done
        case .blocked: self = .blocked
        case .error: self = .error
        }
    }
}

/// `OSC 7501` sub-reasons for `.blocked` (rev 0.4).
public enum TerminalProgramStatusBlockedKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case permission
    case question
    case auth

    init(ffi: FfiProgramStatusBlockedKind) {
        switch ffi {
        case .permission: self = .permission
        case .question: self = .question
        case .auth: self = .auth
        }
    }
}

/// Why an `OSC 7501` record left the active status table.
public enum TerminalProgramStatusRemovalReason: String, Sendable, Equatable, Hashable, CaseIterable {
    case explicitClear
    case promptReturn
    case processExit
    case interrupted
    case acknowledged
    case hardReset
    case evicted

    init(ffi: FfiProgramStatusRemovalReason) {
        switch ffi {
        case .explicitClear: self = .explicitClear
        case .promptReturn: self = .promptReturn
        case .processExit: self = .processExit
        case .interrupted: self = .interrupted
        case .acknowledged: self = .acknowledged
        case .hardReset: self = .hardReset
        case .evicted: self = .evicted
        }
    }
}

/// Materialized `OSC 7501` record with nearest-ancestor `resolvedApp` inheritance.
public struct TerminalProgramStatusRecord: Sendable, Equatable, Hashable {
    public let id: String
    public let state: TerminalProgramStatusState
    public let kind: TerminalProgramStatusBlockedKind?
    public let progress: UInt8?
    public let app: String?
    public let resolvedApp: String?
    public let title: String?
    public let msg: String?
    public let revision: UInt64

    public init(
        id: String,
        state: TerminalProgramStatusState,
        kind: TerminalProgramStatusBlockedKind? = nil,
        progress: UInt8? = nil,
        app: String? = nil,
        resolvedApp: String? = nil,
        title: String? = nil,
        msg: String? = nil,
        revision: UInt64
    ) {
        self.id = id
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.resolvedApp = resolvedApp
        self.title = title
        self.msg = msg
        self.revision = revision
    }

    init(ffi: FfiProgramStatusRecord) {
        self.id = ffi.id
        self.state = TerminalProgramStatusState(ffi: ffi.state)
        self.kind = ffi.kind.map(TerminalProgramStatusBlockedKind.init(ffi:))
        self.progress = ffi.progress
        self.app = ffi.app
        self.resolvedApp = ffi.resolvedApp
        self.title = ffi.title
        self.msg = ffi.msg
        self.revision = ffi.revision
    }

    /// Human-facing message with rev 0.4 fallback for `.blocked` + `.auth`.
    public var displayMessage: String? {
        if let msg, !msg.isEmpty { return msg }
        if let title, !title.isEmpty { return title }
        if state == .blocked && kind == .auth {
            return "Authentication required"
        }
        return nil
    }
}

/// Atomic mutation inside a `TerminalProgramStatusUpdate`.
public enum TerminalProgramStatusMutation: Sendable, Equatable, Hashable {
    case upserted(record: TerminalProgramStatusRecord)
    case removed(id: String, previous: TerminalProgramStatusRecord, reason: TerminalProgramStatusRemovalReason)
    case reset(removedCount: UInt32, reason: TerminalProgramStatusRemovalReason)

    init(ffi: FfiProgramStatusMutation) {
        switch ffi {
        case .upserted(let record):
            self = .upserted(record: TerminalProgramStatusRecord(ffi: record))
        case let .removed(id, previous, reason):
            self = .removed(
                id: id,
                previous: TerminalProgramStatusRecord(ffi: previous),
                reason: TerminalProgramStatusRemovalReason(ffi: reason)
            )
        case let .reset(removedCount, reason):
            self = .reset(
                removedCount: removedCount,
                reason: TerminalProgramStatusRemovalReason(ffi: reason)
            )
        }
    }
}

/// Ordered `OSC 7501` status update emitted on parser or lifecycle transitions.
public struct TerminalProgramStatusUpdate: Sendable, Equatable, Hashable {
    public let revision: UInt64
    public let mutations: [TerminalProgramStatusMutation]
    public let effective: TerminalProgramStatusRecord?

    public init(
        revision: UInt64,
        mutations: [TerminalProgramStatusMutation],
        effective: TerminalProgramStatusRecord?
    ) {
        self.revision = revision
        self.mutations = mutations
        self.effective = effective
    }

    init(ffi: FfiProgramStatusUpdate) {
        self.revision = ffi.revision
        self.mutations = ffi.mutations.map(TerminalProgramStatusMutation.init(ffi:))
        self.effective = ffi.effective.map(TerminalProgramStatusRecord.init(ffi:))
    }
}

/// Complete point-in-time snapshot of the terminal's `OSC 7501` status table.
public struct TerminalProgramStatusSnapshot: Sendable, Equatable, Hashable {
    public let revision: UInt64
    public let osc7501Active: Bool
    public let effective: TerminalProgramStatusRecord?
    public let records: [TerminalProgramStatusRecord]

    public init(
        revision: UInt64,
        osc7501Active: Bool,
        effective: TerminalProgramStatusRecord?,
        records: [TerminalProgramStatusRecord]
    ) {
        self.revision = revision
        self.osc7501Active = osc7501Active
        self.effective = effective
        self.records = records
    }

    init(ffi: FfiProgramStatusSnapshot) {
        self.revision = ffi.revision
        self.osc7501Active = ffi.osc7501Active
        self.effective = ffi.effective.map(TerminalProgramStatusRecord.init(ffi:))
        self.records = ffi.records.map(TerminalProgramStatusRecord.init(ffi:))
    }
}

/// Host-level `OSC 7501` delivery event across live parsing, burst resync, and checkpoint restore.
public enum TerminalProgramStatusEvent: Sendable, Equatable, Hashable {
    /// Normal ordered mutation applied during live parsing or host lifecycle hooks.
    case updated(TerminalProgramStatusUpdate, snapshot: TerminalProgramStatusSnapshot)
    /// Single parser batch exceeded the bounded 64-update window; resync from `snapshot`.
    case overflowCoalesced(fromRevision: UInt64, snapshot: TerminalProgramStatusSnapshot)
    /// Checkpoint restore resync. Hosts update state without replaying live alerts or probes.
    case restored(TerminalProgramStatusSnapshot)

    public var snapshot: TerminalProgramStatusSnapshot {
        switch self {
        case .updated(_, let snapshot),
             .overflowCoalesced(_, let snapshot),
             .restored(let snapshot):
            return snapshot
        }
    }

    public var isLiveTransition: Bool {
        switch self {
        case .updated, .overflowCoalesced:
            return true
        case .restored:
            return false
        }
    }
}
