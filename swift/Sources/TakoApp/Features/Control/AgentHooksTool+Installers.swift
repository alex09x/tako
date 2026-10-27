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

extension AgentHooksTool {
    @discardableResult
    static func installAntigravityHooks(baseDir: String? = nil) -> Bool {
        let fm = FileManager.default
        let home = resolvedBaseDir(baseDir) ?? fm.homeDirectoryForCurrentUser.path
        let configDir = (home as NSString).appendingPathComponent(".gemini/config")
        let hooksPath = (configDir as NSString).appendingPathComponent("hooks.json")

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: hooksPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            root = json
        }

        var takoStatus: [String: Any] = ["enabled": true]
        if let existingTakoRaw = root["tako-status"] {
            guard let existingDict = existingTakoRaw as? [String: Any] else {
                return false
            }
            // Respect deliberate disabled configuration: do not silently re-enable
            if (existingDict["enabled"] as? Bool) == false {
                return false
            }
            takoStatus = existingDict
        }

        if hasDisabledDirectHook(in: takoStatus["PreInvocation"], commandKey: "takoctl status set working") ||
           hasDisabledDirectHook(in: takoStatus["Stop"], commandKey: "takoctl status") {
            return false
        }

        let preHook: [String: Any] = [
            "type": "command",
            "timeout": 5,
            "command": preferredCommand(agent: "agy", event: "pre_invocation", fallback: "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set working --target \"$TAKO_SURFACE_ID\" --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1; fi; echo \"{}\"")
        ]
        guard let mergedPre = mergeDirectHook(in: takoStatus["PreInvocation"], adding: preHook, commandKey: "takoctl status set working") else {
            return false
        }
        takoStatus["PreInvocation"] = mergedPre

        let stopHook: [String: Any] = [
            "type": "command",
            "timeout": 5,
            "command": preferredCommand(agent: "agy", event: "stop", fallback: "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set done --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1; takoctl progress clear --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1; fi; echo \"{}\"")
        ]
        guard let mergedStop = mergeDirectHook(in: takoStatus["Stop"], adding: stopHook, commandKey: "takoctl status set done") else {
            return false
        }
        takoStatus["Stop"] = mergedStop

        root["tako-status"] = takoStatus

        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? outData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)) != nil
    }

    @discardableResult
    static func installGeminiHooks(baseDir: String? = nil) -> Bool {
        let fm = FileManager.default
        let home = resolvedBaseDir(baseDir) ?? fm.homeDirectoryForCurrentUser.path
        let geminiDir = (home as NSString).appendingPathComponent(".gemini")
        let settingsPath = (geminiDir as NSString).appendingPathComponent("settings.json")

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            root = json
        }

        var hooks: [String: Any] = [:]
        if let existingHooksRaw = root["hooks"] {
            guard let existingHooks = existingHooksRaw as? [String: Any] else {
                return false
            }
            hooks = existingHooks
        }

        if hasDisabledMatcherHook(in: hooks["BeforeAgent"], commandKey: "takoctl status set working") ||
           hasDisabledMatcherHook(in: hooks["AfterAgent"], commandKey: "takoctl status set idle") {
            return false
        }

        let beforeGroup: [String: Any] = [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi",
                    "timeout": 5
                ]
            ]
        ]
        guard let mergedBefore = mergeMatcherGroup(in: hooks["BeforeAgent"], adding: beforeGroup, commandKey: "takoctl status set working") else {
            return false
        }
        hooks["BeforeAgent"] = mergedBefore

        let afterGroup: [String: Any] = [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi",
                    "timeout": 5
                ]
            ]
        ]
        guard let mergedAfter = mergeMatcherGroup(in: hooks["AfterAgent"], adding: afterGroup, commandKey: "takoctl status set idle") else {
            return false
        }
        hooks["AfterAgent"] = mergedAfter

        root["hooks"] = hooks

        try? fm.createDirectory(atPath: geminiDir, withIntermediateDirectories: true)
        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? outData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)) != nil
    }

    private static let preamble = ""
    private static func preferredCommand(agent: String, event: String, fallback: String) -> String {
        "if command -v tako-hook >/dev/null 2>&1; then tako-hook \(agent) \(event); else \(fallback); fi; :"
    }
    private static let workingHookCmd = preamble + "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set working --target \"$TAKO_SURFACE_ID\" --text \"Thinking...\" >/dev/null 2>&1 || true; takoctl progress indeterminate --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1 || true; fi; :"
    private static let doneHookCmd = preamble + "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set done --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1 || true; takoctl progress clear --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1 || true; fi; :"
    private static let idleHookCmd = preamble + "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set idle --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1 || true; takoctl progress clear --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1 || true; fi; :"
    private static let needsApprovalHookCmd = preamble + "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set needs_approval --target \"$TAKO_SURFACE_ID\" --text \"Approval requested\" >/dev/null 2>&1 || true; takoctl progress pause --target \"$TAKO_SURFACE_ID\" >/dev/null 2>&1 || true; fi; :"
    private static let questionHookCmd = preamble + "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set waiting_for_input --target \"$TAKO_SURFACE_ID\" --text \"Question\" >/dev/null 2>&1 || true; fi; :"


    @discardableResult
    static func installClaudeHooks(baseDir: String? = nil) -> Bool {
        let fm = FileManager.default
        let home = resolvedBaseDir(baseDir) ?? fm.homeDirectoryForCurrentUser.path
        let claudeDir = (home as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.json")

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            root = json
        }

        var hooks: [String: Any] = [:]
        if let existingHooksRaw = root["hooks"] {
            guard let existingHooks = existingHooksRaw as? [String: Any] else {
                return false
            }
            hooks = existingHooks
        }

        if hasDisabledMatcherHook(in: hooks["UserPromptSubmit"], commandKey: "takoctl status set working") ||
           hasDisabledMatcherHook(in: hooks["Stop"], commandKey: "takoctl status") {
            return false
        }

        let promptGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "claude", event: "user_prompt_submit", fallback: workingHookCmd), "timeout": 5]]
        ]
        guard let mergedPrompt = mergeMatcherGroup(in: hooks["UserPromptSubmit"], adding: promptGroup, commandKey: "takoctl status set working", replacePattern: "takoctl status") else {
            return false
        }
        hooks["UserPromptSubmit"] = mergedPrompt

        let stopGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "claude", event: "stop", fallback: doneHookCmd), "timeout": 5]]
        ]
        guard let mergedStop = mergeMatcherGroup(in: hooks["Stop"], adding: stopGroup, commandKey: "takoctl status set done", replacePattern: "takoctl status") else {
            return false
        }
        hooks["Stop"] = mergedStop

        let permGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "claude", event: "permission_request", fallback: needsApprovalHookCmd), "timeout": 5]]
        ]
        if let mergedPerm = mergeMatcherGroup(in: hooks["PermissionRequest"], adding: permGroup, commandKey: "takoctl status set needs_approval", replacePattern: "takoctl status") {
            hooks["PermissionRequest"] = mergedPerm
        }

        let elicitationGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "claude", event: "question", fallback: questionHookCmd), "timeout": 5]]
        ]
        if let mergedElicitation = mergeMatcherGroup(in: hooks["Elicitation"], adding: elicitationGroup, commandKey: "takoctl status set waiting_for_input", replacePattern: "takoctl status") {
            hooks["Elicitation"] = mergedElicitation
        }

        let answeredGroup: [String: Any] = ["matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": preferredCommand(agent: "claude", event: "question_answered", fallback: workingHookCmd), "timeout": 5]]]
        if hasDisabledMatcherHook(in: hooks["PostToolUse"], commandKey: "takoctl status set working") { return false }
        guard let answered = mergeMatcherGroup(in: hooks["PostToolUse"], adding: answeredGroup,
                                              commandKey: "takoctl status set working") else { return false }
        hooks["PostToolUse"] = answered

        root["hooks"] = hooks

        try? fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? outData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)) != nil
    }

    @discardableResult
    static func installCodexHooks(baseDir: String? = nil) -> Bool {
        let fm = FileManager.default
        let effectiveBase = resolvedBaseDir(baseDir)
        let home = effectiveBase ?? fm.homeDirectoryForCurrentUser.path
        let codexDir: String
        if effectiveBase == nil, let envCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envCodexHome.isEmpty {
            codexDir = envCodexHome
        } else {
            codexDir = (home as NSString).appendingPathComponent(".codex")
        }
        let hooksPath = (codexDir as NSString).appendingPathComponent("hooks.json")

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: hooksPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            root = json
        }

        var hooks: [String: Any] = [:]
        if let existingHooksRaw = root["hooks"] {
            guard let existingHooks = existingHooksRaw as? [String: Any] else {
                return false
            }
            hooks = existingHooks
        }

        if hasDisabledMatcherHook(in: hooks["UserPromptSubmit"], commandKey: "takoctl status set working") ||
           hasDisabledMatcherHook(in: hooks["Stop"], commandKey: "takoctl status") {
            return false
        }

        let promptGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "codex", event: "user_prompt_submit", fallback: workingHookCmd), "timeout": 5]]
        ]
        guard let mergedPrompt = mergeMatcherGroup(in: hooks["UserPromptSubmit"], adding: promptGroup, commandKey: "takoctl status set working", replacePattern: "takoctl status") else {
            return false
        }
        hooks["UserPromptSubmit"] = mergedPrompt

        let stopGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "codex", event: "stop", fallback: doneHookCmd), "timeout": 5]]
        ]
        guard let mergedStop = mergeMatcherGroup(in: hooks["Stop"], adding: stopGroup, commandKey: "takoctl status set done", replacePattern: "takoctl status") else {
            return false
        }
        hooks["Stop"] = mergedStop

        // Esc or Ctrl+C fires Interrupt and no Stop: it is what ends the turn.
        let interruptGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "codex", event: "interrupt", fallback: idleHookCmd), "timeout": 5]]
        ]
        guard let mergedInterrupt = mergeMatcherGroup(in: hooks["Interrupt"], adding: interruptGroup, commandKey: "takoctl status set idle", replacePattern: "takoctl status") else {
            return false
        }
        hooks["Interrupt"] = mergedInterrupt

        let permGroup: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": preferredCommand(agent: "codex", event: "permission_request", fallback: needsApprovalHookCmd), "timeout": 5]]
        ]
        if let mergedPerm = mergeMatcherGroup(in: hooks["PermissionRequest"], adding: permGroup, commandKey: "takoctl status set needs_approval", replacePattern: "takoctl status") {
            hooks["PermissionRequest"] = mergedPerm
        }

        let questionGroup: [String: Any] = [
            "matcher": "request_user_input",
            "hooks": [["type": "command", "command": preferredCommand(agent: "codex", event: "question", fallback: questionHookCmd), "timeout": 5]]
        ]
        if let mergedQuestion = mergeMatcherGroup(in: hooks["PreToolUse"], adding: questionGroup, commandKey: "takoctl status set waiting_for_input", replacePattern: "takoctl status") {
            hooks["PreToolUse"] = mergedQuestion
        }

        let resumeGroup: [String: Any] = [
            "matcher": "request_user_input",
            "hooks": [["type": "command", "command": preferredCommand(agent: "codex", event: "question_answered", fallback: workingHookCmd), "timeout": 5]]
        ]
        if let mergedResume = mergeMatcherGroup(in: hooks["PostToolUse"], adding: resumeGroup, commandKey: "takoctl status set working", replacePattern: "takoctl status") {
            hooks["PostToolUse"] = mergedResume
        }

        root["hooks"] = hooks

        try? fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? outData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)) != nil
    }
}
