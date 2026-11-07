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

    private static let forbiddenWordChars = CharacterSet(charactersIn: ";|&$`'\"<>")

    /// Closed-set recognition of Tako-owned status hook commands across historical releases.
    /// Rejects `echo`, Prod hooks, Rex hooks, and custom/edited user commands.
    static func isTakoOwnedStatusCommand(
        _ command: String,
        agent: String,
        extraExactCommands: Set<String> = []
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if extraExactCommands.contains(command) || extraExactCommands.contains(trimmed) {
            return true
        }
        let body = trimmed.hasPrefix(legacyTokenPreamble)
            ? String(trimmed.dropFirst(legacyTokenPreamble.count))
            : trimmed

        if isThreeWordDispatcherCall(body, agent: agent)
            || isQuotedManagedDispatcher(body, agent: agent)
            || isLegacyInlineTakoctlFallback(body) {
            return true
        }
        let prefix = "if command -v tako-hook >/dev/null 2>&1; then "
        if body.hasPrefix(prefix), body.hasSuffix("; fi; :") {
            let inner = String(body.dropFirst(prefix.count).dropLast("; fi; :".count))
            if let elifRange = inner.range(of: "; elif [ -x \"$HOME/.local/bin/tako-hook\" ]; then ") {
                let thenClause = String(inner[..<elifRange.lowerBound])
                let elifClause = String(inner[elifRange.upperBound...])
                return isThreeWordDispatcherCall(thenClause, agent: agent)
                    && isQuotedHomeDispatcher(elifClause, agent: agent)
            }
            if let elseRange = inner.range(of: "; else ") {
                let thenClause = String(inner[..<elseRange.lowerBound])
                let rawElse = String(inner[elseRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard isThreeWordDispatcherCall(thenClause, agent: agent) else { return false }
                if isThreeWordDispatcherCall(rawElse, agent: agent)
                    || isQuotedHomeDispatcher(rawElse, agent: agent)
                    || isLegacyInlineTakoctlFallback(rawElse) {
                    return true
                }
                if rawElse.hasSuffix("; :") {
                    let stripped = String(rawElse.dropLast(3)).trimmingCharacters(in: .whitespaces)
                    return isThreeWordDispatcherCall(stripped, agent: agent)
                        || isQuotedHomeDispatcher(stripped, agent: agent)
                        || isLegacyInlineTakoctlFallback(stripped)
                }
                return false
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
        return isDispatcher && sameAgent && legacyDispatcherEvents.contains(words[2])
    }

    private static func isQuotedHomeDispatcher(_ clause: String, agent: String) -> Bool {
        let prefix = "\"$HOME/.local/bin/tako-hook\" "
        guard clause.hasPrefix(prefix) else { return false }
        let parts = clause.dropFirst(prefix.count).split(whereSeparator: \.isWhitespace).map(String.init)
        let sameAgent = parts.count == 2 && (parts[0] == agent || (agent == "antigravity" && parts[0] == "agy"))
        return sameAgent && legacyDispatcherEvents.contains(parts[1])
    }

    private static func isQuotedManagedDispatcher(_ body: String, agent: String) -> Bool {
        let afterPython: String
        if body.hasPrefix("PATH='") {
            let afterPath = String(body.dropFirst("PATH='".count))
            guard let sep = afterPath.range(of: "':\"$PATH\" /usr/bin/python3 '") else { return false }
            let macosDir = String(afterPath[..<sep.lowerBound]).replacingOccurrences(of: "'\\''", with: "'")
            guard macosDir.hasPrefix("/"), (macosDir as NSString).lastPathComponent == "MacOS" else {
                return false
            }
            afterPython = String(afterPath[sep.upperBound...])
        } else if body.hasPrefix("/usr/bin/python3 '") {
            afterPython = String(body.dropFirst("/usr/bin/python3 '".count))
        } else {
            return false
        }
        guard afterPython.hasSuffix("; :") else { return false }
        let withoutEnd = String(afterPython.dropLast("; :".count))
        guard let endQuote = withoutEnd.range(of: "' ", options: .backwards) else { return false }
        let scriptPath = String(withoutEnd[..<endQuote.lowerBound]).replacingOccurrences(of: "'\\''", with: "'")
        guard scriptPath.hasPrefix("/"), scriptPath.hasSuffix("/Contents/Resources/tako-hook.py") else {
            return false
        }
        let tail = withoutEnd[endQuote.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
        let sameAgent = tail.count == 2 && (tail[0] == agent || (agent == "antigravity" && tail[0] == "agy"))
        return sameAgent && legacyDispatcherEvents.contains(tail[1])
    }

    private static func isLegacyInlineTakoctlFallback(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix(legacyTokenPreamble)
            ? String(trimmed.dropFirst(legacyTokenPreamble.count))
            : trimmed
        return legacyInlineTakoctlTemplates.contains(body)
    }

    static func configFilePath(for agentId: String, baseDir: String?) -> String? {
        let effectiveBase = resolvedBaseDir(baseDir)
        let home = effectiveBase ?? FileManager.default.homeDirectoryForCurrentUser.path
        switch agentId {
        case "antigravity": return (home as NSString).appendingPathComponent(".gemini/config/hooks.json")
        case "claude": return (home as NSString).appendingPathComponent(".claude/settings.json")
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
        default: return nil
        }
    }

    static func hasLegacyOwnedStatusHooks(for agentId: String, baseDir: String? = nil) -> Bool {
        guard usesNativeOsc7501Status(agentId),
              let path = configFilePath(for: agentId, baseDir: baseDir) else { return false }
        let fm = FileManager.default
        if isSymbolicLink(atPath: path) { return true }
        if ["qwen", "muse"].contains(agentId) {
            if let sidecar = sidecarReceiptPath(for: agentId, settingsPath: path),
               isSymbolicLink(atPath: sidecar) || fm.fileExists(atPath: sidecar) {
                return true
            }
            if fm.fileExists(atPath: legacyShareReceiptPath(for: agentId, baseDir: baseDir)) {
                return true
            }
        }
        guard fm.fileExists(atPath: path) else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              validateHookContainerStructure(root, agent: agentId) else {
            return true
        }
        if agentId == "muse" {
            guard validateMuseSettings(root) else { return true }
            if let managedPath = resolveMuseManagedHooksPath(settings: root, settingsPath: path, receipt: nil) {
                if isSymbolicLink(atPath: managedPath) { return true }
                if fm.fileExists(atPath: managedPath) {
                    guard let mData = try? Data(contentsOf: URL(fileURLWithPath: managedPath)),
                          let mRoot = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
                          validateHookContainerStructure(mRoot, agent: "muse") else {
                        return true
                    }
                    if stripOwnedHooks(from: mRoot, agent: "muse").1 { return true }
                }
            }
        }
        return stripOwnedHooks(from: root, agent: agentId).1
    }

    @discardableResult
    static func cleanupLegacyStatusHooks(
        for agentId: String,
        baseDir: String? = nil,
        executableURL: URL? = nil
    ) -> Bool {
        guard usesNativeOsc7501Status(agentId),
              let path = configFilePath(for: agentId, baseDir: baseDir) else { return false }
        if let cliResult = runTakoctlHookCleanupIfAvailable(
            agentId: agentId, configPath: path, baseDir: baseDir, executableURL: executableURL
        ) {
            if cliResult, ["qwen", "muse"].contains(agentId) {
                try? FileManager.default.removeItem(atPath: legacyShareReceiptPath(for: agentId, baseDir: baseDir))
            }
            return cliResult
        }
        if agentId == "muse" {
            return cleanupMuseLegacyHooks(settingsPath: path, baseDir: baseDir)
        }
        return cleanupSingleFileLegacyHooks(agentId: agentId, path: path, baseDir: baseDir)
    }

    private static func cleanupSingleFileLegacyHooks(agentId: String, path: String, baseDir: String?) -> Bool {
        let fm = FileManager.default
        if isSymbolicLink(atPath: path)
            || isSymbolicLink(atPath: path + ".tako-bak")
            || isSymbolicLink(atPath: path + ".tako-new") { return false }
        var extraCommands: Set<String> = []
        var receiptAddedDisableFalse = false
        if let sidecar = sidecarReceiptPath(for: agentId, settingsPath: path) {
            if isSymbolicLink(atPath: sidecar) { return false }
            if fm.fileExists(atPath: sidecar) {
                guard let rData = try? Data(contentsOf: URL(fileURLWithPath: sidecar)),
                      let rJson = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] else {
                    return false
                }
                extraCommands = extractReceiptOwnedCommands(from: rJson)
                receiptAddedDisableFalse = (rJson["added_disable_false"] as? Bool) == true
            }
        }
        if fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  validateHookContainerStructure(root, agent: agentId) else { return false }
            var (cleaned, removedAny) = stripOwnedHooks(from: root, agent: agentId, extraExactCommands: extraCommands)
            if receiptAddedDisableFalse, (cleaned["disableAllHooks"] as? Bool) == false {
                cleaned.removeValue(forKey: "disableAllHooks")
                removedAny = true
            }
            if removedAny {
                let markerPath = path + ".tako-new"
                if cleaned.isEmpty && fm.fileExists(atPath: markerPath) {
                    try? fm.removeItem(atPath: path)
                } else if !writeAtomically(cleaned, toPath: path) {
                    return false
                }
            }
            try? fm.removeItem(atPath: path + ".tako-bak")
            try? fm.removeItem(atPath: path + ".tako-new")
        }
        if let sidecar = sidecarReceiptPath(for: agentId, settingsPath: path) {
            try? fm.removeItem(atPath: sidecar)
        }
        if agentId == "qwen" {
            try? fm.removeItem(atPath: legacyShareReceiptPath(for: agentId, baseDir: baseDir))
        }
        return true
    }

    static func validateHookContainerStructure(_ root: [String: Any], agent: String) -> Bool {
        if agent == "antigravity" {
            return root["tako-status"] == nil || root["tako-status"] is [String: Any]
        }
        guard let rawHooks = root["hooks"] else { return true }
        guard let hooks = rawHooks as? [String: Any] else { return false }
        for (_, eventVal) in hooks {
            guard let groups = eventVal as? [Any] else { return false }
            for groupItem in groups {
                guard let groupDict = groupItem as? [String: Any] else { return false }
                if let inner = groupDict["hooks"], !(inner is [[String: Any]]) { return false }
            }
        }
        return true
    }

    static func stripOwnedHooks(
        from root: [String: Any],
        agent: String,
        extraExactCommands: Set<String> = []
    ) -> ([String: Any], Bool) {
        var updatedRoot = root
        var removedAny = false
        if agent == "antigravity" {
            if var takoStatus = updatedRoot["tako-status"] as? [String: Any] {
                for (key, value) in takoStatus where key != "enabled" {
                    guard let entries = value as? [[String: Any]] else { continue }
                    let kept = entries.filter { item in
                        guard let cmd = item["command"] as? String else { return true }
                        let owned = isTakoOwnedStatusCommand(cmd, agent: "antigravity", extraExactCommands: extraExactCommands)
                        if owned { removedAny = true }
                        return !owned
                    }
                    if kept.isEmpty { takoStatus.removeValue(forKey: key) } else { takoStatus[key] = kept }
                }
                if takoStatus.keys.allSatisfy({ $0 == "enabled" }) {
                    updatedRoot.removeValue(forKey: "tako-status")
                    removedAny = true
                } else {
                    updatedRoot["tako-status"] = takoStatus
                }
            }
            return (updatedRoot, removedAny)
        }
        guard var hooks = updatedRoot["hooks"] as? [String: Any] else { return (updatedRoot, false) }
        for (eventKey, eventValue) in hooks {
            guard let groups = eventValue as? [[String: Any]] else { continue }
            var keptGroups: [[String: Any]] = []
            for var group in groups {
                if let flatCmd = group["command"] as? String, group["hooks"] == nil,
                   isTakoOwnedStatusCommand(flatCmd, agent: agent, extraExactCommands: extraExactCommands) {
                    removedAny = true
                    continue
                }
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    let keptHooks = innerHooks.filter { hook in
                        guard let cmd = hook["command"] as? String else { return true }
                        let owned = isTakoOwnedStatusCommand(cmd, agent: agent, extraExactCommands: extraExactCommands)
                        if owned { removedAny = true }
                        return !owned
                    }
                    if keptHooks.isEmpty { continue }
                    group["hooks"] = keptHooks
                }
                keptGroups.append(group)
            }
            if keptGroups.isEmpty { hooks.removeValue(forKey: eventKey) } else { hooks[eventKey] = keptGroups }
        }
        if hooks.isEmpty {
            updatedRoot.removeValue(forKey: "hooks")
            if ["qwen", "muse"].contains(agent) {
                if (updatedRoot["allowManagedHooksOnly"] as? Bool) == false {
                    updatedRoot.removeValue(forKey: "allowManagedHooksOnly")
                }
                if (updatedRoot["disableAllHooks"] as? Bool) == false {
                    updatedRoot.removeValue(forKey: "disableAllHooks")
                }
            }
        } else {
            updatedRoot["hooks"] = hooks
        }
        return (updatedRoot, removedAny)
    }

    static func writeAtomically(_ object: [String: Any], toPath path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
