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
struct AgentHooksToolLaunchPolicyTests {
    private func createSandbox() -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-launch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func launchOfferSuppressionRespectsFlagsEnvAndTestHarness() {
        let suiteName = "test-launch-suite-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: true) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == true)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--no-launch-notices"], environment: [:], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--no-update"], environment: [:], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--selftest"], environment: [:], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--selftest-run"], environment: [:], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: ["TAKO_NO_LAUNCH_NOTICES": "1"], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: ["TAKO_NO_UPDATE": "1"], userDefaults: defaults, isTesting: false) == false)

        defaults.set(true, forKey: AgentHooksTool.declinedKey)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == false)
    }

    @Test
    func disabledGeminiMatcherGroupIsNotSilentlyReEnabled() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let settingsFile = geminiDir.appendingPathComponent("settings.json")

        let disabledGroupConfig: [String: Any] = [
            "hooks": [
                "BeforeAgent": [
                    [
                        "matcher": "*",
                        "enabled": false,
                        "hooks": [
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; fi"]
                        ]
                    ]
                ],
                "AfterAgent": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set idle >/dev/null 2>&1; fi"]
                        ]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: disabledGroupConfig).write(to: settingsFile)

        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).first { $0.id == "gemini" }?.isConfigured == false)

        let report = AgentHooksTool.installHooks(for: ["gemini"], baseDir: sandbox.path, includeSkills: false)
        #expect(!report.newlyInstalled.contains("Gemini CLI"))
        #expect(report.failed.contains("Gemini CLI"))
        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).first { $0.id == "gemini" }?.isConfigured == false)
    }

    @Test
    func disabledGeminiMatcherHandlerIsNotSilentlyReEnabled() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let settingsFile = geminiDir.appendingPathComponent("settings.json")

        let disabledHandlerConfig: [String: Any] = [
            "hooks": [
                "BeforeAgent": [
                    [
                        "matcher": "*",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; fi",
                                "enabled": false
                            ]
                        ]
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: disabledHandlerConfig).write(to: settingsFile)

        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).first { $0.id == "gemini" }?.isConfigured == false)

        let report = AgentHooksTool.installHooks(for: ["gemini"], baseDir: sandbox.path, includeSkills: false)
        #expect(!report.newlyInstalled.contains("Gemini CLI"))
        #expect(report.failed.contains("Gemini CLI"))
        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).first { $0.id == "gemini" }?.isConfigured == false)
    }

    @Test
    func cleanNative7501AgentsDoNotTriggerUnconfiguredLaunchOffer() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        for dir in [".claude", ".codex", ".gemini/config", ".qwen", ".config/muse"] {
            try FileManager.default.createDirectory(at: sandbox.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "{}".write(to: sandbox.appendingPathComponent(".gemini/config/hooks.json"), atomically: true, encoding: .utf8)

        let detected = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(Set(detected.map(\.id)) == ["antigravity", "claude", "codex", "qwen", "muse"])
        #expect(detected.allSatisfy { $0.isConfigured })
    }

    @Test
    func deliberateGeminiConnectInstallAndDeclinePreferenceBehavior() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let suiteName = "test-launch-preference-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.bool(forKey: AgentHooksTool.declinedKey) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == true)

        defaults.set(true, forKey: AgentHooksTool.declinedKey)
        #expect(defaults.bool(forKey: AgentHooksTool.declinedKey) == true)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == false)

        let geminiDir = sandbox.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        try "{}".write(to: geminiDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let report = AgentHooksTool.installHooks(for: ["gemini"], baseDir: sandbox.path, includeSkills: false)
        #expect(report.newlyInstalled.contains("Gemini CLI"))
        #expect(!report.failed.contains("Gemini CLI"))
        #expect(AgentHooksTool.detectAgents(baseDir: sandbox.path).first { $0.id == "gemini" }?.isConfigured == true)
    }
}
