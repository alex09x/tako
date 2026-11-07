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
    var hooks = Set<String>()
    var skills = Set<String>()
    var commands: [SetupAgentService.Command] = []
    let installWorks: Bool
    let malformed: Bool

    init(installWorks: Bool = true, malformed: Bool = false) {
        self.installWorks = installWorks
        self.malformed = malformed
    }

    func run(_ command: SetupAgentService.Command) throws -> SetupAgentService.CommandResult {
        commands.append(command)
        let args = command.arguments
        let home = command.environment["HOME"]!
        if args[1] == "install" {
            if installWorks {
                if args[0] == "hooks" { hooks.insert(args[2]) } else { skills.insert(args[2]) }
            }
            return .init()
        }
        if malformed { return .init(stdout: Data("malformed".utf8)) }
        let rows: [[String: Any]]
        if args[0] == "hooks" {
            rows = [["name": args[2], "installed": hooks.contains(args[2]),
                     "file_exists": hooks.contains(args[2]), "config_path": args.last!]]
        } else {
            rows = ["qwen", "muse"].map { id in
                let root = id == "qwen" ? home + "/.qwen" : home + "/.config/muse"
                return ["name": id, "installed": skills.contains(id), "file_exists": skills.contains(id),
                        "skill_path": root + "/skills/tako/SKILL.md"]
            }
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

    @Test func catalogDetectionAndScopedConnect() async throws {
        let base = try home()
        defer { try? FileManager.default.removeItem(at: base) }
        let fake = NativeSetupRunner()
        let before = await SetupAgentService.statuses(baseDir: base.path, runner: { try await fake.run($0) })
        #expect(before.map(\.id) == ["antigravity", "gemini", "claude", "codex", "qwen", "muse"])
        for id in ["qwen", "muse"] {
            #expect(before.first { $0.id == id }?.isDetected == true)
            #expect(before.first { $0.id == id }?.isReady == false)
            #expect(SetupAgentProvider.match(id + " Code")?.rawValue == id)
        }
        let after = await SetupAgentService.connect(ids: ["qwen", "muse"], baseDir: base.path,
                                                   runner: { try await fake.run($0) })
        #expect(after.filter { ["qwen", "muse"].contains($0.id) }.allSatisfy { $0.isReady })
        let commands = await fake.recorded()
        for id in ["qwen", "muse"] {
            let root = SetupAgentService.nativeRoot(id, baseDir: base.path)
            #expect(commands.contains { $0.arguments == ["hooks", "install", id, "--yes", "--json", "--config", root + "/settings.json"] })
            #expect(commands.contains { $0.arguments == ["skills", "install", id, "--yes", "--json", "--skill-path", root + "/skills/tako/SKILL.md"] })
        }
        #expect(commands.allSatisfy { $0.environment["HOME"] == base.path && $0.environment["XDG_CONFIG_HOME"] == nil })
    }

    @Test func failedPostCheckAndMalformedStatusStayUnconfigured() async throws {
        let base = try home()
        defer { try? FileManager.default.removeItem(at: base) }
        for malformed in [false, true] {
            let fake = NativeSetupRunner(installWorks: false, malformed: malformed)
            let statuses = await SetupAgentService.connect(ids: ["qwen", "muse"], baseDir: base.path,
                                                           runner: { try await fake.run($0) })
            #expect(statuses.allSatisfy { !$0.isReady })
            #expect(statuses.filter { ["qwen", "muse"].contains($0.id) }.allSatisfy { !$0.hooksInstalled && $0.detail != nil })
            let commands = await fake.recorded()
            #expect(!commands.contains { $0.arguments.starts(with: ["skills", "install"]) })
        }
    }

    @Test func nativeStatusRejectsFailuresAndWrongScope() throws {
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
        let detected = AgentHooksTool.detectAgents(baseDir: base.path, checkNativeStatus: false)
        #expect(Set(detected.map(\.id)) == ["qwen", "muse"])
        #expect(detected.allSatisfy { !$0.isConfigured })
    }
}
