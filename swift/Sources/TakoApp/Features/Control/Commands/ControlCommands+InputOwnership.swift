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
import AppKit

extension ControlCommands {
    /// `takoctl input`: lock, unlock, takeover, handback, and inspect input ownership (C7).
    static func inputOwnershipCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "input")
        let sub = try ControlInput.text(request.args, "subcommand")
        switch sub {
        case "lock":
            let ownerName = request.args["owner"]?.string ?? "agent"
            InputOwnershipStore.shared.lock(paneId: surface.id, by: ownerName)
            let state = InputOwnershipStore.shared.state(for: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "locked": .bool(state.isLocked),
                "owner": .string(state.owner.agentName ?? "agent")
            ]
        case "unlock":
            InputOwnershipStore.shared.unlock(paneId: surface.id)
            let state = InputOwnershipStore.shared.state(for: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "locked": .bool(state.isLocked),
                "owner": .string("human")
            ]
        case "takeover":
            InputOwnershipStore.shared.takeOver(paneId: surface.id)
            let state = InputOwnershipStore.shared.state(for: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "locked": .bool(state.isLocked),
                "owner": .string("human")
            ]
        case "handback":
            let toName = request.args["owner"]?.string
            InputOwnershipStore.shared.handBack(paneId: surface.id, to: toName)
            let state = InputOwnershipStore.shared.state(for: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "locked": .bool(state.isLocked),
                "owner": .string(state.owner.agentName ?? "agent")
            ]
        case "allow-automation", "enable-automation", "allow-typing":
            InputOwnershipStore.shared.setAutomationMayType(paneId: surface.id, allowed: true)
            let state = InputOwnershipStore.shared.state(for: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "automation_may_type": .bool(state.automationMayType)
            ]
        case "disallow-automation", "disable-automation", "disallow-typing":
            InputOwnershipStore.shared.setAutomationMayType(paneId: surface.id, allowed: false)
            let state = InputOwnershipStore.shared.state(for: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "automation_may_type": .bool(state.automationMayType)
            ]
        case "confirm-automation", "confirm-typing":
            InputOwnershipStore.shared.confirmOneTimeTyping(paneId: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "confirmed": .bool(true)
            ]
        case "status":
            let state = InputOwnershipStore.shared.state(for: surface.id)
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "locked": .bool(state.isLocked),
                "owner": .string(state.owner.isAgent ? (state.owner.agentName ?? "agent") : "human"),
                "automation_may_type": .bool(state.automationMayType),
            ]
            if let creator = state.creatorClient {
                dict["creator_client"] = .string(creator)
            }
            if let mark = state.lastActivityMark {
                dict["last_client"] = .string(mark.client)
                dict["last_action"] = .string(mark.action)
            }
            return dict
        case "log":
            let state = InputOwnershipStore.shared.state(for: surface.id)
            let entries: [JSON] = state.activityLog.map { record in
                .object([
                    "client": .string(record.client),
                    "action": .string(record.action),
                    "timestamp": .string(ISO8601DateFormatter().string(from: record.timestamp))
                ])
            }
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "entries": .array(entries)
            ]
        default:
            throw ControlError(.invalid, "unknown input subcommand: \(sub)")
        }
    }

    /// `takoctl send` / `takoctl type`: send typed text into a pane, subject to input ownership.
    static func sendCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        let client = request.client ?? request.args["client"]?.string ?? "takoctl"
        guard InputOwnershipStore.shared.canClientType(paneId: surface.id, client: client) else {
            let state = InputOwnershipStore.shared.state(for: surface.id)
            let creatorDesc = state.creatorClient.map { "pane was created by client '\($0)'" } ?? "pane was created by user"
            throw ControlError(.automationNotPermitted, "automation is not permitted to type into pane \(surface.id.uuidString.lowercased()): \(creatorDesc) and 'automation may type here' is off")
        }
        let enter = request.cmd == "send" && request.args["enter"] != .bool(false)
        let text = try ControlInput.text(request.args)
        try ControlInput.send(surface, text: text, enter: enter)
        recordActivity(for: request, on: surface.id, action: request.cmd)
        return ["id": .string(surface.id.uuidString.lowercased())]
    }

    /// `takoctl key`: send a key chord into a pane, subject to input ownership.
    static func keyCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        let client = request.client ?? request.args["client"]?.string ?? "takoctl"
        guard InputOwnershipStore.shared.canClientType(paneId: surface.id, client: client) else {
            let state = InputOwnershipStore.shared.state(for: surface.id)
            let creatorDesc = state.creatorClient.map { "pane was created by client '\($0)'" } ?? "pane was created by user"
            throw ControlError(.automationNotPermitted, "automation is not permitted to type into pane \(surface.id.uuidString.lowercased()): \(creatorDesc) and 'automation may type here' is off")
        }
        let chord = try ControlInput.text(request.args, "key")
        try ControlInput.key(surface, chord: chord)
        recordActivity(for: request, on: surface.id, action: "key")
        return ["id": .string(surface.id.uuidString.lowercased())]
    }
}
