/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct AgentHooksToolTests {
    private func createSandbox() -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-agent-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func detectAgentsDistinguishesNative7501AntigravityFromHookBasedGeminiCli() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).isEmpty)

        // Clean Antigravity config (no legacy hooks) is already configured via native OSC 7501.
        let agyConfigDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: agyConfigDir, withIntermediateDirectories: true)
        let agyHooks = agyConfigDir.appendingPathComponent("hooks.json")
        try "{}".write(to: agyHooks, atomically: true, encoding: .utf8)

        // Clean Gemini CLI settings still require BeforeAgent/AfterAgent hooks.
        let geminiSettings = sandbox.appendingPathComponent(".gemini/settings.json")
        try "{}".write(to: geminiSettings, atomically: true, encoding: .utf8)

        let detected = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detected.count == 2)

        let agy = try #require(detected.first { $0.id == "antigravity" })
        #expect(agy.name == "Antigravity")
        #expect(agy.isConfigured == true)

        let gemini = try #require(detected.first { $0.id == "gemini" })
        #expect(gemini.name == "Gemini CLI")
        #expect(gemini.isConfigured == false)
    }

    @Test
    func installAntigravityHooksStripsLegacyTakoStatusAndPreservesCustomEntries() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let geminiDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let hooksFile = geminiDir.appendingPathComponent("hooks.json")

        let legacyAndCustom: [String: Any] = [
            "custom-hook": ["enabled": true],
            "tako-status": [
                "enabled": true,
                "PreInvocation": [["type": "command", "command": "tako-hook agy pre_invocation"]],
                "Stop": [["type": "command", "command": "tako-hook agy stop"]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacyAndCustom).write(to: hooksFile)

        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).first { $0.id == "antigravity" }?.isConfigured == false)
        #expect(AgentHooksTool.installAntigravityHooks(baseDir: sandbox.path) == true)

        let readData = try Data(contentsOf: hooksFile)
        let json = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        #expect(json["custom-hook"] != nil)
        #expect(json["tako-status"] == nil)
        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).first { $0.id == "antigravity" }?.isConfigured == true)
    }

    @Test
    func installGeminiHooksWritesBeforeAfterAgentMatcherGroupsAndPreservesMixedHandlers() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let settingsFile = geminiDir.appendingPathComponent("settings.json")

        let existing: [String: Any] = [
            "model": "gemini-2.5-pro",
            "hooks": [
                "on_prompt": "echo legacy-ignored",
                "BeforeAgent": [
                    [
                        "matcher": "git.*",
                        "label": "Custom Git Matcher",
                        "hooks": [
                            ["type": "command", "command": "echo 'user-pre-hook'", "timeout": 10],
                            ["type": "command", "command": "echo 'user-disabled-hook'", "enabled": false],
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working --old-syntax; fi", "timeout": 5],
                            ["type": "command", "command": "echo 'user-post-hook'"]
                        ]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: settingsFile)

        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == false)
        #expect(AgentHooksTool.installGeminiHooks(baseDir: sandbox.path) == true)
        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == true)

        let readData = try Data(contentsOf: settingsFile)
        let root = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        #expect(root["model"] as? String == "gemini-2.5-pro")
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks["on_prompt"] != nil)
        #expect(hooks["AfterAgent"] != nil)

        let beforeGroups = try #require(hooks["BeforeAgent"] as? [[String: Any]])
        #expect(beforeGroups.count == 1)
        #expect(beforeGroups[0]["matcher"] as? String == "git.*")
        #expect(beforeGroups[0]["label"] as? String == "Custom Git Matcher")
        let innerHooks = try #require(beforeGroups[0]["hooks"] as? [[String: Any]])
        #expect(innerHooks.count == 4)
        #expect(innerHooks[0]["command"] as? String == "echo 'user-pre-hook'")
        #expect(innerHooks[1]["enabled"] as? Bool == false)
        #expect((innerHooks[2]["command"] as? String)?.contains("--text \"Thinking...\"") == true)
        #expect(innerHooks[3]["command"] as? String == "echo 'user-post-hook'")
    }

    @Test
    func claudeAndCodexLegacyHookMigrationPreservesUserHooksAndRespectsCodexHome() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeSettings = claudeDir.appendingPathComponent("settings.json")
        let claudeInitial: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "echo user-pre-submit", "timeout": 5],
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working; fi"]
                        ]
                    ]
                ],
                "Stop": [
                    ["matcher": "", "hooks": [["type": "command", "command": "tako-hook claude stop"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: claudeInitial).write(to: claudeSettings)
        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == true)

        let claudeOut = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        #expect(claudeOut["theme"] as? String == "dark")
        let claudeHooks = try #require(claudeOut["hooks"] as? [String: Any])
        #expect(claudeHooks["Stop"] == nil)
        let promptGroups = try #require(claudeHooks["UserPromptSubmit"] as? [[String: Any]])
        let promptEntries = try #require(promptGroups.first?["hooks"] as? [[String: Any]])
        #expect(promptEntries.count == 1)
        #expect(promptEntries.first?["command"] as? String == "echo user-pre-submit")

        // CODEX_HOME environment override cleans legacy Codex hooks while preserving user SessionStart.
        let customCodexHome = sandbox.appendingPathComponent("custom_codex_home")
        try FileManager.default.createDirectory(at: customCodexHome, withIntermediateDirectories: true)
        let codexHooksFile = customCodexHome.appendingPathComponent("hooks.json")
        let codexInitial: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["matcher": "", "hooks": [["type": "command", "command": "echo start"]]]
                ],
                "Stop": [
                    ["matcher": "", "hooks": [["type": "command", "command": "tako-hook codex stop"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: codexInitial).write(to: codexHooksFile)

        setenv("CODEX_HOME", customCodexHome.path, 1)
        defer { unsetenv("CODEX_HOME") }

        #expect(AgentHooksTool.hasLegacyOwnedStatusHooks(for: "codex", baseDir: nil) == true)
        #expect(AgentHooksTool.installCodexHooks(baseDir: nil) == true)
        #expect(AgentHooksTool.hasLegacyOwnedStatusHooks(for: "codex", baseDir: nil) == false)

        let codexOut = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: codexHooksFile)) as? [String: Any])
        let codexHooks = try #require(codexOut["hooks"] as? [String: Any])
        #expect(codexHooks["SessionStart"] != nil)
        #expect(codexHooks["Stop"] == nil)
    }

    @Test
    func installHooksBatchMigratesLegacyNativeAgentsAndInstallsGemini() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let agyConfigDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: agyConfigDir, withIntermediateDirectories: true)
        let agyLegacy: [String: Any] = [
            "tako-status": [
                "enabled": true,
                "Stop": [["type": "command", "command": "tako-hook agy stop"]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: agyLegacy).write(to: agyConfigDir.appendingPathComponent("hooks.json"))

        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "{}".write(to: sandbox.appendingPathComponent(".gemini/settings.json"), atomically: true, encoding: .utf8)

        let report = AgentHooksTool.installHooks(baseDir: sandbox.path, includeSkills: false)
        #expect(report.newlyInstalled.contains("Antigravity"))
        #expect(report.newlyInstalled.contains("Gemini CLI"))
        #expect(report.alreadyConfigured.contains("Claude Code"))
        #expect(report.failed.isEmpty)

        let secondReport = AgentHooksTool.installHooks(baseDir: sandbox.path, includeSkills: false)
        #expect(secondReport.newlyInstalled.isEmpty)
        #expect(secondReport.failed.isEmpty)
        #expect(secondReport.alreadyConfigured.contains("Antigravity"))
        #expect(secondReport.alreadyConfigured.contains("Gemini CLI"))
        #expect(secondReport.alreadyConfigured.contains("Claude Code"))
    }
}
