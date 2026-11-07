/*
 * tako — Native agent setup tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

private actor NativeSetupRunner {
    var skills = Set<String>()
    var commands: [SetupAgentService.Command] = []
    let installExit: Int32
    let malformed: Bool

    init(installExit: Int32 = 0, malformed: Bool = false) {
        self.installExit = installExit
        self.malformed = malformed
    }

    func run(_ command: SetupAgentService.Command) throws -> SetupAgentService.CommandResult {
        commands.append(command)
        let args = command.arguments
        let home = command.environment["HOME"]!
        if args.starts(with: ["skills", "install"]) {
            if installExit == 0 {
                skills.insert(args[2])
            }
            return .init(exitCode: installExit)
        }
        if malformed { return .init(stdout: Data("malformed".utf8)) }
        let rows: [[String: Any]] = ["qwen", "muse"].map { id in
            let root = id == "qwen" ? home + "/.qwen" : home + "/.config/muse"
            return [
                "name": id,
                "installed": skills.contains(id),
                "file_exists": skills.contains(id),
                "skill_path": root + "/skills/tako/SKILL.md"
            ]
        }
        return .init(stdout: try JSONSerialization.data(withJSONObject: rows))
    }

    func recorded() -> [SetupAgentService.Command] { commands }
}

@Suite @MainActor
struct QwenMuseAgentTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in [".qwen", ".config/muse"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        return url
    }

    @Test func catalogDetectionLegacyHookCleanupAndSkillOnlyConnect() async throws {
        let base = try home()
        defer { try? FileManager.default.removeItem(at: base) }

        // Seed legacy Tako managed hook + receipt in Qwen alongside a custom user hook.
        let qwenSettings = base.appendingPathComponent(".qwen/settings.json")
        let legacyQwen = """
        {
          "allowManagedHooksOnly": false,
          "hooks": {
            "UserPromptSubmit": [
              {
                "matcher": "*",
                "hooks": [
                  {"type": "command", "command": "/usr/bin/python3 '/Applications/Tako.app/Contents/Resources/tako-hook.py' qwen start; :"},
                  {"type": "command", "command": "echo keep-user-qwen"}
                ]
              }
            ]
          }
        }
        """
        try legacyQwen.write(to: qwenSettings, atomically: true, encoding: .utf8)
        let receipt = base.appendingPathComponent(".local/share/tako/hooks/qwen.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: receipt, atomically: true, encoding: .utf8)

        let fake = NativeSetupRunner()
        let before = await SetupAgentService.statuses(baseDir: base.path, runner: { try await fake.run($0) })
        #expect(before.map(\.id) == ["antigravity", "gemini", "claude", "codex", "qwen", "muse"])
        let beforeQwen = try #require(before.first { $0.id == "qwen" })
        #expect(beforeQwen.isDetected && beforeQwen.usesNativeStatus && beforeQwen.hasLegacyHooks && !beforeQwen.isReady)
        let beforeMuse = try #require(before.first { $0.id == "muse" })
        #expect(beforeMuse.isDetected && beforeMuse.usesNativeStatus && !beforeMuse.hasLegacyHooks && !beforeMuse.isReady)

        let after = await SetupAgentService.connect(
            ids: ["qwen", "muse"], baseDir: base.path, runner: { try await fake.run($0) }
        )
        #expect(after.filter { ["qwen", "muse"].contains($0.id) }.allSatisfy { $0.isReady && !$0.hasLegacyHooks })
        #expect(!FileManager.default.fileExists(atPath: receipt.path))

        let cleanedText = try String(contentsOf: qwenSettings, encoding: .utf8)
        #expect(cleanedText.contains("echo keep-user-qwen"))
        #expect(!cleanedText.contains("tako-hook.py"))

        let commands = await fake.recorded()
        #expect(!commands.contains { $0.arguments.first == "hooks" })
        for id in ["qwen", "muse"] {
            let root = SetupAgentService.nativeRoot(id, baseDir: base.path)
            #expect(commands.contains {
                $0.arguments == ["skills", "install", id, "--yes", "--json", "--skill-path", root + "/skills/tako/SKILL.md"]
            })
        }
        #expect(commands.allSatisfy { $0.environment["HOME"] == base.path && $0.environment["XDG_CONFIG_HOME"] == nil })
    }

    @Test func malformedConfigOrSkillFailureStaysUnready() async throws {
        let base = try home()
        defer { try? FileManager.default.removeItem(at: base) }

        try "corrupt".write(to: base.appendingPathComponent(".qwen/settings.json"), atomically: true, encoding: .utf8)
        let fake = NativeSetupRunner(installExit: 17)
        let statuses = await SetupAgentService.connect(
            ids: ["qwen", "muse"], baseDir: base.path, runner: { try await fake.run($0) }
        )
        #expect(statuses.allSatisfy { !$0.isReady })
        let qwen = try #require(statuses.first { $0.id == "qwen" })
        #expect(qwen.hasLegacyHooks && !qwen.skillInstalled)
        let muse = try #require(statuses.first { $0.id == "muse" })
        #expect(!muse.hasLegacyHooks && !muse.skillInstalled && muse.detail != nil)
    }

    @Test func nativeRootAndStatusHelpersRespectScope() {
        let base = "/fixture"
        let rows = #"[{"name":"qwen","installed":true,"file_exists":true,"config_path":"/host/.qwen/settings.json"}]"#
        for result in [SetupAgentService.CommandResult(stdout: Data(rows.utf8)),
                       .init(exitCode: 1, stdout: Data(rows.utf8)), .init(failure: "missing CLI"),
                       .init(stdout: Data("[]".utf8)), .init(stdout: Data("{}".utf8))] {
            #expect(!SetupAgentService.nativeHooksInstalled(result, id: "qwen", baseDir: base))
        }
        #expect(SetupAgentService.nativeRoot("muse", baseDir: base, environment: ["XDG_CONFIG_HOME": "/host"]) == "/fixture/.config/muse")
        #expect(SetupAgentService.nativeRoot("muse", baseDir: nil, environment: ["XDG_CONFIG_HOME": "/native"]) == "/native/muse")
        #expect(SetupAgentService.nativeRoot("muse", baseDir: nil, environment: ["XDG_CONFIG_HOME": "relative"]).hasSuffix("/.config/muse"))
    }

    @Test func detectsExecutablesWithoutStartingThem() throws {
        let base = try home()
        defer { try? FileManager.default.removeItem(at: base) }
        for id in ["qwen", "muse"] {
            let executable = base.appendingPathComponent(id)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            #expect(SetupAgentService.nativeExecutableExists(id, environment: ["PATH": base.path]))
            #expect(!SetupAgentService.nativeExecutableExists(id, environment: ["PATH": base.appendingPathComponent("missing").path]))
        }
        let detected = AgentHooksTool.detectAgents(baseDir: base.path)
        #expect(Set(detected.map(\.id)) == ["qwen", "muse"])
        #expect(detected.allSatisfy { $0.isConfigured })
    }

    @Test func exact507QwenAndMuseManagedHooksAndReceiptsAreCleanedWhileUserInlineMarkerPreserved() async throws {
        let base = try home()
        defer { try? FileManager.default.removeItem(at: base) }

        // 1. Exact 507 Qwen PATH=... python wrapper + sidecar .tako-qwen-receipt + user disableAllHooks=false
        let qwenSettings = base.appendingPathComponent(".qwen/settings.json")
        let qwenReceipt = base.appendingPathComponent(".qwen/settings.json.tako-qwen-receipt")
        let qwenCmd = #"PATH='/Applications/Tako.app/Contents/MacOS':"$PATH" /usr/bin/python3 '/Applications/Tako.app/Contents/Resources/tako-hook.py' qwen user_prompt_submit; :"#
        let qwenJSON: [String: Any] = [
            "disableAllHooks": false,
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": qwenCmd, "timeout": 5],
                            ["type": "command", "command": "echo keep-qwen-user"]
                        ]
                    ]
                ]
            ]
        ]
        let qwenReceiptJSON: [String: Any] = [
            "UserPromptSubmit": [
                ["matcher": "*", "hooks": [["type": "command", "command": qwenCmd, "timeout": 5]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: qwenJSON, options: [.prettyPrinted]).write(to: qwenSettings)
        try JSONSerialization.data(withJSONObject: qwenReceiptJSON, options: [.prettyPrinted]).write(to: qwenReceipt)

        // 2. Exact 507 Muse settings.json -> managed_hooks_path + .tako-muse-receipt
        let museDir = base.appendingPathComponent(".config/muse")
        let museSettings = museDir.appendingPathComponent("settings.json")
        let museManaged = museDir.appendingPathComponent("tako-managed-hooks.json")
        let museReceipt = museDir.appendingPathComponent("settings.json.tako-muse-receipt")
        let museCmd = #"PATH='/Applications/Tako.app/Contents/MacOS':"$PATH" /usr/bin/python3 '/Applications/Tako.app/Contents/Resources/tako-hook.py' muse start; :"#
        let museSettingsJSON: [String: Any] = [
            "managed_hooks_path": "tako-managed-hooks.json",
            "managed_hooks_env_vars": ["CUSTOM_ENV", "TAKO_SURFACE_ID", "TAKO_SOCKET"],
            "schema_version": 1
        ]
        let museManagedJSON: [String: Any] = [
            "hooks": [
                "BeforeAgent": [
                    ["matcher": "*", "hooks": [["type": "command", "command": museCmd]]]
                ]
            ]
        ]
        let museReceiptJSON: [String: Any] = [
            "version": 1,
            "managed_path": museManaged.path,
            "added_env": ["TAKO_SURFACE_ID", "TAKO_SOCKET"],
            "pointer_added": true,
            "schema_added": true,
            "env_added": false,
            "dispatcher_hooks": [:]
        ]
        try JSONSerialization.data(withJSONObject: museSettingsJSON, options: [.prettyPrinted]).write(to: museSettings)
        try JSONSerialization.data(withJSONObject: museManagedJSON, options: [.prettyPrinted]).write(to: museManaged)
        try JSONSerialization.data(withJSONObject: museReceiptJSON, options: [.prettyPrinted]).write(to: museReceipt)

        // 3. Claude settings.json with user-modified inline takoctl command that MUST NOT be deleted
        let claudeDir = base.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeSettings = claudeDir.appendingPathComponent("settings.json")
        let userInlineCmd = #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --target "$TAKO_SURFACE_ID"; /usr/bin/touch /tmp/user-owned-marker; fi; :"#
        let claudeJSON: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["matcher": "", "hooks": [["type": "command", "command": userInlineCmd]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: claudeJSON, options: [.prettyPrinted]).write(to: claudeSettings)

        let claudeRawBefore = try Data(contentsOf: claudeSettings)

        #expect(AgentHooksTool.hasLegacyOwnedStatusHooks(for: "qwen", baseDir: base.path))
        #expect(AgentHooksTool.hasLegacyOwnedStatusHooks(for: "muse", baseDir: base.path))
        #expect(!AgentHooksTool.hasLegacyOwnedStatusHooks(for: "claude", baseDir: base.path))

        let fake = NativeSetupRunner()
        let before = await SetupAgentService.statuses(baseDir: base.path, runner: { try await fake.run($0) })
        #expect(before.first { $0.id == "qwen" }?.hasLegacyHooks == true)
        #expect(before.first { $0.id == "muse" }?.hasLegacyHooks == true)

        let after = await SetupAgentService.connect(
            ids: ["qwen", "muse"], baseDir: base.path, runner: { try await fake.run($0) }
        )
        #expect(after.filter { ["qwen", "muse"].contains($0.id) }.allSatisfy { $0.isReady && !$0.hasLegacyHooks })
        #expect(!FileManager.default.fileExists(atPath: qwenReceipt.path))
        #expect(!FileManager.default.fileExists(atPath: museReceipt.path))
        #expect(!FileManager.default.fileExists(atPath: museManaged.path))

        let qwenAfter = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: qwenSettings)) as? [String: Any])
        #expect(qwenAfter["disableAllHooks"] as? Bool == false)
        let qwenAfterText = try String(contentsOf: qwenSettings, encoding: .utf8)
        #expect(qwenAfterText.contains("echo keep-qwen-user"))
        #expect(!qwenAfterText.contains("tako-hook.py"))

        // Also verify disableAllHooks=false is preserved when Tako owned the ONLY hook in Qwen settings.json.
        let qwenOnlyTako: [String: Any] = [
            "disableAllHooks": false,
            "hooks": [
                "UserPromptSubmit": [
                    ["matcher": "*", "hooks": [["type": "command", "command": qwenCmd, "timeout": 5]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: qwenOnlyTako, options: [.prettyPrinted]).write(to: qwenSettings)
        #expect(AgentHooksTool.cleanupLegacyStatusHooks(for: "qwen", baseDir: base.path))
        let qwenEmptyHooksAfter = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: qwenSettings)) as? [String: Any]
        )
        #expect(qwenEmptyHooksAfter["hooks"] == nil)
        #expect(qwenEmptyHooksAfter["disableAllHooks"] as? Bool == false)

        let museAfter = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: museSettings)) as? [String: Any])
        #expect(museAfter["managed_hooks_path"] == nil)
        #expect(museAfter["schema_version"] == nil)
        #expect(museAfter["managed_hooks_env_vars"] as? [String] == ["CUSTOM_ENV"])

        #expect(AgentHooksTool.cleanupLegacyStatusHooks(for: "claude", baseDir: base.path))
        #expect(try Data(contentsOf: claudeSettings) == claudeRawBefore)
        #expect(!FileManager.default.fileExists(atPath: claudeSettings.path + ".tako-bak"))
        let claudeAfter = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any]
        )
        let claudeHooks = try #require(claudeAfter["hooks"] as? [String: Any])
        let promptGroups = try #require(claudeHooks["UserPromptSubmit"] as? [[String: Any]])
        let promptInner = try #require(promptGroups.first?["hooks"] as? [[String: Any]])
        #expect(promptInner.first?["command"] as? String == userInlineCmd)
    }
}
