/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

@MainActor
enum SetupAgentService {
    struct Status: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let isDetected: Bool
        let hooksInstalled: Bool
        let skillInstalled: Bool
        let detail: String?
        var isReady: Bool { hooksInstalled && skillInstalled }
    }

    struct Command: Sendable {
        let executable: URL?
        let arguments: [String]
        let environment: [String: String]
    }

    struct CommandResult: Sendable {
        var exitCode: Int32 = 0
        var stdout = Data()
        var failure: String? = nil
    }

    typealias Runner = @Sendable (Command) async throws -> CommandResult
    private static let agents = [
        ("antigravity", "Antigravity"), ("gemini", "Gemini CLI"),
        ("claude", "Claude Code"), ("codex", "Codex CLI"),
    ]

    private struct Skill: Decodable {
        let name: String
        let installed: Bool
        let skill_path: String
        let file_exists: Bool
    }

    static func statuses(
        baseDir: String? = nil, executableURL: URL? = nil, runner: Runner = { try await SetupAgentService.run($0) }
    ) async -> [Status] {
        let base = AgentHooksTool.resolvedBaseDir(baseDir)
        let detected = AgentHooksTool.detectAgents(baseDir: base)
        var skills: [String: Skill] = [:]
        var failure: String?
        let result = await execute(
            ["skills", "status", "--json"], baseDir: base, executableURL: executableURL, runner: runner
        )
        if let error = result.failure {
            failure = error
        } else if result.exitCode != 0 {
            failure = "Skill status exited with code \(result.exitCode)."
        } else if let rows = try? JSONDecoder().decode([Skill].self, from: result.stdout),
                  Set(rows.map(\.name)).count == rows.count,
                  rows.allSatisfy({ !$0.skill_path.isEmpty && (!$0.installed || $0.file_exists) }) {
            skills = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        } else {
            failure = "Skill status returned malformed JSON."
        }
        return agents.map { id, name in
            let agent = detected.first { $0.id == id }
            let hooks = agent?.isConfigured ?? false
            let skill = skills[adapter(id)]
            var installed = skill?.installed ?? false
            // Status has no path override and resolves ~/.codex, not CODEX_HOME.
            if id == "codex", let path = customCodexSkill(baseDir: base), skill != nil {
                installed = isSkillInstalled(at: path)
            }
            let detail = failure ?? (skill == nil ? "Skill status omitted this agent." : nil)
                ?? (agent == nil ? "Agent not detected." : nil)
                ?? (!hooks ? "Required Tako hooks are missing." : nil)
                ?? (!installed ? "Tako skill is missing." : nil)
            return Status(id: id, name: name, isDetected: agent != nil,
                          hooksInstalled: hooks, skillInstalled: installed, detail: detail)
        }
    }

    static func connect(
        ids: [String], baseDir: String? = nil, executableURL: URL? = nil, runner: Runner = { try await SetupAgentService.run($0) }
    ) async -> [Status] {
        let base = AgentHooksTool.resolvedBaseDir(baseDir)
        let before = await statuses(baseDir: base, executableURL: executableURL, runner: runner)
        var failures: [String: String] = [:]
        var hookFailures = Set<String>()
        var skillFailures = Set<String>()
        var installedAdapters = Set<String>()
        for agent in before where ids.contains(agent.id) && !agent.isReady {
            guard agent.isDetected else {
                failures[agent.id] = "Agent not detected; no configuration was changed."
                continue
            }
            if !agent.hooksInstalled {
                let report = AgentHooksTool.installHooks(for: [agent.id], baseDir: base, includeSkills: false)
                guard report.failed.isEmpty,
                      AgentHooksTool.detectAgents(baseDir: base).first(where: { $0.id == agent.id })?.isConfigured == true else {
                    failures[agent.id] = "Required Tako hooks could not be installed."
                    hookFailures.insert(agent.id)
                    continue
                }
            }
            let target = adapter(agent.id)
            if !agent.skillInstalled && !installedAdapters.contains(target) {
                var arguments = ["skills", "install", target, "--yes", "--json"]
                if agent.id == "codex", let path = customCodexSkill(baseDir: base) {
                    arguments += ["--skill-path", path]
                }
                let result = await execute(arguments, baseDir: base, executableURL: executableURL, runner: runner)
                if let failure = result.failure {
                    failures[agent.id] = "Skill installation failed: \(failure)"
                    skillFailures.insert(agent.id)
                } else if result.exitCode != 0 {
                    failures[agent.id] = "Skill installation exited with code \(result.exitCode)."
                    skillFailures.insert(agent.id)
                } else {
                    installedAdapters.insert(target)
                }
            }
        }
        let after = await statuses(baseDir: base, executableURL: executableURL, runner: runner)
        return after.map { agent in
            guard let failure = failures[agent.id] else { return agent }
            return Status(id: agent.id, name: agent.name, isDetected: agent.isDetected,
                          hooksInstalled: agent.hooksInstalled && !hookFailures.contains(agent.id),
                          skillInstalled: agent.skillInstalled && !skillFailures.contains(agent.id), detail: failure)
        }
    }

    private static func adapter(_ id: String) -> String { id == "antigravity" ? "gemini" : id }

    private static func customCodexSkill(baseDir: String?) -> String? {
        guard baseDir == nil, let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: home).appendingPathComponent("skills/tako/SKILL.md").path
    }

    private static func isSkillInstalled(at path: String) -> Bool {
        // Match SkillAdapter::is_installed, including its refusal of symlinks/non-files.
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return content.contains("Tako Terminal Integration") || content.contains("name: tako")
    }

    private static func execute(
        _ arguments: [String], baseDir: String?, executableURL: URL?, runner: Runner
    ) async -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        if let baseDir {
            environment["HOME"] = baseDir
            environment.removeValue(forKey: "CODEX_HOME")
        }
        let executable = executableURL ?? Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("takoctl")
        do {
            return try await runner(Command(executable: executable, arguments: arguments, environment: environment))
        } catch {
            // Arbitrary runner errors may contain configuration or credentials.
            return CommandResult(failure: "Unable to launch takoctl.")
        }
    }

    /// File-backed capture avoids pipe backpressure, including inherited descriptors in descendants.
    /// Launch, polling, termination and reaping all run away from the main actor.
    nonisolated static func run(_ command: Command) async throws -> CommandResult {
        await Task.detached(priority: .utility) { runBlocking(command) }.value
    }

    nonisolated private static func runBlocking(_ command: Command) -> CommandResult {
        guard let executable = command.executable,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return CommandResult(failure: "The bundled takoctl executable is missing or not executable.")
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("tako-setup-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: directory) }
            let out = directory.appendingPathComponent("stdout")
            let err = directory.appendingPathComponent("stderr")
            guard fm.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  fm.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return CommandResult(failure: "Unable to prepare takoctl output capture.")
            }
            let output = try FileHandle(forWritingTo: out)
            defer { try? output.close() }
            let errors = try FileHandle(forWritingTo: err)
            defer { try? errors.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = command.arguments
            process.environment = command.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let oversized = {
                [out, err].contains {
                    guard let attributes = try? fm.attributesOfItem(atPath: $0.path),
                          let size = attributes[.size] as? NSNumber else { return false }
                    return size.intValue > 65_536
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var failure: String?
            while process.isRunning {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    failure = "takoctl timed out after 15 seconds."
                } else if oversized() {
                    failure = "takoctl output exceeded the 64 KiB capture limit."
                }
                if failure != nil {
                    process.terminate()
                    let grace = ProcessInfo.processInfo.systemUptime + 0.25
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            process.waitUntilExit()
            let reader = try FileHandle(forReadingFrom: out)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 65_537) ?? Data()
            if oversized() || data.count > 65_536 {
                failure = "takoctl output exceeded the 64 KiB capture limit."
            }
            return CommandResult(exitCode: process.terminationStatus, stdout: Data(data.prefix(65_536)), failure: failure)
        } catch {
            return CommandResult(failure: "Unable to launch takoctl or collect its output.")
        }
    }
}
