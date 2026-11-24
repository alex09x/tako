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
import Testing
@testable import Tako

private actor SetupSkillRunner {
    private var installed: Set<String>
    private var commands: [SetupAgentService.Command] = []
    private let installExit: Int32

    init(installed: Set<String> = [], installExit: Int32 = 0) {
        self.installed = installed
        self.installExit = installExit
    }

    func run(_ command: SetupAgentService.Command) throws -> SetupAgentService.CommandResult {
        commands.append(command)
        if command.arguments.starts(with: ["skills", "install"]) {
            if installExit == 0 { installed.insert(command.arguments[2]) }
            return .init(exitCode: installExit)
        }
        let home = command.environment["HOME"] ?? ""
        let rows: [[String: Any]] = ["claude", "gemini", "codex"].map { name in
            ["name": name, "title": name, "installed": installed.contains(name),
             "file_exists": installed.contains(name), "skill_path": home + "/.\(name)/skills/tako/SKILL.md"]
        }
        return .init(stdout: try JSONSerialization.data(withJSONObject: rows))
    }

    func recorded() -> [SetupAgentService.Command] { commands }
}

@Suite(.serialized)
@MainActor
struct SetupAgentServiceTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tako-setup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ path: String, home: URL) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test
    func nativeStatusAgentWithoutSkillIsNotReadyAndRefreshDoesNotWrite() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{}", ".claude/settings.json", home: home)
        let settings = home.appendingPathComponent(".claude/settings.json")
        let original = try Data(contentsOf: settings)
        let declined = UserDefaults.standard.object(forKey: AgentHooksTool.declinedKey) as? Bool
        let fake = SetupSkillRunner()
        let statuses = await SetupAgentService.statuses(baseDir: home.path, runner: { try await fake.run($0) })
        let claude = try #require(statuses.first { $0.id == "claude" })
        #expect(claude.usesNativeStatus && !claude.hasLegacyHooks && !claude.hooksInstalled)
        #expect(!claude.skillInstalled && !claude.isReady)
        #expect(claude.detail?.contains("skill") == true)
        #expect(try Data(contentsOf: settings) == original)
        #expect((UserDefaults.standard.object(forKey: AgentHooksTool.declinedKey) as? Bool) == declined)
        let commands = await fake.recorded()
        #expect(commands.count == 1)
        #expect(commands[0].arguments == ["skills", "status", "--json"])
        #expect(commands[0].environment["HOME"] == home.path)
        #expect(commands[0].environment["CODEX_HOME"] == nil)
    }

    @Test
    func connectStripsLegacyStatusHooksPreservesUnrelatedHooksAndInstallsSkill() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let mixed = """
        {
          "theme": "dark",
          "hooks": {
            "Stop": [
              {
                "matcher": "custom",
                "hooks": [
                  {"type": "command", "command": "echo user-hook"},
                  {"type": "command", "command": "tako-hook claude stop"}
                ]
              }
            ]
          }
        }
        """
        try write(mixed, ".claude/settings.json", home: home)
        try write("{}", ".codex/hooks.json", home: home)
        let codexFile = home.appendingPathComponent(".codex/hooks.json")
        let beforeCodex = try Data(contentsOf: codexFile)
        let fake = SetupSkillRunner()

        let pre = await SetupAgentService.statuses(baseDir: home.path, runner: { try await fake.run($0) })
        let preClaude = try #require(pre.first { $0.id == "claude" })
        #expect(preClaude.hasLegacyHooks && !preClaude.isReady)

        let statuses = await SetupAgentService.connect(
            ids: ["claude", "claude", "unknown"], baseDir: home.path, runner: { try await fake.run($0) }
        )
        #expect(statuses.map(\.id) == ["antigravity", "gemini", "claude", "codex", "qwen", "muse"])
        let claude = try #require(statuses.first { $0.id == "claude" })
        #expect(claude.isDetected && claude.usesNativeStatus && !claude.hasLegacyHooks && claude.skillInstalled && claude.isReady)
        #expect(claude.detail == nil)
        #expect(statuses.first { $0.id == "codex" }?.isReady == false)
        #expect(try Data(contentsOf: codexFile) == beforeCodex)

        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["theme"] as? String == "dark")
        let hooks = try #require(json["hooks"] as? [String: Any])
        let stops = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stops.contains { ($0["matcher"] as? String) == "custom" })
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("echo user-hook"))
        #expect(!text.contains("tako-hook"))
        let commands = await fake.recorded()
        #expect(commands.filter { $0.arguments.starts(with: ["skills", "install"]) }.map(\.arguments)
                == [["skills", "install", "claude", "--yes", "--json"]])
    }

    @Test
    func skillFailureRemainsVisibleAfterNativeMigrationSucceeds() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{}", ".claude/settings.json", home: home)
        let fake = SetupSkillRunner(installExit: 23)
        let statuses = await SetupAgentService.connect(
            ids: ["claude"], baseDir: home.path, runner: { try await fake.run($0) }
        )
        let claude = try #require(statuses.first { $0.id == "claude" })
        #expect(!claude.hasLegacyHooks && !claude.skillInstalled && !claude.isReady)
        #expect(claude.detail == "Skill installation exited with code 23.")
    }

    @Test
    func readyNativeAgentsDoNotReinstall() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{}", ".claude/settings.json", home: home)
        let settings = home.appendingPathComponent(".claude/settings.json")
        let original = try Data(contentsOf: settings)
        let fake = SetupSkillRunner(installed: ["claude"])
        let statuses = await SetupAgentService.connect(
            ids: ["claude"], baseDir: home.path, runner: { try await fake.run($0) }
        )
        #expect(statuses.first { $0.id == "claude" }?.isReady == true)
        #expect(try Data(contentsOf: settings) == original)
        let commands = await fake.recorded()
        #expect(commands.allSatisfy { $0.arguments == ["skills", "status", "--json"] })
    }

    @Test
    func malformedIncompleteAndFailedSkillStatusCannotMarkAgentReady() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{}", ".claude/settings.json", home: home)
        let responses: [SetupAgentService.CommandResult] = [
            .init(stdout: Data("not JSON".utf8)),
            .init(stdout: Data(#"[{"name":"claude","installed":"true","skill_path":"x"}]"#.utf8)),
            .init(stdout: Data(#"[{"name":"claude","installed":true,"skill_path":"x","file_exists":false}]"#.utf8)),
            .init(stdout: Data("[]".utf8)),
            .init(exitCode: 5),
            .init(failure: "takoctl timed out after 15 seconds."),
        ]
        for response in responses {
            let statuses = await SetupAgentService.statuses(baseDir: home.path, runner: { _ in response })
            let claude = try #require(statuses.first { $0.id == "claude" })
            #expect(!claude.skillInstalled && !claude.isReady)
            #expect(claude.detail != nil)
        }
        struct LaunchFailure: Error {}
        let statuses = await SetupAgentService.statuses(baseDir: home.path, runner: { _ in throw LaunchFailure() })
        #expect(statuses.first { $0.id == "claude" }?.detail == "Unable to launch takoctl.")
        #expect(statuses.allSatisfy { !$0.isReady })
    }

    @Test
    func malformedSettingsJsonPreservesFileAndSkipsSkillInstallOnBothNativeAndHookAgents() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("not JSON", ".claude/settings.json", home: home)
        try write("not JSON", ".gemini/settings.json", home: home)
        let fake = SetupSkillRunner()
        let statuses = await SetupAgentService.connect(
            ids: ["claude", "gemini"], baseDir: home.path, runner: { try await fake.run($0) }
        )
        let claude = try #require(statuses.first { $0.id == "claude" })
        #expect(!claude.isReady && claude.hasLegacyHooks)
        #expect(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8) == "not JSON")

        let gemini = try #require(statuses.first { $0.id == "gemini" })
        #expect(!gemini.isReady && !gemini.hooksInstalled)
        #expect(gemini.detail == "Required Tako hooks could not be installed.")
        #expect(try String(contentsOf: home.appendingPathComponent(".gemini/settings.json"), encoding: .utf8) == "not JSON")

        let commands = await fake.recorded()
        #expect(!commands.contains { $0.arguments.contains("install") })
    }

    @Test
    func antigravityUsesGeminiSkillWithoutInstallingGeminiHooksAndGeminiStillRequiresHooks() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{}", ".gemini/config/hooks.json", home: home)
        try write(#"{"note":"takoctl status set working; takoctl status set idle"}"#, ".gemini/settings.json", home: home)
        let fake = SetupSkillRunner()
        let statuses = await SetupAgentService.connect(
            ids: ["antigravity"], baseDir: home.path, runner: { try await fake.run($0) }
        )
        #expect(statuses.first { $0.id == "antigravity" }?.isReady == true)
        let gemini = try #require(statuses.first { $0.id == "gemini" })
        #expect(gemini.skillInstalled && !gemini.hooksInstalled && !gemini.isReady)
        let commands = await fake.recorded()
        #expect(commands.filter { $0.arguments.contains("install") }.map(\.arguments)
                == [["skills", "install", "gemini", "--yes", "--json"]])
    }

    @Test
    func missingExecutableIsVisibleWithoutLaunchingAnInstaller() async throws {
        let home = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("{}", ".claude/settings.json", home: home)
        let statuses = await SetupAgentService.statuses(
            baseDir: home.path, executableURL: home.appendingPathComponent("missing-takoctl")
        )
        let claude = try #require(statuses.first { $0.id == "claude" })
        #expect(!claude.isReady && !claude.skillInstalled)
        #expect(claude.detail?.contains("missing") == true)
    }
}
