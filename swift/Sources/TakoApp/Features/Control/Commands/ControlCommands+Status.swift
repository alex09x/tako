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
    /// `takoctl status`: get, set, or clear a pane's status indicator and text.
    static func statusCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "status")
        let action: String = try {
            if let a = request.args["action"] {
                if case .string(let s) = a { return s }
                throw ControlError(.invalid, "\"action\" must be a string")
            }
            return "get"
        }()
        switch action {
        case "get":
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "status": .string(surface.crab.paneStatus.rawValue),
                "unread": .bool(surface.crab.unread),
            ]
            if let text = surface.crab.statusText {
                dict["text"] = .string(text)
            }
            if let ttl = surface.crab.remainingTTL {
                dict["ttl"] = .number(ttl)
            }
            return dict
        case "set":
            let statusStr: String = try {
                guard let s = request.args["status"], case .string(let str) = s else {
                    throw ControlError(.invalid, "missing or invalid \"status\" argument")
                }
                return str
            }()
            guard let parsed = Tako.PaneStatus.parse(statusStr) else {
                throw ControlError(.invalid, "invalid status \"\(statusStr)\"")
            }
            let text: String? = {
                if let t = request.args["text"], case .string(let str) = t { return str }
                return nil
            }()
            let ttl: TimeInterval? = {
                if let ttlVal = request.args["ttl"] {
                    if case .number(let n) = ttlVal, n > 0 { return n }
                }
                return nil
            }()
            surface.setStatus(parsed.rawValue, text: text, ttl: ttl)
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "status": .string(surface.crab.paneStatus.rawValue),
                "unread": .bool(surface.crab.unread),
            ]
            if let t = surface.crab.statusText { dict["text"] = .string(t) }
            if let rem = surface.crab.remainingTTL { dict["ttl"] = .number(rem) }
            return dict
        case "clear":
            surface.clearStatus()
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "status": .string(surface.crab.paneStatus.rawValue),
                "unread": .bool(surface.crab.unread),
            ]
        default:
            throw ControlError(.invalid, "unknown status action \"\(action)\"")
        }
    }
}
