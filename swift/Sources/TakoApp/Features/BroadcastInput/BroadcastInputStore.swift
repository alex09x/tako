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

/// Active multi-pane broadcast session (C8).
public struct BroadcastSession: Equatable, Sendable {
    public var id: UUID
    public var selectedPaneIds: Set<UUID>
    public var leaderPaneId: UUID?
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        selectedPaneIds: Set<UUID>,
        leaderPaneId: UUID? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.selectedPaneIds = selectedPaneIds
        self.leaderPaneId = leaderPaneId
        self.startedAt = startedAt
    }
}

/// Central store for managing broadcast keyboard input across selected panes (C8).
///
/// Broadcast input is off by default, explicit per selection, and ends automatically
/// when the selection changes or drops below 2 panes. Secure input panes never
/// receive broadcast text.
@MainActor
public final class BroadcastInputStore: ObservableObject {
    public static let shared = BroadcastInputStore()

    @Published public private(set) var activeSession: BroadcastSession?

    public init() {}

    /// Whether broadcast input is currently active.
    public var isBroadcasting: Bool {
        activeSession != nil
    }

    /// Whether a specific pane is part of the active broadcast session.
    public func isParticipating(paneId: UUID) -> Bool {
        activeSession?.selectedPaneIds.contains(paneId) ?? false
    }

    /// Whether a specific pane is the leader (source of typing) in the broadcast session.
    public func isLeader(paneId: UUID) -> Bool {
        activeSession?.leaderPaneId == paneId
    }

    /// Starts a broadcast session across the given panes, with an optional leader pane.
    /// Broadcast requires at least 2 panes.
    @discardableResult
    public func startBroadcast(panes: Set<UUID>, leader: UUID? = nil) -> Bool {
        guard panes.count >= 2 else {
            endBroadcast()
            return false
        }
        let resolvedLeader = (leader != nil && panes.contains(leader!)) ? leader : panes.first
        activeSession = BroadcastSession(selectedPaneIds: panes, leaderPaneId: resolvedLeader)
        return true
    }

    /// Ends the active broadcast session.
    public func endBroadcast() {
        activeSession = nil
    }

    /// Sets or updates the active leader pane (when user clicks/focuses a different pane in the broadcast set).
    public func setLeader(paneId: UUID) {
        guard var session = activeSession, session.selectedPaneIds.contains(paneId) else { return }
        session.leaderPaneId = paneId
        activeSession = session
    }

    /// Updates the selection of panes. Broadcast automatically terminates if the selection
    /// drops below 2 panes ("it ends with the selection").
    public func updateSelection(panes: Set<UUID>) {
        guard let session = activeSession else { return }
        let intersection = session.selectedPaneIds.intersection(panes)
        if intersection.count < 2 {
            endBroadcast()
        } else if intersection != session.selectedPaneIds {
            var updated = session
            updated.selectedPaneIds = intersection
            if let leader = updated.leaderPaneId, !intersection.contains(leader) {
                updated.leaderPaneId = intersection.first
            }
            activeSession = updated
        }
    }

    /// Called when a pane is closed or removed.
    public func paneClosed(_ paneId: UUID) {
        guard var session = activeSession, session.selectedPaneIds.contains(paneId) else { return }
        session.selectedPaneIds.remove(paneId)
        if session.selectedPaneIds.count < 2 {
            endBroadcast()
        } else {
            if session.leaderPaneId == paneId {
                session.leaderPaneId = session.selectedPaneIds.first
            }
            activeSession = session
        }
    }

    /// Broadcasts raw terminal input bytes from the source surface to other participating panes.
    /// Secure-input panes never receive broadcast text, and a secure source never broadcasts out.
    public func broadcastInput(
        from source: AnyObject,
        sourceId: UUID,
        data: Data,
        lookup: (UUID) -> (target: AnyObject, isLocked: Bool, write: ([UInt8]) -> Void)?
    ) {
        guard let session = activeSession, session.selectedPaneIds.contains(sourceId) else { return }

        // Security check: if the source pane is in secure input mode (e.g. typing a password),
        // NEVER broadcast its keystrokes to other panes!
        guard !SecureInput.shared.isSecure(for: source) else { return }

        let bytes = [UInt8](data)
        for targetId in session.selectedPaneIds where targetId != sourceId {
            guard let (targetObj, isLocked, write) = lookup(targetId) else { continue }
            // Security check: secure-input panes never receive broadcast text!
            guard !SecureInput.shared.isSecure(for: targetObj) else { continue }
            // Respect input lock: if a pane is locked (e.g. by an agent), don't inject human keystrokes
            guard !isLocked else { continue }

            write(bytes)
        }
    }

    /// Broadcasts text (e.g. paste) from the source surface to other participating panes.
    public func broadcastText(
        from source: AnyObject,
        sourceId: UUID,
        text: String,
        lookup: (UUID) -> (target: AnyObject, isLocked: Bool, insertText: (String) -> Void)?
    ) {
        guard let session = activeSession, session.selectedPaneIds.contains(sourceId) else { return }

        guard !SecureInput.shared.isSecure(for: source) else { return }

        for targetId in session.selectedPaneIds where targetId != sourceId {
            guard let (targetObj, isLocked, insertText) = lookup(targetId) else { continue }
            guard !SecureInput.shared.isSecure(for: targetObj) else { continue }
            guard !isLocked else { continue }

            insertText(text)
        }
    }
}
