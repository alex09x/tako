/*
 * tako — Surgical migration of legacy status hooks to native OSC 7501
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension AgentHooksTool {
    nonisolated static let nativeOsc7501AgentIds: Set<String> = [
        "antigravity", "claude", "codex", "qwen", "muse"
    ]

    nonisolated static func usesNativeOsc7501Status(_ id: String) -> Bool {
        nativeOsc7501AgentIds.contains(id)
    }

    private static let dispatcherEvents: Set<String> = [
        "user_prompt_submit", "start", "working", "pre_invocation",
        "stop", "done", "post_invocation", "permission_request", "approval",
        "question", "waiting_for_input", "ask", "question_answered",
        "post_question", "session_start", "session_end", "post_tool_use",
        "stop_failure", "interrupt"
    ]

    private static let forbiddenWordChars = CharacterSet(charactersIn: ";|&$`'\"<>")

    /// Closed-set recognition of Tako-owned status hook commands across historical releases.
    /// Rejects `echo`, Prod hooks, Rex hooks, and custom user wrappers.
    static func isTakoOwnedStatusCommand(_ command: String, agent: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if isThreeWordDispatcherCall(trimmed, agent: agent) {
            return true
        }
        if isQuotedManagedDispatcher(trimmed, agent: agent) {
            return true
        }
        if isLegacyInlineTakoctlFallback(trimmed) {
            return true
        }
        let prefix = "if command -v tako-hook >/dev/null 2>&1; then "
        if trimmed.hasPrefix(prefix), trimmed.hasSuffix("; fi; :") {
            let inner = String(trimmed.dropFirst(prefix.count).dropLast("; fi; :".count))
            if let elifRange = inner.range(of: "; elif [ -x \"$HOME/.local/bin/tako-hook\" ]; then ") {
                let thenClause = String(inner[..<elifRange.lowerBound])
                let elifClause = String(inner[elifRange.upperBound...])
                return isThreeWordDispatcherCall(thenClause, agent: agent)
                    && isQuotedHomeDispatcher(elifClause, agent: agent)
            }
            if let elseRange = inner.range(of: "; else ") {
                let thenClause = String(inner[..<elseRange.lowerBound])
                var elseClause = String(inner[elseRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if elseClause.hasSuffix("; :") {
                    elseClause = String(elseClause.dropLast(3)).trimmingCharacters(in: .whitespaces)
                }
                if !isThreeWordDispatcherCall(thenClause, agent: agent) {
                    return false
                }
                return isThreeWordDispatcherCall(elseClause, agent: agent)
                    || isQuotedHomeDispatcher(elseClause, agent: agent)
                    || isLegacyInlineTakoctlFallback(elseClause)
            }
        }
        return false
    }

    private static func isThreeWordDispatcherCall(_ clause: String, agent: String) -> Bool {
        let words = clause.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 3,
              words.allSatisfy({ $0.rangeOfCharacter(from: forbiddenWordChars) == nil }) else {
            return false
        }
        let exe = words[0]
        let isDispatcher = (exe as NSString).lastPathComponent == "tako-hook"
            && (exe.hasPrefix("/") || exe == "tako-hook")
        let sameAgent = words[1] == agent || (agent == "antigravity" && words[1] == "agy")
        return isDispatcher && sameAgent && dispatcherEvents.contains(words[2])
    }

    private static func isQuotedHomeDispatcher(_ clause: String, agent: String) -> Bool {
        let prefix = "\"$HOME/.local/bin/tako-hook\" "
        guard clause.hasPrefix(prefix) else { return false }
        let parts = clause.dropFirst(prefix.count).split(whereSeparator: \.isWhitespace).map(String.init)
        let sameAgent = parts.count == 2 && (parts[0] == agent || (agent == "antigravity" && parts[0] == "agy"))
        return sameAgent && dispatcherEvents.contains(parts[1])
    }

    private static func isQuotedManagedDispatcher(_ trimmed: String, agent: String) -> Bool {
        guard trimmed.hasPrefix("/usr/bin/python3 '"), trimmed.hasSuffix("; :") else { return false }
        let body = String(trimmed.dropFirst("/usr/bin/python3 '".count).dropLast("; :".count))
        guard let endQuote = body.range(of: "' ") else { return false }
        let scriptPath = String(body[..<endQuote.lowerBound])
        guard scriptPath.hasSuffix("/Contents/Resources/tako-hook.py") else { return false }
        let tail = body[endQuote.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
        let sameAgent = tail.count == 2 && (tail[0] == agent || (agent == "antigravity" && tail[0] == "agy"))
        return sameAgent && dispatcherEvents.contains(tail[1])
    }

    private static func isLegacyInlineTakoctlFallback(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let guardPrefix = "if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then "
        if trimmed.hasPrefix(guardPrefix) {
            let rest = String(trimmed.dropFirst(guardPrefix.count))
            let validEnd = rest.hasSuffix("; fi; :") || rest.hasSuffix("; fi") || rest.hasSuffix("; fi; echo \"{}\"")
            return validEnd && (
                rest.hasPrefix("takoctl status ")
                    || rest.hasPrefix("takoctl notify \"$CLAUDE_NOTIFICATION\" --title \"Claude Code\"")
            )
        }
        let simplePrefix = "if [ -n \"$TAKO_SOCKET\" ]; then "
        if trimmed.hasPrefix(simplePrefix) {
            let rest = String(trimmed.dropFirst(simplePrefix.count))
            let validEnd = rest.hasSuffix("; fi; :") || rest.hasSuffix("; fi") || rest.hasSuffix("; fi; echo \"{}\"")
            return validEnd && rest.hasPrefix("takoctl status ")
        }
        if trimmed.hasPrefix("[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID")
            && trimmed.contains("takoctl status set ")
            && trimmed.hasSuffix("echo \"{}\"") {
            return true
        }
        return false
    }

    static func configFilePath(for agentId: String, baseDir: String?) -> String? {
        let effectiveBase = resolvedBaseDir(baseDir)
        let home = effectiveBase ?? FileManager.default.homeDirectoryForCurrentUser.path
        switch agentId {
        case "antigravity":
            return (home as NSString).appendingPathComponent(".gemini/config/hooks.json")
        case "claude":
            return (home as NSString).appendingPathComponent(".claude/settings.json")
        case "codex":
            let codexDir: String
            if effectiveBase == nil,
               let envCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
               !envCodexHome.isEmpty {
                codexDir = envCodexHome
            } else {
                codexDir = (home as NSString).appendingPathComponent(".codex")
            }
            return (codexDir as NSString).appendingPathComponent("hooks.json")
        case "qwen", "muse":
            return SetupAgentService.nativeRoot(agentId, baseDir: effectiveBase) + "/settings.json"
        default:
            return nil
        }
    }

    private static func managedReceiptPath(for agentId: String, baseDir: String?) -> String {
        let home = resolvedBaseDir(baseDir) ?? FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".local/share/tako/hooks/\(agentId).json")
    }

    /// Returns `true` when legacy Tako-owned status hooks, receipts, or unreadable/corrupt
    /// hook containers remain on disk for a native-7501 agent.
    static func hasLegacyOwnedStatusHooks(for agentId: String, baseDir: String? = nil) -> Bool {
        guard usesNativeOsc7501Status(agentId),
              let path = configFilePath(for: agentId, baseDir: baseDir) else {
            return false
        }
        let fm = FileManager.default
        if ["qwen", "muse"].contains(agentId),
           fm.fileExists(atPath: managedReceiptPath(for: agentId, baseDir: baseDir)) {
            return true
        }
        let url = URL(fileURLWithPath: path)
        if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            return true
        }
        guard fm.fileExists(atPath: path) else {
            return false
        }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              validateHookContainerStructure(root, agent: agentId) else {
            return true
        }
        let (_, removedAny) = stripOwnedHooks(from: root, agent: agentId)
        return removedAny
    }

    /// Surgically strips only Tako-owned status hooks for a native-7501 agent while preserving
    /// all unrelated user/Prod/Rex hooks and refusing to clobber malformed JSON or symlinks.
    @discardableResult
    static func cleanupLegacyStatusHooks(for agentId: String, baseDir: String? = nil) -> Bool {
        guard usesNativeOsc7501Status(agentId),
              let path = configFilePath(for: agentId, baseDir: baseDir) else {
            return false
        }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), vals.isSymbolicLink == true {
            return false
        }

        if fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: url),
                  let rawJson = try? JSONSerialization.jsonObject(with: data),
                  let root = rawJson as? [String: Any] else {
                return false
            }
            guard validateHookContainerStructure(root, agent: agentId) else {
                return false
            }
            let (cleaned, removedAny) = stripOwnedHooks(from: root, agent: agentId)
            if removedAny {
                let markerPath = path + ".tako-new"
                if cleaned.isEmpty && fm.fileExists(atPath: markerPath) {
                    try? fm.removeItem(atPath: path)
                } else {
                    guard let outData = try? JSONSerialization.data(
                        withJSONObject: cleaned,
                        options: [.prettyPrinted, .sortedKeys]
                    ),
                    (try? outData.write(to: url, options: .atomic)) != nil else {
                        return false
                    }
                }
            }
            try? fm.removeItem(atPath: path + ".tako-bak")
            try? fm.removeItem(atPath: path + ".tako-new")
        }

        if ["qwen", "muse"].contains(agentId) {
            try? fm.removeItem(atPath: managedReceiptPath(for: agentId, baseDir: baseDir))
        }
        return true
    }

    private static func validateHookContainerStructure(_ root: [String: Any], agent: String) -> Bool {
        if agent == "antigravity" {
            if let rawTako = root["tako-status"], !(rawTako is [String: Any]) {
                return false
            }
            return true
        }
        guard let rawHooks = root["hooks"] else { return true }
        guard let hooks = rawHooks as? [String: Any] else { return false }
        for (_, eventVal) in hooks {
            guard let groups = eventVal as? [Any] else { continue }
            for groupItem in groups {
                guard let groupDict = groupItem as? [String: Any] else { return false }
                if let inner = groupDict["hooks"], !(inner is [[String: Any]]) {
                    return false
                }
            }
        }
        return true
    }

    private static func stripOwnedHooks(from root: [String: Any], agent: String) -> ([String: Any], Bool) {
        var updatedRoot = root
        var removedAny = false

        if agent == "antigravity" {
            if var takoStatus = updatedRoot["tako-status"] as? [String: Any] {
                for (key, value) in takoStatus where key != "enabled" {
                    guard let entries = value as? [[String: Any]] else { continue }
                    let kept = entries.filter { item in
                        guard let cmd = item["command"] as? String else { return true }
                        let owned = isTakoOwnedStatusCommand(cmd, agent: "antigravity")
                        if owned { removedAny = true }
                        return !owned
                    }
                    if kept.isEmpty {
                        takoStatus.removeValue(forKey: key)
                    } else {
                        takoStatus[key] = kept
                    }
                }
                let nonEnabledKeys = takoStatus.keys.filter { $0 != "enabled" }
                if nonEnabledKeys.isEmpty {
                    updatedRoot.removeValue(forKey: "tako-status")
                    removedAny = true
                } else {
                    updatedRoot["tako-status"] = takoStatus
                }
            }
            return (updatedRoot, removedAny)
        }

        guard var hooks = updatedRoot["hooks"] as? [String: Any] else {
            return (updatedRoot, false)
        }

        for (eventKey, eventValue) in hooks {
            guard let groups = eventValue as? [[String: Any]] else { continue }
            var keptGroups: [[String: Any]] = []
            for var group in groups {
                if let flatCmd = group["command"] as? String, group["hooks"] == nil {
                    if isTakoOwnedStatusCommand(flatCmd, agent: agent) {
                        removedAny = true
                        continue
                    }
                }
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    let keptHooks = innerHooks.filter { hook in
                        guard let cmd = hook["command"] as? String else { return true }
                        let owned = isTakoOwnedStatusCommand(cmd, agent: agent)
                        if owned { removedAny = true }
                        return !owned
                    }
                    if keptHooks.isEmpty {
                        continue
                    }
                    group["hooks"] = keptHooks
                }
                keptGroups.append(group)
            }
            if keptGroups.isEmpty {
                hooks.removeValue(forKey: eventKey)
            } else {
                hooks[eventKey] = keptGroups
            }
        }

        if hooks.isEmpty {
            updatedRoot.removeValue(forKey: "hooks")
            if ["qwen", "muse"].contains(agent),
               (updatedRoot["allowManagedHooksOnly"] as? Bool) == false {
                updatedRoot.removeValue(forKey: "allowManagedHooksOnly")
            }
        } else {
            updatedRoot["hooks"] = hooks
        }
        return (updatedRoot, removedAny)
    }
}
