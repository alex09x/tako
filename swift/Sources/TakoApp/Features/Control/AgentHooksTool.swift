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

/// Detects installed AI coding agents (Antigravity, Gemini CLI, Claude Code, Codex)
/// and manages installing Tako lifecycle hooks natively with schema validation
/// using Tako's signature in-terminal TUI dialogs (`TerminalDialogView`).
@MainActor
enum AgentHooksTool {
    static let declinedKey = "TakoAgentHooksInstallDeclined"

    struct AgentInfo: Identifiable, Sendable {
        let id: String
        let name: String
        let isDetected: Bool
        let isConfigured: Bool
    }

    struct InstallReport: Sendable {
        var alreadyConfigured: [String] = []
        var newlyInstalled: [String] = []
        var failed: [String] = []
    }

    /// Pure predicate to check if the launch offer should be displayed, respecting test isolation,
    /// CLI flags, environment variables, and user preference.
    static func shouldOfferAtLaunch(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = UserDefaults.tako,
        isTesting: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        guard !isTesting,
              !arguments.contains(where: {
                  $0.hasPrefix("--selftest") ||
                  $0 == "--no-update" ||
                  $0 == "--no-launch-notices"
              }),
              environment["TAKO_NO_UPDATE"] != "1",
              environment["TAKO_NO_LAUNCH_NOTICES"] != "1",
              !userDefaults.bool(forKey: declinedKey) else {
            return false
        }
        return true
    }

    /// Resolves an explicit `baseDir` or the `TAKO_AGENT_HOOKS_HOME` environment override.
    static func resolvedBaseDir(_ baseDir: String?) -> String? {
        if let baseDir, !baseDir.isEmpty { return baseDir }
        if let envHome = ProcessInfo.processInfo.environment["TAKO_AGENT_HOOKS_HOME"], !envHome.isEmpty {
            return envHome
        }
        return nil
    }

    /// Checks which agents exist on the host and whether Tako hooks are configured.
    static func detectAgents(baseDir: String? = nil) -> [AgentInfo] {
        let fm = FileManager.default
        let effectiveBase = resolvedBaseDir(baseDir)
        let home = effectiveBase ?? fm.homeDirectoryForCurrentUser.path

        // Antigravity (agy)
        let agyHooksFile = (home as NSString).appendingPathComponent(".gemini/config/hooks.json")
        let agyInstalled = fm.fileExists(atPath: agyHooksFile) || (effectiveBase == nil && binaryExists("agy"))
        let agyConfigured = isAntigravityConfigured(filePath: agyHooksFile)

        // Gemini CLI
        let geminiSettings = (home as NSString).appendingPathComponent(".gemini/settings.json")
        let geminiInstalled = fm.fileExists(atPath: geminiSettings) || (effectiveBase == nil && binaryExists("gemini"))
        let geminiConfigured = isGeminiConfigured(filePath: geminiSettings)

        // Claude Code
        let claudeDir = (home as NSString).appendingPathComponent(".claude")
        let claudeSettings = (claudeDir as NSString).appendingPathComponent("settings.json")
        let claudeInstalled = fm.fileExists(atPath: claudeDir) || (effectiveBase == nil && binaryExists("claude"))
        let claudeConfigured = isClaudeConfigured(filePath: claudeSettings)

        // Codex CLI
        let codexDir: String
        if effectiveBase == nil, let envCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envCodexHome.isEmpty {
            codexDir = envCodexHome
        } else {
            codexDir = (home as NSString).appendingPathComponent(".codex")
        }
        let codexHooksFile = (codexDir as NSString).appendingPathComponent("hooks.json")
        let codexInstalled = fm.fileExists(atPath: codexDir) || (effectiveBase == nil && binaryExists("codex"))
        let codexConfigured = isCodexConfigured(filePath: codexHooksFile)

        var list: [AgentInfo] = []
        if agyInstalled {
            list.append(AgentInfo(id: "antigravity", name: "Antigravity", isDetected: true, isConfigured: agyConfigured))
        }
        if geminiInstalled {
            list.append(AgentInfo(id: "gemini", name: "Gemini CLI", isDetected: true, isConfigured: geminiConfigured))
        }
        if claudeInstalled {
            list.append(AgentInfo(id: "claude", name: "Claude Code", isDetected: true, isConfigured: claudeConfigured))
        }
        if codexInstalled {
            list.append(AgentInfo(id: "codex", name: "Codex CLI", isDetected: true, isConfigured: codexConfigured))
        }
        return list
    }

    static func isClaudeConfigured(filePath: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let hasPrompt = hasMatcherHook(in: hooks["UserPromptSubmit"], commandKey: "takoctl status set working") ||
                        hasMatcherHook(in: hooks["UserPromptSubmit"], commandKey: "tako-hook claude user_prompt_submit")
        let hasStop = hasMatcherHook(in: hooks["Stop"], commandKey: "takoctl status set idle") ||
                      hasMatcherHook(in: hooks["Stop"], commandKey: "takoctl status set done") ||
                      hasMatcherHook(in: hooks["Stop"], commandKey: "tako-hook claude stop")
        return hasPrompt && hasStop
    }

    static func isCodexConfigured(filePath: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let hasPrompt = hasMatcherHook(in: hooks["UserPromptSubmit"], commandKey: "takoctl status set working --target") ||
                        hasMatcherHook(in: hooks["UserPromptSubmit"], commandKey: "tako-hook codex user_prompt_submit")
        let hasStop = hasMatcherHook(in: hooks["Stop"], commandKey: "takoctl status set done --target") ||
                      hasMatcherHook(in: hooks["Stop"], commandKey: "tako-hook codex stop")
        let hasApproval = hasMatcherHook(in: hooks["PermissionRequest"], commandKey: "takoctl status set needs_approval --target") ||
                          hasMatcherHook(in: hooks["PermissionRequest"], commandKey: "tako-hook codex permission_request")
        return hasPrompt && hasStop && hasApproval
    }

    static func isGeminiConfigured(filePath: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let hasBefore = hasMatcherHook(in: hooks["BeforeAgent"], commandKey: "takoctl status set working")
        let hasAfter = hasMatcherHook(in: hooks["AfterAgent"], commandKey: "takoctl status set idle")
        return hasBefore && hasAfter
    }

    static func isAntigravityConfigured(filePath: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tako = root["tako-status"] as? [String: Any],
              (tako["enabled"] as? Bool) != false else { return false }
        let hasPre = hasDirectHook(in: tako["PreInvocation"], commandKey: "takoctl status set working") ||
                     hasDirectHook(in: tako["PreInvocation"], commandKey: "tako-hook agy pre_invocation")
        let hasStop = hasDirectHook(in: tako["Stop"], commandKey: "takoctl status set idle") ||
                      hasDirectHook(in: tako["Stop"], commandKey: "takoctl status set done") ||
                      hasDirectHook(in: tako["Stop"], commandKey: "tako-hook agy stop")
        return hasPre && hasStop
    }

    private static func hasMatcherHook(in container: Any?, commandKey: String) -> Bool {
        guard let groups = container as? [[String: Any]] else { return false }
        return groups.contains { group in
            if (group["enabled"] as? Bool) == false { return false }
            if let innerHooks = group["hooks"] as? [[String: Any]] {
                return innerHooks.contains { hook in
                    if (hook["enabled"] as? Bool) == false { return false }
                    return commandMatches(hook["command"] as? String, key: commandKey)
                }
            }
            return false
        }
    }

    private static func hasDirectHook(in container: Any?, commandKey: String) -> Bool {
        guard let list = container as? [[String: Any]] else { return false }
        return list.contains { item in
            if (item["enabled"] as? Bool) == false { return false }
            return commandMatches(item["command"] as? String, key: commandKey)
        }
    }

    private static func commandMatches(_ command: String?, key: String) -> Bool {
        guard let command else { return false }
        if !key.hasPrefix("tako-hook ") { return command.contains(key) }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let expected = key.split(separator: " ").map(String.init)
        guard words.count == 3, expected.count == 3,
              (words[0] as NSString).lastPathComponent == "tako-hook" else { return false }
        return Array(words.dropFirst()) == Array(expected.dropFirst())
    }

    private static func binaryExists(_ name: String) -> Bool {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userDirs = [
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent("bin"),
            (home as NSString).appendingPathComponent(".cargo/bin"),
        ]
        return (dirs + userDirs).contains { dir in
            FileManager.default.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }

    /// Install hooks for targeted or all unconfigured agents.
    @discardableResult
    static func installHooks(for agentIds: [String]? = nil, baseDir: String? = nil) -> InstallReport {
        let agents = detectAgents(baseDir: baseDir)
        var report = InstallReport()

        let targets = agentIds.map { ids in
            agents.filter { ids.contains($0.id) }
        } ?? agents

        for agent in targets {
            if agent.isConfigured {
                report.alreadyConfigured.append(agent.name)
                continue
            }
            let success: Bool
            switch agent.id {
            case "antigravity":
                success = installAntigravityHooks(baseDir: baseDir)
            case "gemini":
                success = installGeminiHooks(baseDir: baseDir)
            case "claude":
                success = installClaudeHooks(baseDir: baseDir)
            case "codex":
                success = installCodexHooks(baseDir: baseDir)
            default:
                success = false
            }

            // Validate that the required active hooks are ACTUALLY configured after install
            let postCheck = detectAgents(baseDir: baseDir)
            let isNowConfigured = postCheck.first(where: { $0.id == agent.id })?.isConfigured ?? false

            if success && isNowConfigured {
                report.newlyInstalled.append(agent.name)
            } else {
                report.failed.append(agent.name)
            }
        }
        return report
    }

    /// At launch: offers to connect detected AI coding agents if any are unconfigured
    /// using Tako's signature in-terminal TUI dialog (`TerminalDialogView`).
    static func offerAtLaunch(
        theme: TerminalTheme?,
        attempt: Int = 0,
        baseDir: String? = nil,
        userDefaults: UserDefaults = UserDefaults.tako
    ) {
        guard shouldOfferAtLaunch(userDefaults: userDefaults) else { return }
        guard attempt < 10 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 1.5 : 0.4)) {
            guard shouldOfferAtLaunch(userDefaults: userDefaults) else { return }
            guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) else {
                offerAtLaunch(theme: theme, attempt: attempt + 1, baseDir: baseDir, userDefaults: userDefaults)
                return
            }

            // Never present over an existing modal, sheet, or pending dialog
            guard window.attachedSheet == nil,
                  TerminalDialogView.pending(in: window) == nil else { return }

            let agents = detectAgents(baseDir: baseDir)
            let unconfigured = agents.filter { !$0.isConfigured }
            guard !unconfigured.isEmpty else { return }

            let names = unconfigured.map(\.name).joined(separator: ", ")
            let bodyText = "Tako detected installed coding agents (\(names)). Connect them now so their lifecycle status (idle, thinking, tool running) is displayed in your tab bar?"

            Task { @MainActor in
                let answer = await TerminalDialogView.choose(
                    in: window,
                    title: "Connect AI Agents",
                    lines: TUIText.plain(bodyText, width: 56),
                    choices: [
                        .init(title: "Not Now", kind: .normal),
                        .init(title: "Don't Ask Again", kind: .normal),
                        .init(title: "Connect", kind: .primary)
                    ],
                    selected: 0,
                    cancelIndex: 0,
                    theme: theme
                )

                guard shouldOfferAtLaunch(userDefaults: userDefaults) else { return }
                switch answer {
                case 2: // Connect
                    let reportData = installHooks(for: unconfigured.map(\.id), baseDir: baseDir)
                    var summary: [String] = []
                    if !reportData.newlyInstalled.isEmpty {
                        summary.append("Connected: " + reportData.newlyInstalled.joined(separator: ", "))
                    }
                    if !reportData.alreadyConfigured.isEmpty {
                        summary.append("Already connected: " + reportData.alreadyConfigured.joined(separator: ", "))
                    }
                    if !reportData.failed.isEmpty {
                        summary.append("Failed to configure: " + reportData.failed.joined(separator: ", "))
                    }

                    let title = reportData.failed.isEmpty ? "AI Agents Connected" : "AI Agent Connection Results"
                    let resultBody = summary.joined(separator: "\n") + "\n\nLifecycle status dots will now reflect agent state in Tako tabs."
                    report(in: window, title: title, text: resultBody, theme: theme)
                case 1: // Don't Ask Again
                    userDefaults.set(true, forKey: declinedKey)
                default: // Not Now / cancel
                    break
                }
            }
        }
    }

    /// Invoked from the application menu (Help > Connect AI Agents...).
    static func installFromMenu(theme: TerminalTheme?) {
        guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) else { return }
        let agents = detectAgents()
        guard !agents.isEmpty else {
            report(in: window, title: "No AI Agents Found",
                   text: "Neither Antigravity, Gemini CLI, Claude Code, nor Codex CLI was detected on your system.", theme: theme)
            return
        }
        let reportData = installHooks()

        if reportData.newlyInstalled.isEmpty && reportData.failed.isEmpty {
            report(in: window, title: "AI Agents Already Connected",
                   text: "All detected agents (\(reportData.alreadyConfigured.joined(separator: ", "))) are already configured with Tako hooks.", theme: theme)
            return
        }

        var lines: [String] = []
        if !reportData.newlyInstalled.isEmpty {
            lines.append("Configured hooks for: " + reportData.newlyInstalled.joined(separator: ", "))
        }
        if !reportData.alreadyConfigured.isEmpty {
            lines.append("Already configured: " + reportData.alreadyConfigured.joined(separator: ", "))
        }
        if !reportData.failed.isEmpty {
            lines.append("Failed to configure: " + reportData.failed.joined(separator: ", "))
        }

        let title = reportData.failed.isEmpty ? "AI Agents Connected" : "AI Agent Connection Results"
        report(in: window, title: title, text: lines.joined(separator: "\n"), theme: theme)
    }

    private static func report(in window: NSWindow?, title: String, text: String, theme: TerminalTheme?) {
        guard let window else { return }
        Task { @MainActor in
            _ = await TerminalDialogView.choose(
                in: window,
                title: title,
                lines: TUIText.plain(text, width: 56),
                choices: [.init(title: "OK", kind: .primary)],
                selected: 0,
                cancelIndex: 0,
                theme: theme
            )
        }
    }
}
