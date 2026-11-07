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
    /// Antigravity reports status natively via `OSC 7501`; clean up any legacy owned status hooks.
    @discardableResult
    static func installAntigravityHooks(baseDir: String? = nil) -> Bool {
        cleanupLegacyStatusHooks(for: "antigravity", baseDir: baseDir)
    }

    /// Claude Code reports status natively via `OSC 7501`; clean up any legacy owned status hooks.
    @discardableResult
    static func installClaudeHooks(baseDir: String? = nil) -> Bool {
        cleanupLegacyStatusHooks(for: "claude", baseDir: baseDir)
    }

    /// Codex CLI reports status natively via `OSC 7501`; clean up any legacy owned status hooks.
    @discardableResult
    static func installCodexHooks(baseDir: String? = nil) -> Bool {
        cleanupLegacyStatusHooks(for: "codex", baseDir: baseDir)
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
        guard let mergedBefore = mergeMatcherGroup(
            in: hooks["BeforeAgent"],
            adding: beforeGroup,
            commandKey: "takoctl status set working",
            replacePattern: "takoctl status"
        ) else {
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
        guard let mergedAfter = mergeMatcherGroup(
            in: hooks["AfterAgent"],
            adding: afterGroup,
            commandKey: "takoctl status set idle",
            replacePattern: "takoctl status"
        ) else {
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
}
