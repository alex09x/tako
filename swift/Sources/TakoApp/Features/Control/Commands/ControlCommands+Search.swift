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
    /// command that printed each match where the shell marked one.
    /// `limit` for find: a whole number from 1 to the panel's own limit.
    static func findLimit(_ args: [String: JSON]) throws -> Int {
        let refused = ControlError(.invalid, "\"limit\" must be a whole number from 1 to \(CrossSessionSearch.limit)")
        switch args["limit"] {
        case nil, .null?: return 50
        case .number(let n)?:
            guard n.isFinite, let limit = Int(exactly: n), (1...CrossSessionSearch.limit).contains(limit) else {
                throw refused
            }
            return limit
        default:
            throw refused
        }
    }

    /// `takoctl history`: the cross-session command history search.
    /// `limit` for history: a whole number from 0 to 5000 (default 100).
    static func historyLimit(_ args: [String: JSON]) throws -> Int {
        let refused = ControlError(.invalid, "\"limit\" must be a whole number from 0 to 5000")
        switch args["limit"] {
        case nil, .null?: return 100
        case .number(let n)?:
            guard n.isFinite, let limit = Int(exactly: n), (0...5000).contains(limit) else {
                throw refused
            }
            return limit
        default:
            throw refused
        }
    }

    static func find(_ needle: String, limit cap: Int, reply: @escaping @Sendable (ControlResponse) -> Void) {
        guard !needle.isEmpty else { return reply(.failure(ControlError(.invalid, "nothing to find"))) }
        let targets = CrossSessionSearch.openTerminals()
        Task.detached(priority: .userInitiated) {
            guard let found = await CrossSessionSearch.search(needle, in: targets) else {
                return reply(.failure(ControlError(.internalError, "search cancelled")))
            }
            let matches: [JSON] = found.results.prefix(cap).map { result in
                var match: [String: JSON] = [
                    "id": .string(result.surfaceID.uuidString.lowercased()),
                    "place": .string(result.place),
                    "pane": result.pane.map(JSON.string) ?? .null,
                    "line": .string(result.hit.before + result.hit.matched + result.hit.after),
                    "matched": .string(result.hit.matched),
                ]
                if let heading = result.command {
                    match["command"] = .object([
                        "input": heading.commandLine.map(JSON.string) ?? .null,
                        "status": .string(heading.outcomeText),
                        "cwd": heading.directory.map(JSON.string) ?? .null,
                    ])
                }
                return .object(match)
            }
            reply(.ok(["matches": .array(matches), "more": .bool(found.more || found.results.count > cap)]))
        }
    }

    /// `takoctl history`: the cross-session command history search.
    static func historyCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let query = request.args["query"]?.string ?? ""
        let limit = try historyLimit(request.args)
        let entries = CommandHistoryStore.shared.search(query: query, limit: limit).filter { entry in
            guard let paneId = entry.paneId else { return true }
            if let found = all.first(where: { $0.surface.id == paneId }) {
                return !SecureInput.shared.isSecure(for: found.surface) && !found.surface.isSecureInput
            }
            return true
        }
        let jsonEntries = entries.map { entry -> JSON in
            var obj: [String: JSON] = [
                "id": .string(entry.id.uuidString.lowercased()),
                "command": .string(entry.command),
                "started_at": .number(entry.startedAt.timeIntervalSince1970),
            ]
            if let cwd = entry.cwd { obj["cwd"] = .string(cwd) }
            if let dur = entry.duration {
                obj["duration"] = .number(dur)
                obj["duration_ms"] = .number((dur * 1000.0).rounded())
            }
            if let exitCode = entry.exitCode {
                obj["exit_code"] = .number(Double(exitCode))
            }
            if let paneId = entry.paneId {
                obj["pane_id"] = .string(paneId.uuidString.lowercased())
            }
            return .object(obj)
        }
        return ["entries": .array(jsonEntries)]
    }
}
