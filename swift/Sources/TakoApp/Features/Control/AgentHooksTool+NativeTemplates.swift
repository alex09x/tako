/*
 * tako — Closed-set legacy status hook templates and 507 receipt helpers
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension AgentHooksTool {
    static let legacyTokenPreamble = "tako_hook_token=\"${TAKO_CONTROL_TOKEN-${TAKO_AUTH_TOKEN-}}\"; case \"$tako_hook_token\" in *[!0-9a-f]*) tako_hook_token=\"\";; esac; "

    static let legacyDispatcherEvents: Set<String> = [
        "user_prompt_submit", "start", "working", "pre_invocation",
        "stop", "done", "post_invocation", "permission_request", "approval",
        "question", "waiting_for_input", "ask", "question_answered",
        "post_question", "session_start", "session_end", "post_tool_use",
        "stop_failure", "interrupt"
    ]

    /// Exact literal closed set of historical inline `takoctl` hook bodies emitted by
    /// `AgentHooksTool` and `takoctl/adapters/*.json` prior to `OSC 7501`.
    static let legacyInlineTakoctlTemplates: Set<String> = [
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1 || true; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1 || true; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set idle --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set needs_approval --target "$TAKO_SURFACE_ID" --text "Approval requested" >/dev/null 2>&1 || true; takoctl progress pause --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set needs_approval --target "$TAKO_SURFACE_ID" --text "Approval requested" >/dev/null 2>&1 || true; takoctl progress pause --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set waiting_for_input --target "$TAKO_SURFACE_ID" --text "Question" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set waiting_for_input --target "$TAKO_SURFACE_ID" --text "Question" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl notify "$CLAUDE_NOTIFICATION" --title "Claude Code" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
        "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi; echo \"{}\"",
        "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ] && [ \"${#tako_hook_token}\" -eq 64 ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi; echo \"{}\"",
        "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi; echo \"{}\"",
        "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ] && [ \"${#tako_hook_token}\" -eq 64 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi; echo \"{}\"",
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi"#,
        #"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; fi"#,
        #"if [ -n "$TAKO_SOCKET" ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1 || true; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ]; then takoctl status set idle --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
        #"if [ -n "$TAKO_SOCKET" ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"#,
        #"if [ -n "$TAKO_SOCKET" ]; then takoctl status set done >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi"#,
        #"if [ -n "$TAKO_SOCKET" ]; then takoctl status set working; fi"#,
        #"takoctl status set working --text "Thinking..." && takoctl progress indeterminate"#,
        #"takoctl status clear && takoctl progress clear"#,
        #"takoctl status set done --text "Turn complete" && takoctl notify "Claude finished turn" --title "Claude Code" && takoctl progress clear"#,
        #"takoctl status set needs_approval --text "Approval requested" && takoctl notify "Claude requested tool approval" --title "Claude Approval" && takoctl progress pause"#,
        #"takoctl status set done --text "Done" && takoctl notify "Codex completed turn" --title "Codex" && takoctl progress clear"#,
        #"takoctl status set needs_approval --text "Approval requested" && takoctl notify "Codex requested approval" --title "Approval Needed" && takoctl progress pause"#,
        #"takoctl status set waiting_for_input --text "Waiting for input" && takoctl notify "Codex waiting for input" --title "Input Needed" && takoctl progress clear"#,
        #"takoctl status set done --text "Done" && takoctl notify "Antigravity completed task" --title "Task Complete" && takoctl progress clear"#,
        #"takoctl status set needs_approval --text "Approval requested" && takoctl notify "Antigravity requested tool approval" --title "Approval Required" && takoctl progress pause"#,
        #"takoctl status set waiting_for_input --text "Waiting for input" && takoctl notify "Antigravity waiting for input" --title "Input Needed" && takoctl progress clear"#
    ]

    static func sidecarReceiptPath(for agentId: String, settingsPath: String) -> String? {
        switch agentId {
        case "qwen": return settingsPath + ".tako-qwen-receipt"
        case "muse": return settingsPath + ".tako-muse-receipt"
        default: return nil
        }
    }

    static func legacyShareReceiptPath(for agentId: String, baseDir: String?) -> String {
        let home = resolvedBaseDir(baseDir) ?? FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".local/share/tako/hooks/\(agentId).json")
    }

    static func extractReceiptOwnedCommands(from receiptJSON: [String: Any]) -> Set<String> {
        let mapObj = (receiptJSON["dispatcher_hooks"] as? [String: Any]) ?? receiptJSON
        var commands: Set<String> = []
        for (_, val) in mapObj {
            guard let groups = val as? [[String: Any]] else { continue }
            for group in groups {
                if let inner = group["hooks"] as? [[String: Any]] {
                    for h in inner {
                        if let cmd = h["command"] as? String { commands.insert(cmd) }
                    }
                } else if let cmd = group["command"] as? String {
                    commands.insert(cmd)
                }
            }
        }
        return commands
    }

    static func resolveMuseManagedHooksPath(
        settings: [String: Any],
        settingsPath: String,
        receipt: [String: Any]?
    ) -> String? {
        if let receiptPath = receipt?["managed_path"] as? String, receiptPath.hasPrefix("/") {
            return receiptPath
        }
        if let raw = settings["managed_hooks_path"] as? String {
            guard !raw.isEmpty else { return nil }
            if raw.hasPrefix("/") { return raw }
            let dir = (settingsPath as NSString).deletingLastPathComponent
            return (dir as NSString).appendingPathComponent(raw)
        }
        let dir = (settingsPath as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("tako-managed-hooks.json")
    }

    static func isSymbolicLink(atPath path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    static func runTakoctlHookCleanupIfAvailable(
        agentId: String,
        configPath: String,
        baseDir: String?,
        executableURL: URL?
    ) -> Bool? {
        let candidate = executableURL
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("takoctl")
        guard let url = candidate, FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["hooks", "uninstall", agentId, "--yes", "--json", "--config", configPath]
        var env = ProcessInfo.processInfo.environment
        if let baseDir {
            env["HOME"] = baseDir
            env.removeValue(forKey: "CODEX_HOME")
            env.removeValue(forKey: "XDG_CONFIG_HOME")
        }
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return nil
        }
    }

    static func cleanupMuseLegacyHooks(settingsPath: String, baseDir: String?) -> Bool {
        let fm = FileManager.default
        let sidecar = settingsPath + ".tako-muse-receipt"
        if isSymbolicLink(atPath: settingsPath) || isSymbolicLink(atPath: sidecar)
            || isSymbolicLink(atPath: settingsPath + ".tako-bak") { return false }
        var receipt: [String: Any]?
        if fm.fileExists(atPath: sidecar) {
            guard let rData = try? Data(contentsOf: URL(fileURLWithPath: sidecar)),
                  let rJson = try? JSONSerialization.jsonObject(with: rData) as? [String: Any],
                  (rJson["version"] as? Int) == 1 else { return false }
            receipt = rJson
        }
        var settings: [String: Any] = [:]
        let settingsExisted = fm.fileExists(atPath: settingsPath)
        if settingsExisted {
            guard let sData = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
                  let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                  validateMuseSettings(sJson),
                  validateHookContainerStructure(sJson, agent: "muse") else { return false }
            settings = sJson
        }
        guard let managedPath = resolveMuseManagedHooksPath(
            settings: settings, settingsPath: settingsPath, receipt: receipt
        ), managedPath != settingsPath, !isSymbolicLink(atPath: managedPath) else { return false }
        let extra = receipt.map(extractReceiptOwnedCommands(from:)) ?? []
        var managedEmptyAfter = !fm.fileExists(atPath: managedPath)
        if fm.fileExists(atPath: managedPath) {
            guard let mData = try? Data(contentsOf: URL(fileURLWithPath: managedPath)),
                  let mJson = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
                  validateHookContainerStructure(mJson, agent: "muse") else { return false }
            let (cleanedManaged, removedManaged) = stripOwnedHooks(from: mJson, agent: "muse", extraExactCommands: extra)
            managedEmptyAfter = cleanedManaged.isEmpty
            if removedManaged, !writeAtomically(cleanedManaged, toPath: managedPath) { return false }
        }
        var settingsChanged = false
        let stripInline = stripOwnedHooks(from: settings, agent: "muse", extraExactCommands: extra)
        if stripInline.1 { settings = stripInline.0; settingsChanged = true }
        if receipt != nil || (managedEmptyAfter && (settings["managed_hooks_path"] as? String) == "tako-managed-hooks.json") {
            let addedEnv = Set((receipt?["added_env"] as? [String]) ?? ["TAKO_SURFACE_ID", "TAKO_SOCKET"])
            if var env = settings["managed_hooks_env_vars"] as? [String] {
                let beforeCount = env.count
                env.removeAll { addedEnv.contains($0) }
                if env.count != beforeCount {
                    settingsChanged = true
                    if env.isEmpty && ((receipt?["env_added"] as? Bool) ?? true) {
                        settings.removeValue(forKey: "managed_hooks_env_vars")
                    } else {
                        settings["managed_hooks_env_vars"] = env
                    }
                }
            }
            if ((receipt?["pointer_added"] as? Bool) ?? true),
               (settings["managed_hooks_path"] as? String) == "tako-managed-hooks.json",
               managedEmptyAfter {
                settings.removeValue(forKey: "managed_hooks_path")
                settingsChanged = true
            }
            if ((receipt?["schema_added"] as? Bool) ?? true),
               (settings["schema_version"] as? Int) == 1,
               settings["managed_hooks_path"] == nil {
                settings.removeValue(forKey: "schema_version")
                settingsChanged = true
            }
        }
        if settingsExisted && settingsChanged, !writeAtomically(settings, toPath: settingsPath) { return false }
        if managedEmptyAfter,
           (managedPath as NSString).lastPathComponent == "tako-managed-hooks.json",
           settings["managed_hooks_path"] == nil {
            try? fm.removeItem(atPath: managedPath)
            try? fm.removeItem(atPath: managedPath + ".tako-bak")
        }
        try? fm.removeItem(atPath: sidecar)
        try? fm.removeItem(atPath: settingsPath + ".tako-bak")
        try? fm.removeItem(atPath: settingsPath + ".tako-new")
        try? fm.removeItem(atPath: legacyShareReceiptPath(for: "muse", baseDir: baseDir))
        return true
    }

    static func validateMuseSettings(_ settings: [String: Any]) -> Bool {
        if let schema = settings["schema_version"], (schema as? Int) != 1 { return false }
        if let env = settings["managed_hooks_env_vars"], !(env is [String]) { return false }
        return true
    }
}
