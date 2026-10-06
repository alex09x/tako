/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

enum TakoPTYEnvironment {
    /// Automation hosts and build tools frequently set NO_COLOR for their
    /// own logs. A GUI terminal must not leak that launcher preference into
    /// every interactive shell and silently disable application color.
    static let variablesRemovedFromChild = ["NO_COLOR"]

    /// What the terminal calls itself to the programs running inside it.
    ///
    /// A program that asks who it is talking to gets the true answer. Tools
    /// that gate kitty-protocol keyboard input or graphics on a list of
    /// TERM_PROGRAM names will not recognise us even though we speak those
    /// protocols; feature detection belongs in terminfo and in the escape
    /// sequences themselves, not in an allowlist of names.
    static func terminalIdentity(appVersion: String?) -> [(String, String)] {
        let version = appVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
        return [
            ("TERM_PROGRAM", "tako"),
            ("TERM_PROGRAM_VERSION", version),
        ]
    }
}

extension PTY {
    ///
    /// Computed in the parent. Between `fork` and `exec` only
    /// async-signal-safe calls are allowed, and Foundation is not one --
    /// doing this in the child killed the shell before it ever ran.
    static func shellIntegrationEnvironment(config: Tako.Config? = nil, loginShell: String = PTY.loginShell) -> [(String, String)] {
        // `shell-integration = none`: inject nothing.
        guard config?.shellIntegration != Tako.Config.ShellIntegration.none else { return [] }
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("tako").path else { return [] }
        let base = resources + "/shell-integration"
        guard FileManager.default.fileExists(atPath: base) else { return [] }

        return shellIntegrationVariables(
            resourcesDir: resources,
            base: base,
            mode: config?.shellIntegration ?? .detect,
            loginShell: loginShell,
            shellFeatures: shellFeatures(config?.shellIntegrationFeatures),
            environment: ProcessInfo.processInfo.environment)
    }

    /// The env vars a shell-integration mode needs, given the login shell
    /// and the existing environment. Pulled out of
    /// `shellIntegrationEnvironment` so the shell-name/env-var mapping is
    /// testable without a bundled Resources directory, which a test host
    /// does not have.
    static func shellIntegrationVariables(
        resourcesDir: String,
        base: String,
        mode: Tako.Config.ShellIntegration,
        loginShell: String,
        shellFeatures: String,
        environment: [String: String]
    ) -> [(String, String)] {
        guard mode != .none else { return [] }

        var env: [(String, String)] = [
            ("TAKO_RESOURCES_DIR", resourcesDir),
            // Not `title`: upstream's integration sets the window title to
            // the running command, and the design wants the directory. An
            // application that sets OSC 0 deliberately -- vim, ssh -- still
            // wins, which is the behaviour the spec asks for.
            // Neither `title` nor `cursor`: the first sets the window title
            // to the running command where the design wants the directory,
            // and the second turns the cursor into a bar at the prompt where
            // the design wants an ember block everywhere.
            // `highlight` routes an interactive `cat` through bat when it is
            // installed, and does nothing at all when it is not. It stays out
            // of the way of pipes and redirects, so a script's `cat` is still
            // byte-for-byte cat; see the shell-integration files.
            ("TAKO_SHELL_FEATURES", shellFeatures),
        ]
        // Where the `path` feature finds takoctl: the app's own MacOS folder.
        if let bin = Bundle.main.executableURL?.deletingLastPathComponent().path {
            env.append(("TAKO_BIN_DIR", bin))
        }

        let shellName: String
        switch mode {
        case .detect: shellName = (loginShell as NSString).lastPathComponent
        case .bash: shellName = "bash"
        case .zsh: shellName = "zsh"
        case .fish: shellName = "fish"
        case .elvish: shellName = "elvish"
        case .none: shellName = ""
        }

        switch shellName {
        case "zsh":
            if let old = environment["ZDOTDIR"] {
                env.append(("TAKO_ZSH_ZDOTDIR", old))
            }
            env.append(("ZDOTDIR", base + "/zsh"))
        case "bash":
            env.append(("TAKO_BASH_INJECT", "1"))
        default:
            let existing = environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env.append(("XDG_DATA_DIRS", base + ":" + existing))
        }
        return env
    }

    /// Tako's own shell-integration feature defaults, in the fixed order
    /// they're declared, with `shell-integration-features`'s comma list
    /// applied over them: a bare name enables it, `no-<name>` disables it.
    /// Names outside `knownShellFeatures` are ignored, matching how every
    /// other config key here treats an unrecognised value.
    /// `path` appends the app's own executables (takoctl) to the end of
    /// PATH, so nothing the user installed is shadowed.
    static let defaultShellFeatures = ["sudo", "prompt", "highlight", "path"]
    static let knownShellFeatures: Set<String> = [
        "cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "prompt", "highlight", "path",
    ]

    static func shellFeatures(_ raw: String?) -> String {
        var enabled = defaultShellFeatures
        guard let raw else { return enabled.joined(separator: ",") }
        for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            if token.hasPrefix("no-") {
                let name = String(token.dropFirst(3))
                guard knownShellFeatures.contains(name) else { continue }
                enabled.removeAll { $0 == name }
            } else {
                guard knownShellFeatures.contains(token), !enabled.contains(token) else { continue }
                enabled.append(token)
            }
        }
        return enabled.joined(separator: ",")
    }

    /// The process currently in the foreground of this tty -- the running
    /// command, not the shell, when one is running.
    var foregroundPID: Int? {
        let pid = tcgetpgrp(master)
        return pid > 0 ? Int(pid) : nil
    }

    /// The terminal device the shell runs on, `/dev/ttysNNN`: the pty's
    /// slave side, by `ptsname`. `ttyname` on the master returns nothing on
    /// macOS.
    var ttyName: String? {
        guard let name = ptsname(master) else { return nil }
        return String(cString: name)
    }

}
