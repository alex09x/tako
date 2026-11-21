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

/// Command identity only: lifecycle state still comes from provider hooks.
struct AgentProgramIdentity {
    let program: String
    let rawProgram: String
    let arguments: [String]

    init?(_ words: [String]) {
        guard let executable = words.first else { return nil }
        rawProgram = Tako.ShellLine.programName(executable)
        let args = Array(words.dropFirst())
        let node = "/qwen-code/node/bin/node"
        let entry = "/qwen-code/lib/cli-entry.js"
        if executable.hasPrefix("/"), executable.hasSuffix(node),
           let script = args.first, script.hasPrefix("/"), script.hasSuffix(entry),
           executable.dropLast(node.count) == script.dropLast(entry.count) {
            program = "qwen"
            arguments = Array(args.dropFirst())
        } else if rawProgram.range(of: #"\Amuse-bin-[0-9]+\.[0-9]+\.[0-9]+-R[0-9]+\.[0-9]+\z"#,
                                   options: .regularExpression) != nil {
            program = "muse"
            arguments = args
        } else {
            program = rawProgram
            arguments = args
        }
    }

    /// Existing raw-name overrides retain their meaning after normalization.
    var policyNames: [String] { program == rawProgram ? [program] : [rawProgram, program] }

    static func kind(program: String, arguments: [String]) -> Tako.CommandKind? {
        guard program == "qwen" || program == "muse" else { return nil }
        let flags = arguments.prefix { $0 != "--" }
        if flags.contains(where: { ["-h", "--help", "-v", "-V", "--version"].contains($0)
            || $0.hasPrefix("--help=") || $0.hasPrefix("--version=") }) { return .batch }
        if program == "muse" {
            let utilities: Set<String> = ["exec", "config", "export", "trace", "model-profile", "skills",
                "voice", "plugins", "sandbox", "schema", "session-message", "mcp", "auth", "login",
                "logout", "usage", "init", "help", "version"]
            return arguments.first.map(utilities.contains) == true ? .batch : .quiet
        }
        if flags.contains(where: { $0 == "--prompt" || $0.hasPrefix("--prompt=")
            || ($0.hasPrefix("-p") && !$0.hasPrefix("--")) }) { return .batch }
        if flags.contains(where: { ["-i", "--prompt-interactive", "-r", "--resume", "--continue"].contains($0)
            || $0.hasPrefix("--prompt-interactive=") || $0.hasPrefix("--resume=") }) { return .quiet }
        if let first = arguments.first {
            if first == "attach" || first == "serve" { return .quiet }
            if first == "--" { return arguments.count > 1 ? .batch : .quiet }
            // Qwen's positional query is a one-shot invocation; Muse's is not.
            if !first.hasPrefix("-") { return .batch }
        }
        return .quiet
    }
}
