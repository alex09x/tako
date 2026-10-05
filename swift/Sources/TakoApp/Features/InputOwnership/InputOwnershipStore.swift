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

/// State tracking input ownership, lock status, activity marks, and automation typing permissions per pane (C7, G1, G2).
public struct PaneInputState: Equatable, Sendable {
    public var isLocked: Bool
    public var owner: InputOwner
    public var previousAgent: String?
    public var lastActivityMark: InputActivityRecord?
    public var activityLog: [InputActivityRecord]
    /// The client identity that created this pane, if created by an automated client (Track G1).
    public var creatorClient: String?
    /// Whether external automation is permitted to type into this pane ("automation may type here" switch, Track G1).
    public var automationMayType: Bool
    /// One-time permission to allow automation to type once into this pane without turning the permanent switch on (Track G1).
    public var oneTimeConfirmation: Bool

    public init(
        isLocked: Bool = false,
        owner: InputOwner = .human,
        previousAgent: String? = nil,
        lastActivityMark: InputActivityRecord? = nil,
        activityLog: [InputActivityRecord] = [],
        creatorClient: String? = nil,
        automationMayType: Bool = false,
        oneTimeConfirmation: Bool = false
    ) {
        self.isLocked = isLocked
        self.owner = owner
        self.previousAgent = previousAgent
        self.lastActivityMark = lastActivityMark
        self.activityLog = activityLog
        self.creatorClient = creatorClient
        self.automationMayType = automationMayType
        self.oneTimeConfirmation = oneTimeConfirmation
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

    public func creatorClient(for paneId: UUID) -> String? {
        states[paneId]?.creatorClient
    }

    public func setCreatorClient(paneId: UUID, client: String?) {
        guard let client, !client.isEmpty else { return }
        var current = state(for: paneId)
        current.creatorClient = client
        states[paneId] = current
    }

    public func automationMayType(for paneId: UUID) -> Bool {
        states[paneId]?.automationMayType ?? false
    }

    public func setAutomationMayType(paneId: UUID, allowed: Bool) {
        var current = state(for: paneId)
        current.automationMayType = allowed
        states[paneId] = current
    }

    public func confirmOneTimeTyping(paneId: UUID) {
        var current = state(for: paneId)
        current.oneTimeConfirmation = true
        states[paneId] = current
    }

    /// Whether a client may type into this pane (Track G1).
    /// Panes created by a client are writable by it; typing into a pane it did not create
    /// needs the "automation may type here" switch or a one-time confirmation.
    public func canClientType(paneId: UUID, client: String?) -> Bool {
        var current = state(for: paneId)
        if current.oneTimeConfirmation {
            current.oneTimeConfirmation = false
            states[paneId] = current
            return true
        }
        if current.automationMayType {
            return true
        }
        if let client, !client.isEmpty, let creator = current.creatorClient, creator == client {
            return true
        }
        return false
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
