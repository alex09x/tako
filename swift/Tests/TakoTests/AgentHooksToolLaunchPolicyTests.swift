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

        // Automatic test harness suppression (XCTestCase active in testing)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: true) == false)

        // Default clean state without test harness
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == true)

        // CLI flags suppression
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--no-launch-notices"], environment: [:], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--no-update"], environment: [:], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--selftest"], environment: [:], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako", "--selftest-run"], environment: [:], userDefaults: defaults, isTesting: false) == false)

        // Environment variables suppression
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: ["TAKO_NO_LAUNCH_NOTICES": "1"], userDefaults: defaults, isTesting: false) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: ["TAKO_NO_UPDATE": "1"], userDefaults: defaults, isTesting: false) == false)

        // Declined user preference suppression
        defaults.set(true, forKey: AgentHooksTool.declinedKey)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == false)
    }

    @Test
    func disabledMatcherGroupIsNotSilentlyReEnabled() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        // Matcher group explicitly disabled by user
        let disabledGroupConfig: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "",
                        "enabled": false,
                        "hooks": [
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"]
                        ]
                    ]
                ],
                "Stop": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set done >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi"]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: disabledGroupConfig)
        try data.write(to: settingsFile)

        // Pre-check: must be detected as unconfigured
        let detectedBefore = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedBefore.first { $0.id == "claude" }?.isConfigured == false)

        // Install should respect deliberate disabled configuration and NOT claim newlyInstalled
        let report = AgentHooksTool.installHooks(for: ["claude"], baseDir: sandbox.path)
        #expect(!report.newlyInstalled.contains("Claude Code"))
        #expect(report.failed.contains("Claude Code"))

        // Post-check: must remain unconfigured
        let detectedAfter = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedAfter.first { $0.id == "claude" }?.isConfigured == false)
    }

    @Test
    func disabledMatcherHandlerIsNotSilentlyReEnabled() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let claudeDir = sandbox.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")

        // Hook handler inside matcher group explicitly disabled by user
        let disabledHandlerConfig: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "if [ -n \"$TAKO_SOCKET\" ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi",
                                "enabled": false
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: disabledHandlerConfig)
        try data.write(to: settingsFile)

        let detectedBefore = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedBefore.first { $0.id == "claude" }?.isConfigured == false)

        let report = AgentHooksTool.installHooks(for: ["claude"], baseDir: sandbox.path)
        #expect(!report.newlyInstalled.contains("Claude Code"))
        #expect(report.failed.contains("Claude Code"))

        let detectedAfter = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedAfter.first { $0.id == "claude" }?.isConfigured == false)
    }

    @Test
    func disabledDirectGroupIsNotSilentlyReEnabled() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let agyConfigDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: agyConfigDir, withIntermediateDirectories: true)
        let hooksFile = agyConfigDir.appendingPathComponent("hooks.json")

        // Antigravity tako-status group explicitly disabled by user
        let disabledAgy: [String: Any] = [
            "tako-status": [
                "enabled": false,
                "PreInvocation": [
                    ["type": "command", "command": "takoctl status set working"]
                ],
                "Stop": [
                    ["type": "command", "command": "takoctl status set idle"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: disabledAgy)
        try data.write(to: hooksFile)

        let detectedBefore = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedBefore.first { $0.id == "antigravity" }?.isConfigured == false)

        let report = AgentHooksTool.installHooks(for: ["antigravity"], baseDir: sandbox.path)
        #expect(!report.newlyInstalled.contains("Antigravity"))
        #expect(report.failed.contains("Antigravity"))

        let detectedAfter = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedAfter.first { $0.id == "antigravity" }?.isConfigured == false)
    }

    @Test
    func disabledDirectHandlerIsNotSilentlyReEnabled() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let agyConfigDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: agyConfigDir, withIntermediateDirectories: true)
        let hooksFile = agyConfigDir.appendingPathComponent("hooks.json")

        // Handler inside PreInvocation explicitly disabled by user
        let disabledHandlerAgy: [String: Any] = [
            "tako-status": [
                "enabled": true,
                "PreInvocation": [
                    [
                        "type": "command",
                        "command": "takoctl status set working",
                        "enabled": false
                    ]
                ],
                "Stop": [
                    ["type": "command", "command": "takoctl status set idle"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: disabledHandlerAgy)
        try data.write(to: hooksFile)

        let detectedBefore = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedBefore.first { $0.id == "antigravity" }?.isConfigured == false)

        let report = AgentHooksTool.installHooks(for: ["antigravity"], baseDir: sandbox.path)
        #expect(!report.newlyInstalled.contains("Antigravity"))
        #expect(report.failed.contains("Antigravity"))

        let detectedAfter = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(detectedAfter.first { $0.id == "antigravity" }?.isConfigured == false)
    }

    @Test
    func deliberateConnectInstallAndDeclinePreferenceBehavior() throws {
        let sandbox = createSandbox()
        defer { cleanupSandbox(sandbox) }

        let suiteName = "test-launch-preference-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. Initial state: not declined
        #expect(defaults.bool(forKey: AgentHooksTool.declinedKey) == false)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == true)

        // 2. Decline preference ("Don't Ask Again") sets key and suppresses future prompts
        defaults.set(true, forKey: AgentHooksTool.declinedKey)
        #expect(defaults.bool(forKey: AgentHooksTool.declinedKey) == true)
        #expect(AgentHooksTool.shouldOfferAtLaunch(arguments: ["tako"], environment: [:], userDefaults: defaults, isTesting: false) == false)

        // 3. Deliberate connect in sandbox installs hooks cleanly
        let configDir = sandbox.appendingPathComponent(".gemini/config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let hooksFile = configDir.appendingPathComponent("hooks.json")
        try "{}".write(to: hooksFile, atomically: true, encoding: .utf8)

        let report = AgentHooksTool.installHooks(for: ["antigravity"], baseDir: sandbox.path)
        #expect(report.newlyInstalled.contains("Antigravity"))
        #expect(!report.failed.contains("Antigravity"))

        let agents = AgentHooksTool.detectAgents(baseDir: sandbox.path)
        #expect(agents.first { $0.id == "antigravity" }?.isConfigured == true)
    }
}
