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
    /// Handles `triggers` control command: list, add, remove, and clear passive regex triggers (E7).
    /// Strictly passive: rules can highlight output text or trigger notifications; never injects keystrokes.
    static func triggersCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let sub = request.args["subcommand"]?.string ?? "list"
        switch sub {
        case "list":
            let triggers = PassiveTriggerStore.shared.allTriggers
            let listJson: [JSON] = triggers.map { trigger in
                var obj: [String: JSON] = [
                    "id": .string(trigger.id.uuidString.lowercased()),
                    "pattern": .string(trigger.pattern),
                    "action": .string(trigger.action.rawValue),
                    "style": .string(trigger.style.rawValue),
                    "only_unfocused": .bool(trigger.onlyUnfocused),
                    "is_dynamic": .bool(trigger.isDynamic),
                ]
                if let colorName = trigger.colorName {
                    obj["color"] = .string(colorName)
                }
                if let title = trigger.notificationTitle {
                    obj["title"] = .string(title)
                }
                return .object(obj)
            }
            return ["triggers": .array(listJson)]

        case "add":
            guard let pattern = request.args["pattern"]?.string, !pattern.isEmpty else {
                throw ControlError(.invalid, "missing or empty \"pattern\" argument")
            }
            // Validate regex syntax
            guard (try? NSRegularExpression(pattern: pattern, options: [])) != nil else {
                throw ControlError(.invalid, "invalid regular expression pattern: \(pattern)")
            }
            let actionStr = request.args["action"]?.string ?? "highlight"
            guard let action = TerminalRegexTrigger.Action(rawValue: actionStr.lowercased()) else {
                throw ControlError(.invalid, "invalid action: \(actionStr); expected highlight, notify, or both")
            }
            let colorName = request.args["color"]?.string ?? "yellow"
            let styleStr = request.args["style"]?.string ?? "background"
            guard let style = TerminalRegexTrigger.HighlightStyle(rawValue: styleStr.lowercased()) else {
                throw ControlError(.invalid, "invalid style: \(styleStr); expected background, underline, box, or bold")
            }
            let title = request.args["title"]?.string
            let onlyUnfocused = request.args["only_unfocused"]?.bool ?? (request.args["all_focus"]?.bool == true ? false : true)

            let safety = TerminalRegexTrigger.isSafePattern(pattern)
            guard safety.isSafe else {
                throw ControlError(.invalid, "unsafe regex pattern: \(safety.reason ?? "catastrophic backtracking risk")")
            }
            guard let trigger = TerminalRegexTrigger(
                pattern: pattern,
                action: action,
                colorName: colorName,
                style: style,
                notificationTitle: title,
                onlyUnfocused: onlyUnfocused,
                isDynamic: true
            ) else {
                throw ControlError(.invalid, "invalid regex pattern: \(pattern)")
            }
            PassiveTriggerStore.shared.addDynamicTrigger(trigger)
            all.forEach { $0.surface.updateActiveRegexTriggers() }

            var res: [String: JSON] = [
                "id": .string(trigger.id.uuidString.lowercased()),
                "pattern": .string(trigger.pattern),
                "action": .string(trigger.action.rawValue),
                "color": .string(colorName),
                "style": .string(trigger.style.rawValue),
                "only_unfocused": .bool(trigger.onlyUnfocused),
                "is_dynamic": .bool(true),
            ]
            if let title {
                res["title"] = .string(title)
            }
            return res

        case "remove", "rm", "delete":
            guard let idStr = request.args["id"]?.string, let id = UUID(uuidString: idStr) else {
                throw ControlError(.invalid, "missing or invalid \"id\" argument")
            }
            PassiveTriggerStore.shared.removeTrigger(id: id)
            all.forEach { $0.surface.updateActiveRegexTriggers() }
            return ["removed": .string(id.uuidString.lowercased())]

        case "clear", "reset":
            PassiveTriggerStore.shared.clearDynamicTriggers()
            all.forEach { $0.surface.updateActiveRegexTriggers() }
            return ["cleared": .bool(true)]

        default:
            throw ControlError(.invalid, "unknown triggers subcommand: \(sub); expected list, add, remove, or clear")
        }
    }
}
