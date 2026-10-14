/*
 * tako — Managed dispatcher detection and installer safety regressions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@MainActor
struct AgentHookDispatcherTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func nativeInstallersNeverEvaluateEnvironmentOrStripGrant() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentHooksTool.installClaudeHooks(baseDir: root.path))
        #expect(AgentHooksTool.installCodexHooks(baseDir: root.path))
        #expect(AgentHooksTool.installAntigravityHooks(baseDir: root.path))
        for relative in [".claude/settings.json", ".codex/hooks.json", ".gemini/config/hooks.json"] {
            let contents = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            #expect(!contents.contains("eval $("))
            #expect(!contents.contains("unset TAKO_CONTROL_TOKEN"))
            #expect(!contents.contains("ps eww"))
        }
    }

    @Test func recognizesOnlyActiveDispatcherInvocations() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hooks.json")
        func group(_ command: String) -> [[String: Any]] {
            [["matcher": "", "hooks": [["type": "command", "command": command]]]]
        }
        var hooks: [String: Any] = [
            "UserPromptSubmit": group("/Users/example/.local/bin/tako-hook codex user_prompt_submit"),
            "Stop": group("/Users/example/.local/bin/tako-hook codex stop"),
            "PermissionRequest": group("/Users/example/.local/bin/tako-hook codex permission_request")]
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: file)
        #expect(AgentHooksTool.isCodexConfigured(filePath: file.path))
        hooks["Stop"] = group("echo tako-hook codex stop")
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: file)
        #expect(!AgentHooksTool.isCodexConfigured(filePath: file.path))
        hooks["Stop"] = [["enabled": false, "matcher": "", "hooks": [[
            "type": "command", "command": "tako-hook codex stop"]]]]
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: file)
        #expect(!AgentHooksTool.isCodexConfigured(filePath: file.path))
    }

    @Test func questionAnswerResumesWorkingOnlyForQuestionTool() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentHooksTool.installClaudeHooks(baseDir: root.path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".claude/settings.json")))
        let settings = try #require(json as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let groups = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(groups[0]["matcher"] as? String == "AskUserQuestion")
        let entries = try #require(groups[0]["hooks"] as? [[String: Any]])
        let command = try #require(entries[0]["command"] as? String)
        #expect(command.contains("status set working"))
        #expect(command.contains("progress indeterminate"))
    }

    @Test func disabledQuestionAnswerHookIsNotReenabled() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        let bytes = Data(#"{"hooks":{"PostToolUse":[{"matcher":"AskUserQuestion","enabled":false,"hooks":[{"type":"command","command":"takoctl status set working"}]}]}}"#.utf8)
        try bytes.write(to: file)
        #expect(!AgentHooksTool.installClaudeHooks(baseDir: root.path))
        #expect(try Data(contentsOf: file) == bytes)
    }
}
