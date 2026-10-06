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
    /// `takoctl broadcast`: start, stop, or query multi-pane synchronized broadcast input (C8).
    static func broadcastCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "broadcast")
        let sub = try? ControlInput.text(request.args, "subcommand")
        switch sub ?? "status" {
        case "start":
            var targetPanes: Set<UUID> = []
            if let panesArg = request.args["panes"]?.string {
                let tokens = panesArg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for token in tokens {
                    if let pane = all.first(where: {
                        $0.surface.id.uuidString.lowercased().hasPrefix(token.lowercased())
                    }) {
                        targetPanes.insert(pane.surface.id)
                    }
                }
            } else if request.args["all_splits"] == .bool(true) || request.args["panes"] == nil {
                if let currentPane = all.first(where: { $0.surface.id == surface.id }) {
                    let tabPanes = all.filter { $0.tabID == currentPane.tabID }
                    for p in tabPanes {
                        targetPanes.insert(p.surface.id)
                    }
                }
            }
            targetPanes.insert(surface.id)
            guard targetPanes.count >= 2 else {
                throw ControlError(.invalid, "broadcast requires at least 2 panes in selection")
            }
            let started = BroadcastInputStore.shared.startBroadcast(panes: targetPanes, leader: surface.id)
            let session = BroadcastInputStore.shared.activeSession
            let paneArray: [JSON] = (session?.selectedPaneIds ?? []).map { .string($0.uuidString.lowercased()) }
            return [
                "active": .bool(started),
                "leader": .string(surface.id.uuidString.lowercased()),
                "count": .number(Double(paneArray.count)),
                "panes": .array(paneArray)
            ]
        case "stop":
            BroadcastInputStore.shared.endBroadcast()
            return [
                "active": .bool(false)
            ]
        case "status":
            let session = BroadcastInputStore.shared.activeSession
            let active = session != nil
            let paneArray: [JSON] = (session?.selectedPaneIds ?? []).map { .string($0.uuidString.lowercased()) }
            var dict: [String: JSON] = [
                "active": .bool(active),
                "count": .number(Double(paneArray.count)),
                "panes": .array(paneArray)
            ]
            if let leader = session?.leaderPaneId {
                dict["leader"] = .string(leader.uuidString.lowercased())
            }
            return dict
        default:
            throw ControlError(.invalid, "unknown broadcast subcommand: \(sub ?? "")")
        }
    }
}
