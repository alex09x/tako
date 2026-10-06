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

/// Capability scopes for socket clients (Track G1).
enum ControlScope: String, CaseIterable, Sendable, Codable {
    case read
    case input
    case layout
    case signal
    case overlay
    case approval

    /// The scopes required to run a given command with specific args.
    /// Returns an empty set for unscoped discovery commands (e.g. `version`).
    static func required(for cmd: String, args: [String: JSON] = [:]) -> Set<ControlScope> {
        switch cmd {
        case "version":
            return []
        case "tree", "text", "last", "find", "events", "screenshot", "history", "diagnose":
            return [.read]
        case "activity":
            let act = args["action"]?.string ?? args["subcommand"]?.string ?? "get"
            if act == "clear" {
                return [.approval]
            }
            return [.read]
        case "send", "type", "key", "broadcast":
            return [.input]
        case "input":
            let sub = args["subcommand"]?.string ?? ""
            if sub == "log" || sub == "status" {
                return [.read]
            }
            if sub == "allow-automation" || sub == "enable-automation" ||
               sub == "disallow-automation" || sub == "disable-automation" ||
               sub == "confirm-automation" {
                return [.approval]
            }
            return [.input]
        case "grant":
            let sub = args["subcommand"]?.string ?? ""
            if sub == "request" {
                return []
            }
            return [.approval]
        case "run":
            return [.layout, .input]
        case "tab-new", "split":
            if args["argv"] != nil {
                return [.layout, .input]
            }
            return [.layout]
        case "close", "focus", "collapse", "expand",
             "workspace", "layout", "action", "task", "session", "wait", "resume":
            return [.layout]
        case "notify", "status", "progress", "ask", "title", "triggers":
            return [.signal]
        case "dialog", "overlay":
            return [.overlay]
        case "review":
            let sub = args["subcommand"]?.string ?? ""
            if sub == "send" {
                return [.input]
            }
            return [.read]
        default:
            return []
        }
    }

    /// Parses scopes from a JSON string, comma-separated string, or array of strings.
    static func parseScopes(from raw: JSON?) throws -> Set<ControlScope>? {
        guard let raw else { return nil }
        switch raw {
        case .null:
            return nil
        case .array(let arr):
            var parsedScopes: Set<ControlScope> = []
            for item in arr {
                guard case .string(let s) = item else {
                    throw ControlError(.invalid, "item in \"scopes\" must be a string")
                }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.isEmpty { continue }
                guard let scope = ControlScope(rawValue: trimmed) else {
                    throw ControlError(.invalid, "unknown scope '\(s)'; valid scopes are \(ControlScope.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                parsedScopes.insert(scope)
            }
            return parsedScopes
        case .string(let s):
            var parsedScopes: Set<ControlScope> = []
            for part in s.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.isEmpty { continue }
                guard let scope = ControlScope(rawValue: trimmed) else {
                    throw ControlError(.invalid, "unknown scope '\(trimmed)'; valid scopes are \(ControlScope.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                parsedScopes.insert(scope)
            }
            return parsedScopes
        default:
            throw ControlError(.invalid, "\"scopes\" must be an array of strings or comma-separated string")
        }
    }
}
