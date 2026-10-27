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
    func detectAgentsDistinguishesAntigravityAndGeminiCli() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let empty = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(empty.isEmpty)

        // Create Antigravity config
        let agyConfigDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: agyConfigDir, withIntermediateDirectories: true)
        let agyHooks = agyConfigDir.appendingPathComponent("hooks.json")
        try "{}".write(to: agyHooks, atomically: true, encoding: .utf8)

        // Create Gemini CLI settings
        let geminiSettings = sandbox.appendingPathComponent(".gemini/settings.json")
        try "{}".write(to: geminiSettings, atomically: true, encoding: .utf8)

        let detected = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detected.count == 2)
        let ids = detected.map(\.id)
        #expect(ids.contains("antigravity"))
        #expect(ids.contains("gemini"))

        let agy = try #require(detected.first { $0.id == "antigravity" })
        #expect(agy.name == "Antigravity")
        #expect(agy.isConfigured == false)

        let gemini = try #require(detected.first { $0.id == "gemini" })
        #expect(gemini.name == "Gemini CLI")
        #expect(gemini.isConfigured == false)
    }

    @Test
    func installAntigravityHooksWritesValidJsonAndPreservesExisting() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let geminiDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let hooksFile = geminiDir.appendingPathComponent("hooks.json")

        let existing: [String: Any] = [
            "custom-hook": ["enabled": true]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: hooksFile)

        let success = AgentHooksTool.installAntigravityHooks(baseDir: sandbox.path)
        #expect(success == true)

        let readData = try Data(contentsOf: hooksFile)
        let json = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        #expect(json["custom-hook"] != nil)
        let takoHook = try #require(json["tako-status"] as? [String: Any])
        #expect(takoHook["enabled"] as? Bool == true)
        #expect(takoHook["PreInvocation"] != nil)
        #expect(takoHook["Stop"] != nil)

        let detected = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detected.first { $0.id == "antigravity" }?.isConfigured == true)
    }

    @Test
    func installGeminiHooksWritesBeforeAfterAgentMatcherGroups() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let settingsFile = geminiDir.appendingPathComponent("settings.json")

        // Pre-populate with user model setting and legacy unsupported on_prompt
        let existing: [String: Any] = [
            "model": "gemini-2.5-pro",
            "hooks": [
                "on_prompt": "echo legacy-ignored"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: settingsFile)

        // Initially legacy on_prompt must NOT be reported as configured
        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == false)

        #expect(AgentHooksTool.installGeminiHooks(baseDir: sandbox.path) == true)

        let readData = try Data(contentsOf: settingsFile)
        let root = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        #expect(root["model"] as? String == "gemini-2.5-pro")
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks["on_prompt"] != nil) // Preserved
        #expect(hooks["BeforeAgent"] != nil)
        #expect(hooks["AfterAgent"] != nil)

        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == true)
    }

    @Test
    func installClaudeHooksPreservesExistingUserHooksAndUsesMatcherGroups() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "echo user-pre-submit",
                                "timeout": 5
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: settingsFile)

        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == true)

        let readData = try Data(contentsOf: settingsFile)
        let root = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        #expect(root["theme"] as? String == "dark")
        let hooks = try #require(root["hooks"] as? [String: Any])
        let promptGroups = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        #expect(promptGroups.count == 2)
        #expect(promptGroups[0]["hooks"] != nil)
        #expect(promptGroups[1]["hooks"] != nil)

        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(!stopGroups.isEmpty)

        // Idempotent reinstall
        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == true)
        let readData2 = try Data(contentsOf: settingsFile)
        let root2 = try #require(try JSONSerialization.jsonObject(with: readData2) as? [String: Any])
        let hooks2 = try #require(root2["hooks"] as? [String: Any])
        let promptGroups2 = try #require(hooks2["UserPromptSubmit"] as? [[String: Any]])
        #expect(promptGroups2.count == 2)
    }

    @Test
    func installCodexHooksPreservesExistingUserHooksAndTargetsHooksJson() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let codexDir = sandbox.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let hooksFile = codexDir.appendingPathComponent("hooks.json")

        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "",
                        "hooks": [["type": "command", "command": "echo start"]]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: hooksFile)

        #expect(AgentHooksTool.installCodexHooks(baseDir: sandbox.path) == true)

        let readData = try Data(contentsOf: hooksFile)
        let root = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil)
        #expect(hooks["PermissionRequest"] != nil)
        let interrupt = try #require(hooks["Interrupt"] as? [[String: Any]])
        let command = try #require((interrupt.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(command.contains("tako-hook codex interrupt"))
        #expect(command.contains("takoctl status set idle"))
        #expect(AgentHooksTool.isCodexConfigured(filePath: hooksFile.path))

        // A second install replaces the Interrupt handler instead of adding another.
        #expect(AgentHooksTool.installCodexHooks(baseDir: sandbox.path) == true)
        let again = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile)) as? [String: Any])
        let againInterrupt = try #require((again["hooks"] as? [String: Any])?["Interrupt"] as? [[String: Any]])
        #expect(againInterrupt.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.count == 1)
    }

    @Test
    func installCodexHooksRespectsCodexHomeEnvironmentVariable() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let customCodexHome = sandbox.appendingPathComponent("custom_codex_home")
        setenv("CODEX_HOME", customCodexHome.path, 1)
        defer { unsetenv("CODEX_HOME") }

        #expect(AgentHooksTool.installCodexHooks(baseDir: nil) == true)
        let hooksFile = customCodexHome.appendingPathComponent("hooks.json")
        #expect(FileManager.default.fileExists(atPath: hooksFile.path))

        let readData = try Data(contentsOf: hooksFile)
        let root = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil)
        #expect(hooks["PermissionRequest"] != nil)
    }

    @Test
    func installHooksBatchReturnsAccurateReport() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        // Create Antigravity config
        let agyConfigDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: agyConfigDir, withIntermediateDirectories: true)
        try "{}".write(to: agyConfigDir.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)

        // Create Claude dir
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent(".claude"), withIntermediateDirectories: true)

        let report = AgentHooksTool.installHooks(baseDir: sandbox.path)
        #expect(report.newlyInstalled.contains("Antigravity"))
        #expect(report.newlyInstalled.contains("Claude Code"))
        #expect(report.failed.isEmpty)

        // Second run should find all already configured
        let secondReport = AgentHooksTool.installHooks(baseDir: sandbox.path)
        #expect(secondReport.newlyInstalled.isEmpty)
        #expect(secondReport.failed.isEmpty)
        #expect(secondReport.alreadyConfigured.contains("Antigravity"))
        #expect(secondReport.alreadyConfigured.contains("Claude Code"))
    }

    @Test
    func installClaudeHooksConfiguresDoneAndApprovalHooks() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        let initialContent: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "",
                        "hooks": [["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working; fi"]]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: initialContent)
        try data.write(to: settingsFile)

        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == true)
        let readData = try Data(contentsOf: settingsFile)
        let root = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 1)
        let stopHooks = try #require(stopGroups[0]["hooks"] as? [[String: Any]])
        let cmd = try #require(stopHooks[0]["command"] as? String)
        #expect(cmd.contains("takoctl status set done"))

        let permGroups = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        #expect(permGroups.count == 1)
        let permHooks = try #require(permGroups[0]["hooks"] as? [[String: Any]])
        let permCmd = try #require(permHooks[0]["command"] as? String)
        #expect(permCmd.contains("takoctl status set needs_approval"))

        let elicitationGroups = try #require(hooks["Elicitation"] as? [[String: Any]])
        #expect(elicitationGroups.count == 1)
        let elicitationHooks = try #require(elicitationGroups[0]["hooks"] as? [[String: Any]])
        let elicitationCmd = try #require(elicitationHooks[0]["command"] as? String)
        #expect(elicitationCmd.contains("takoctl status set waiting_for_input"))
    }

    @Test
    func mixedMatcherGroupPreservesUserHandlersAndMetadataOnUpgrade() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        let initialContent: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
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
        let data = try JSONSerialization.data(withJSONObject: initialContent)
        try data.write(to: settingsFile)

        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == true)

        let readData = try Data(contentsOf: settingsFile)
        let root = try #require(try JSONSerialization.jsonObject(with: readData) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let promptGroups = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])

        #expect(promptGroups.count == 1)
        let group = promptGroups[0]
        #expect(group["matcher"] as? String == "git.*")
        #expect(group["label"] as? String == "Custom Git Matcher")

        let innerHooks = try #require(group["hooks"] as? [[String: Any]])
        #expect(innerHooks.count == 4)

        #expect(innerHooks[0]["command"] as? String == "echo 'user-pre-hook'")
        #expect(innerHooks[0]["timeout"] as? Int == 10)

        #expect(innerHooks[1]["command"] as? String == "echo 'user-disabled-hook'")
        #expect(innerHooks[1]["enabled"] as? Bool == false)

        let upgradedCmd = try #require(innerHooks[2]["command"] as? String)
        #expect(upgradedCmd.contains("takoctl status set working"))
        #expect(upgradedCmd.contains("--text \"Thinking...\""))

        #expect(innerHooks[3]["command"] as? String == "echo 'user-post-hook'")
    }
}
