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
import Combine

/// The ownership state of interactive input for a pane (C7).
public enum InputOwner: Equatable, Sendable, Codable {
    case human
    case agent(name: String)

    public var isAgent: Bool {
        switch self {
        case .human: false
        case .agent: true
        }
    }

    public var agentName: String? {
        switch self {
        case .human: nil
        case .agent(let name): name
        }
    }
}

/// An entry in the per-pane activity log recording automated client actions (C7, G2).
public struct InputActivityRecord: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var client: String
    public var action: String
    public var timestamp: Date

    public init(id: UUID = UUID(), client: String, action: String, timestamp: Date = Date()) {
        self.id = id
        self.client = client
        self.action = action
        self.timestamp = timestamp
    }
}

/// State tracking input ownership, lock status, and activity marks per pane (C7).
public struct PaneInputState: Equatable, Sendable {
    public var isLocked: Bool
    public var owner: InputOwner
    public var previousAgent: String?
    public var lastActivityMark: InputActivityRecord?
    public var activityLog: [InputActivityRecord]

    public init(
        isLocked: Bool = false,
        owner: InputOwner = .human,
        previousAgent: String? = nil,
        lastActivityMark: InputActivityRecord? = nil,
        activityLog: [InputActivityRecord] = []
    ) {
        self.isLocked = isLocked
        self.owner = owner
        self.previousAgent = previousAgent
        self.lastActivityMark = lastActivityMark
        self.activityLog = activityLog
    }
}

/// Central store for managing pane input locking, take-over / hand-back ownership
/// transitions, and automated keystroke attribution (C7, G2).
@MainActor
public final class InputOwnershipStore: ObservableObject {
    public static let shared = InputOwnershipStore()

    /// Maximum activity records kept per pane to keep memory bounded (G2).
    public static let maxLogEntriesPerPane = 100

    @Published private var states: [UUID: PaneInputState] = [:]

    public init() {}

    public func state(for paneId: UUID) -> PaneInputState {
        states[paneId] ?? PaneInputState()
    }

    public func isLocked(for paneId: UUID) -> Bool {
        states[paneId]?.isLocked ?? false
    }

    public func owner(for paneId: UUID) -> InputOwner {
        states[paneId]?.owner ?? .human
    }

    public func previousAgent(for paneId: UUID) -> String? {
        states[paneId]?.previousAgent
    }

    public func lastActivityMark(for paneId: UUID) -> InputActivityRecord? {
        states[paneId]?.lastActivityMark
    }

    public func activityLog(for paneId: UUID) -> [InputActivityRecord] {
        states[paneId]?.activityLog ?? []
    }

    /// Locks a pane against accidental keyboard typing (for watching agent execution).
    public func lock(paneId: UUID, by ownerName: String = "agent") {
        var current = state(for: paneId)
        current.isLocked = true
        current.owner = .agent(name: ownerName)
        states[paneId] = current
    }

    /// Unlocks a pane so the human user takes over interactive keyboard input.
    public func takeOver(paneId: UUID) {
        var current = state(for: paneId)
        current.isLocked = false
        if let agentName = current.owner.agentName {
            current.previousAgent = agentName
        } else if current.previousAgent == nil {
            current.previousAgent = "agent"
        }
        current.owner = .human
        states[paneId] = current
    }

    /// Hands back input ownership to the agent, re-locking the pane.
    public func handBack(paneId: UUID, to ownerName: String? = nil) {
        var current = state(for: paneId)
        let name = ownerName ?? current.previousAgent ?? current.owner.agentName ?? "agent"
        current.isLocked = true
        current.owner = .agent(name: name)
        states[paneId] = current
    }

    /// Explicitly unlocks a pane.
    public func unlock(paneId: UUID) {
        var current = state(for: paneId)
        current.isLocked = false
        current.owner = .human
        current.previousAgent = nil
        states[paneId] = current
    }

    /// Records an automated action from a client script or agent (takoctl send, type, key).
    public func recordAutomation(paneId: UUID, client: String, action: String) {
        var current = state(for: paneId)
        let record = InputActivityRecord(client: client, action: action, timestamp: Date())
        current.lastActivityMark = record
        current.activityLog.append(record)
        if current.activityLog.count > Self.maxLogEntriesPerPane {
            current.activityLog.removeFirst(current.activityLog.count - Self.maxLogEntriesPerPane)
        }
        states[paneId] = current
    }

    /// Clears any transient activity mark for a pane.
    public func clearActivityMark(paneId: UUID) {
        guard var current = states[paneId] else { return }
        current.lastActivityMark = nil
        states[paneId] = current
    }

    /// Cleans up tracking when a pane closes.
    public func remove(paneId: UUID) {
        states.removeValue(forKey: paneId)
    }

    public func removeAll(except kept: Set<UUID>) {
        states = states.filter { kept.contains($0.key) }
    }
}
