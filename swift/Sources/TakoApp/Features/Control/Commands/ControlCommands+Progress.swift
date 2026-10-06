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
    /// `takoctl progress`: get, set, or clear progress bar on a pane.
    static func progressCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "progress")
        let action: String = try {
            if let a = request.args["action"] {
                if case .string(let s) = a { return s.lowercased() }
                throw ControlError(.invalid, "\"action\" must be a string")
            }
            if let s = request.args["state"] {
                if case .string(let str) = s { return str.lowercased() }
            }
            return "get"
        }()

        let parsedNumber: UInt8? = {
            if let num = UInt8(action), (0...100).contains(num) {
                return num
            }
            if let v = request.args["value"] ?? request.args["progress"] {
                if case .number(let n) = v, n >= 0, n <= 100 { return UInt8(n) }
            }
            return nil
        }()

        let effectiveAction = parsedNumber != nil && action != "error" && action != "pause" && action != "paused" ? "set" : action

        switch effectiveAction {
        case "get":
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "state": .string(surface.crab.progressState.rawValue),
            ]
            if let p = surface.crab.progress {
                dict["progress"] = .number(Double(p))
            }
            return dict

        case "set", "normal":
            let val = parsedNumber
            surface.crab.progressReported(state: 1, value: val)
            surface.progressReport = .init(state: .set, progress: val)
            surface.updateProgressBar(state: surface.crab.progressState, progress: surface.crab.progress)
            (NSApp.delegate as? AppDelegate)?.setDockBadge()
            Tako.TabBarController.refreshAll()
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "state": .string(surface.crab.progressState.rawValue),
            ]
            if let p = surface.crab.progress { dict["progress"] = .number(Double(p)) }
            return dict

        case "error":
            let val = parsedNumber
            surface.crab.progressReported(state: 2, value: val)
            surface.progressReport = .init(state: .error, progress: val)
            surface.updateProgressBar(state: surface.crab.progressState, progress: surface.crab.progress)
            (NSApp.delegate as? AppDelegate)?.setDockBadge()
            Tako.TabBarController.refreshAll()
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "state": .string(surface.crab.progressState.rawValue),
            ]
            if let p = surface.crab.progress { dict["progress"] = .number(Double(p)) }
            return dict

        case "indeterminate":
            surface.crab.progressReported(state: 3, value: nil)
            surface.progressReport = .init(state: .indeterminate, progress: nil)
            surface.updateProgressBar(state: surface.crab.progressState, progress: nil)
            (NSApp.delegate as? AppDelegate)?.setDockBadge()
            Tako.TabBarController.refreshAll()
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "state": .string("indeterminate"),
            ]

        case "pause", "paused":
            let val = parsedNumber
            surface.crab.progressReported(state: 4, value: val)
            surface.progressReport = .init(state: .pause, progress: val)
            surface.updateProgressBar(state: surface.crab.progressState, progress: surface.crab.progress)
            (NSApp.delegate as? AppDelegate)?.setDockBadge()
            Tako.TabBarController.refreshAll()
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "state": .string(surface.crab.progressState.rawValue),
            ]
            if let p = surface.crab.progress { dict["progress"] = .number(Double(p)) }
            return dict

        case "clear", "none", "reset":
            surface.progressReport = nil
            surface.crab.progressReported(state: 0, value: nil)
            surface.updateProgressBar(state: .none, progress: nil)
            (NSApp.delegate as? AppDelegate)?.setDockBadge()
            Tako.TabBarController.refreshAll()
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "state": .string("none"),
            ]

        default:
            throw ControlError(.invalid, "unknown progress action \"\(action)\"")
        }
    }
}
