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
struct AgentHooksToolRecoveryTests {
    private func createSandbox() -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-agent-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func installAbortsOnCorruptOrUnreadableJsonWithoutClobbering() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        let malformed = "{\"broken\": [unclosed array"
        try malformed.write(to: settingsFile, atomically: true, encoding: .utf8)

        let success = AgentHooksTool.installClaudeHooks(baseDir: sandbox.path)
        #expect(success == false)

        let preserved = try String(contentsOf: settingsFile, encoding: .utf8)
        #expect(preserved == malformed)
    }

    @Test
    func installAbortsOnNestedInvalidStructureWithoutClobbering() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        // 1. Mixed array with invalid non-dict item
        let mixedContent = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "matcher": "",
                "hooks": [{"type": "command", "command": "echo valid"}]
              },
              "malformed_non_dict_element"
            ]
          }
        }
        """
        try mixedContent.write(to: settingsFile, atomically: true, encoding: .utf8)

        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == false)
        let preserved1 = try String(contentsOf: settingsFile, encoding: .utf8)
        #expect(preserved1 == mixedContent)

        // 2. Matcher group with invalid "hooks" container (string instead of array)
        let invalidHooksContainer = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {
                "matcher": "",
                "hooks": "invalid_string_not_array"
              }
            ]
          }
        }
        """
        try invalidHooksContainer.write(to: settingsFile, atomically: true, encoding: .utf8)

        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == false)
        let preserved2 = try String(contentsOf: settingsFile, encoding: .utf8)
        #expect(preserved2 == invalidHooksContainer)

        // 3. hooks field is non-dict
        let nonDictHooks = """
        {
          "hooks": ["invalid_array_root"]
        }
        """
        try nonDictHooks.write(to: settingsFile, atomically: true, encoding: .utf8)

        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == false)
        let preserved3 = try String(contentsOf: settingsFile, encoding: .utf8)
        #expect(preserved3 == nonDictHooks)
    }

    @Test
    func partialHookInstallationIsReportedAsUnconfiguredAndRepaired() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        // 1. Prompt-only hook (missing Stop)
        let promptOnly: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"]
                        ]
                    ]
                ]
            ]
        ]
        let data1 = try JSONSerialization.data(withJSONObject: promptOnly)
        try data1.write(to: settingsFile)

        #expect(AgentHooksTool.isClaudeConfigured(filePath: settingsFile.path) == false)

        // Running installer should add the missing Stop hook and preserve prompt hook
        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == true)
        #expect(AgentHooksTool.isClaudeConfigured(filePath: settingsFile.path) == true)

        let readData1 = try Data(contentsOf: settingsFile)
        let root1 = try #require(try JSONSerialization.jsonObject(with: readData1) as? [String: Any])
        let hooks1 = try #require(root1["hooks"] as? [String: Any])
        let promptGroups1 = try #require(hooks1["UserPromptSubmit"] as? [[String: Any]])
        #expect(promptGroups1.count == 1) // Not duplicated
        let stopGroups1 = try #require(hooks1["Stop"] as? [[String: Any]])
        #expect(stopGroups1.count == 1) // Newly added

        // 2. Disabled hook should report unconfigured
        let disabledContent: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "",
                        "enabled": false,
                        "hooks": [
                            ["type": "command", "command": "takoctl status set working"]
                        ]
                    ]
                ],
                "Stop": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "takoctl status set done"]
                        ]
                    ]
                ]
            ]
        ]
        let data2 = try JSONSerialization.data(withJSONObject: disabledContent)
        try data2.write(to: settingsFile)
        #expect(AgentHooksTool.isClaudeConfigured(filePath: settingsFile.path) == false)

        // 3. Unrelated text containing "takoctl status" should NOT report configured
        let unrelatedText: [String: Any] = [
            "custom_note": "Here is takoctl status documentation"
        ]
        let data3 = try JSONSerialization.data(withJSONObject: unrelatedText)
        try data3.write(to: settingsFile)
        #expect(AgentHooksTool.isClaudeConfigured(filePath: settingsFile.path) == false)

        // 4. Legacy invalid flat hook (from previous installer without matcher groups) is migrated
        let legacyFlat: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "type": "command",
                        "command": "takoctl status set working"
                    ]
                ]
            ]
        ]
        let data4 = try JSONSerialization.data(withJSONObject: legacyFlat)
        try data4.write(to: settingsFile)

        #expect(AgentHooksTool.isClaudeConfigured(filePath: settingsFile.path) == false)
        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == true)
        #expect(AgentHooksTool.isClaudeConfigured(filePath: settingsFile.path) == true)

        let readData4 = try Data(contentsOf: settingsFile)
        let root4 = try #require(try JSONSerialization.jsonObject(with: readData4) as? [String: Any])
        let hooks4 = try #require(root4["hooks"] as? [String: Any])
        let promptGroups4 = try #require(hooks4["UserPromptSubmit"] as? [[String: Any]])
        #expect(promptGroups4.first?["hooks"] != nil) // Successfully converted to matcher group
    }
}
