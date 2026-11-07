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
}
