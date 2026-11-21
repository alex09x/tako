/*
 * tako — Managed dispatcher ownership and native OSC 7501 migration regressions
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

@MainActor
struct AgentHookDispatcherTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func closedSetOwnershipMatchesOnlyAuthenticTakoStatusHooks() {
        // Authentic historical Tako status commands match for the matching agent.
        #expect(AgentHooksTool.isTakoOwnedStatusCommand(
            "/Users/example/.local/bin/tako-hook codex user_prompt_submit",
            agent: "codex"
        ))
        #expect(AgentHooksTool.isTakoOwnedStatusCommand(
            "if command -v tako-hook >/dev/null 2>&1; then tako-hook claude stop; elif [ -x \"$HOME/.local/bin/tako-hook\" ]; then \"$HOME/.local/bin/tako-hook\" claude stop; fi; :",
            agent: "claude"
        ))
        #expect(AgentHooksTool.isTakoOwnedStatusCommand(
            "/usr/bin/python3 '/Applications/Tako.app/Contents/Resources/tako-hook.py' qwen start; :",
            agent: "qwen"
        ))
        #expect(AgentHooksTool.isTakoOwnedStatusCommand(
            "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; fi",
            agent: "claude"
        ))
        #expect(AgentHooksTool.isTakoOwnedStatusCommand(
            "tako-hook agy pre_invocation",
            agent: "antigravity"
        ))

        // Echo, Prod, Rex, wrong-agent, and custom wrapper commands MUST NOT match.
        #expect(!AgentHooksTool.isTakoOwnedStatusCommand("echo tako-hook codex stop", agent: "codex"))
        #expect(!AgentHooksTool.isTakoOwnedStatusCommand("prod hook claude stop", agent: "claude"))
        #expect(!AgentHooksTool.isTakoOwnedStatusCommand("rex-hook claude stop", agent: "claude"))
        #expect(!AgentHooksTool.isTakoOwnedStatusCommand("tako-hook codex stop", agent: "claude"))
        #expect(!AgentHooksTool.isTakoOwnedStatusCommand("tako-hook claude stop && rm -rf /tmp/x", agent: "claude"))
        #expect(!AgentHooksTool.isTakoOwnedStatusCommand("/usr/local/bin/my-tako-hook claude stop", agent: "claude"))
    }

    @Test func surgicalCleanupRemovesLegacyDispatcherHooksAndLeavesNonTakoHooksUntouched() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let codexDir = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codexHooksFile = codexDir.appendingPathComponent("hooks.json")
        let codexSeed: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["matcher": "", "hooks": [["type": "command", "command": "/Users/example/.local/bin/tako-hook codex user_prompt_submit"]]]
                ],
                "Stop": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "/Users/example/.local/bin/tako-hook codex stop"],
                            ["type": "command", "command": "echo tako-hook codex stop"]
                        ]
                    ]
                ],
                "Interrupt": [
                    ["matcher": "", "hooks": [["type": "command", "command": "/Users/example/.local/bin/tako-hook codex interrupt"]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: codexSeed).write(to: codexHooksFile)

        #expect(AgentHooksTool.hasLegacyOwnedStatusHooks(for: "codex", baseDir: root.path))
        #expect(AgentHooksTool.installCodexHooks(baseDir: root.path))
        #expect(!AgentHooksTool.hasLegacyOwnedStatusHooks(for: "codex", baseDir: root.path))

        let cleaned = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: codexHooksFile)) as? [String: Any]
        )
        let hooks = try #require(cleaned["hooks"] as? [String: Any])
        #expect(hooks["UserPromptSubmit"] == nil)
        #expect(hooks["Interrupt"] == nil)
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        let stopEntries = try #require(stopGroups.first?["hooks"] as? [[String: Any]])
        #expect(stopEntries.count == 1)
        #expect(stopEntries.first?["command"] as? String == "echo tako-hook codex stop")
    }

    @Test func cleanDirectoriesNeverCreateNewHookFilesForNative7501Agents() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in [".claude", ".codex", ".gemini/config"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        #expect(AgentHooksTool.installClaudeHooks(baseDir: root.path))
        #expect(AgentHooksTool.installCodexHooks(baseDir: root.path))
        #expect(AgentHooksTool.installAntigravityHooks(baseDir: root.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/hooks.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".gemini/config/hooks.json").path))
    }
}
