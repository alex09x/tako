/*
 * tako — Native agent setup adapters
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension SetupAgentService {
    static func nativeExecutableExists(_ id: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        (environment["PATH"] ?? "").split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(atPath: (String(directory) as NSString).appendingPathComponent(id))
        }
    }

    static func nativeRoot(_ id: String, baseDir: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = baseDir ?? FileManager.default.homeDirectoryForCurrentUser.path
        if id == "qwen" { return (home as NSString).appendingPathComponent(".qwen") }
        if baseDir == nil, let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return (xdg as NSString).appendingPathComponent("muse")
        }
        return (home as NSString).appendingPathComponent(".config/muse")
    }

    static func nativeHookArguments(_ action: String, id: String, baseDir: String?) -> [String] {
        var arguments = ["hooks", action, id]
        if action == "install" { arguments.append("--yes") }
        arguments += ["--json", "--config", nativeRoot(id, baseDir: baseDir) + "/settings.json"]
        return arguments
    }

    private struct HookStatus: Decodable {
        let name: String
        let installed: Bool
        let file_exists: Bool
        let config_path: String
    }

    static func nativeHooksInstalled(_ result: CommandResult, id: String, baseDir: String?) -> Bool {
        guard result.failure == nil, result.exitCode == 0,
              let rows = try? JSONDecoder().decode([HookStatus].self, from: result.stdout),
              rows.filter({ $0.name == id }).count == 1,
              let row = rows.first(where: { $0.name == id }) else { return false }
        return row.installed && row.file_exists
            && row.config_path == nativeRoot(id, baseDir: baseDir) + "/settings.json"
    }

    private static func nativeCommand(_ action: String, id: String, baseDir: String?) -> Command {
        var environment = ProcessInfo.processInfo.environment
        if let baseDir {
            environment["HOME"] = baseDir
            environment.removeValue(forKey: "CODEX_HOME")
            environment.removeValue(forKey: "XDG_CONFIG_HOME")
        }
        let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("takoctl")
        return Command(executable: executable, arguments: nativeHookArguments(action, id: id, baseDir: baseDir),
                       environment: environment)
    }

    static func nativeHookStatus(_ id: String, baseDir: String?) -> Bool {
        !AgentHooksTool.hasLegacyOwnedStatusHooks(for: id, baseDir: baseDir)
    }

    static func installNativeHooks(_ id: String, baseDir: String?) -> Bool {
        AgentHooksTool.cleanupLegacyStatusHooks(for: id, baseDir: baseDir)
    }

    static func installNativeSkill(_ id: String, baseDir: String?) {
        let command = nativeCommand("status", id: id, baseDir: baseDir)
        _ = runBlocking(Command(executable: command.executable,
                                arguments: ["skills", "install", id, "--yes", "--skill-path",
                                            nativeRoot(id, baseDir: baseDir) + "/skills/tako/SKILL.md"],
                                environment: command.environment))
    }
}
