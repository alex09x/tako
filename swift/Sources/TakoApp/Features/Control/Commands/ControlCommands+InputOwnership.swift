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
    /// Records automated activity on a target pane.
    static func recordActivity(for request: ControlRequest, on paneId: UUID, action: String) {
        let client = request.client ?? request.args["client"]?.string ?? "anonymous"
        InputOwnershipStore.shared.recordAutomation(paneId: paneId, client: client, action: action)
    }
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
        case "status":
            let state = InputOwnershipStore.shared.state(for: surface.id)
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "locked": .bool(state.isLocked),
                "owner": .string(state.owner.isAgent ? (state.owner.agentName ?? "agent") : "human"),
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
        let enter = request.cmd == "send" && request.args["enter"] != .bool(false)
        let text = try ControlInput.text(request.args)
        try ControlInput.send(surface, text: text, enter: enter)
        recordActivity(for: request, on: surface.id, action: request.cmd)
        return ["id": .string(surface.id.uuidString.lowercased())]
    }

    /// `takoctl key`: send a key chord into a pane, subject to input ownership.
    static func keyCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        let chord = try ControlInput.text(request.args, "key")
        try ControlInput.key(surface, chord: chord)
        recordActivity(for: request, on: surface.id, action: "key")
        return ["id": .string(surface.id.uuidString.lowercased())]
    }
}
