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
    /// `takoctl activity`: inspect and export automated activity log on panes (G2).
    static func activityCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        guard !SecureInput.shared.isSecure(for: surface) && !surface.isSecureInput else {
            throw ControlError(.disabled, "secure-input panes cannot be read")
        }
        let act = request.args["action"]?.string ?? request.args["subcommand"]?.string ?? "get"
        switch act {
        case "get", "list":
            recordActivity(for: request, on: surface.id, action: "activity")
            let records = InputOwnershipStore.shared.activityLog(for: surface.id)
            let entries: [JSON] = records.map { record in
                .object([
                    "client": .string(record.client),
                    "action": .string(record.action),
                    "timestamp": .string(ISO8601DateFormatter().string(from: record.timestamp))
                ])
            }
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "count": .number(Double(entries.count)),
                "entries": .array(entries)
            ]
            if let lastCleared = InputOwnershipStore.shared.lastCleared(for: surface.id) {
                dict["last_cleared"] = .object([
                    "client": .string(lastCleared.client),
                    "action": .string(lastCleared.action),
                    "timestamp": .string(ISO8601DateFormatter().string(from: lastCleared.timestamp))
                ])
            }
            if let exportPath = request.args["export"]?.string ?? request.args["file"]?.string {
                let jsonString = InputOwnershipStore.shared.exportLog(for: surface.id)
                let expanded = (exportPath as NSString).expandingTildeInPath
                try jsonString.write(toFile: expanded, atomically: true, encoding: .utf8)
                dict["exported"] = .string(expanded)
            }
            return dict
        case "clear":
            let client = request.client ?? "control"
            InputOwnershipStore.shared.clearLog(paneId: surface.id, by: client)
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "cleared": .bool(true)
            ]
            if let lastCleared = InputOwnershipStore.shared.lastCleared(for: surface.id) {
                dict["last_cleared"] = .object([
                    "client": .string(lastCleared.client),
                    "action": .string(lastCleared.action),
                    "timestamp": .string(ISO8601DateFormatter().string(from: lastCleared.timestamp))
                ])
            }
            return dict
        case "export":
            let jsonString = InputOwnershipStore.shared.exportLog(for: surface.id)
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "json": .string(jsonString)
            ]
            if let exportPath = request.args["export"]?.string ?? request.args["file"]?.string ?? request.args["path"]?.string {
                let expanded = (exportPath as NSString).expandingTildeInPath
                try jsonString.write(toFile: expanded, atomically: true, encoding: .utf8)
                dict["exported"] = .string(expanded)
            }
            return dict
        default:
            throw ControlError(.invalid, "unknown activity action \"\(act)\"; use get, export, or clear")
        }
    }
}
