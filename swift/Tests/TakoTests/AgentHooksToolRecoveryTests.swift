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
    func installAndCleanupAbortOnCorruptJsonWithoutClobbering() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        let claudeFile = claudeDir.appendingPathComponent("settings.json")
        let geminiFile = geminiDir.appendingPathComponent("settings.json")
        let malformed = "{\"broken\": [unclosed array"
        try malformed.write(to: claudeFile, atomically: true, encoding: .utf8)
        try malformed.write(to: geminiFile, atomically: true, encoding: .utf8)

        #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == false)
        #expect(AgentHooksTool.installGeminiHooks(baseDir: sandbox.path) == false)

        #expect(try String(contentsOf: claudeFile, encoding: .utf8) == malformed)
        #expect(try String(contentsOf: geminiFile, encoding: .utf8) == malformed)
    }

    @Test
    func installAndCleanupAbortOnNestedInvalidStructureWithoutClobbering() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let claudeFile = claudeDir.appendingPathComponent("settings.json")
        let geminiFile = geminiDir.appendingPathComponent("settings.json")

        let invalidPayloads = [
            """
            {
              "hooks": {
                "BeforeAgent": [
                  {
                    "matcher": "*",
                    "hooks": [{"type": "command", "command": "echo valid"}]
                  },
                  "malformed_non_dict_element"
                ]
              }
            }
            """,
            """
            {
              "hooks": {
                "BeforeAgent": [
                  {
                    "matcher": "*",
                    "hooks": "invalid_string_not_array"
                  }
                ]
              }
            }
            """,
            """
            {
              "hooks": ["invalid_array_root"]
            }
            """
        ]

        for payload in invalidPayloads {
            try payload.write(to: claudeFile, atomically: true, encoding: .utf8)
            try payload.write(to: geminiFile, atomically: true, encoding: .utf8)

            #expect(AgentHooksTool.installClaudeHooks(baseDir: sandbox.path) == false)
            #expect(AgentHooksTool.installGeminiHooks(baseDir: sandbox.path) == false)

            #expect(try String(contentsOf: claudeFile, encoding: .utf8) == payload)
            #expect(try String(contentsOf: geminiFile, encoding: .utf8) == payload)
        }
    }

    @Test
    func partialGeminiHookInstallationIsReportedAsUnconfiguredAndRepaired() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let settingsFile = geminiDir.appendingPathComponent("settings.json")

        // 1. BeforeAgent-only hook (missing AfterAgent)
        let beforeOnly: [String: Any] = [
            "hooks": [
                "BeforeAgent": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"]
                        ]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: beforeOnly).write(to: settingsFile)
        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == false)

        #expect(AgentHooksTool.installGeminiHooks(baseDir: sandbox.path) == true)
        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == true)

        let root1 = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any])
        let hooks1 = try #require(root1["hooks"] as? [String: Any])
        #expect((hooks1["BeforeAgent"] as? [[String: Any]])?.count == 1)
        #expect((hooks1["AfterAgent"] as? [[String: Any]])?.count == 1)

        // 2. Unrelated text containing "takoctl status" must NOT report configured
        let unrelatedText: [String: Any] = [
            "custom_note": "Here is takoctl status documentation"
        ]
        try JSONSerialization.data(withJSONObject: unrelatedText).write(to: settingsFile)
        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == false)

        // 3. Legacy flat hook is migrated into a matcher group on Gemini
        let legacyFlat: [String: Any] = [
            "hooks": [
                "BeforeAgent": [
                    ["type": "command", "command": "takoctl status set working"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacyFlat).write(to: settingsFile)
        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == false)
        #expect(AgentHooksTool.installGeminiHooks(baseDir: sandbox.path) == true)
        #expect(AgentHooksTool.isGeminiConfigured(filePath: settingsFile.path) == true)
    }
}
