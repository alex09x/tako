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

extension Tako {
    /// The built-in knowledge of which programs are not jobs. Anything not
    /// named here is a batch job: a long build or test run that prints all
    /// the while must keep its "working", so nothing is guessed from how a
    /// program behaves. A full-screen program that is missing is caught
    /// anyway, when it switches to the alternate screen.
    enum CommandRules {
        /// Words that run the command after them.
        static let wrappers: Set<String> = [
            "env", "time", "nohup", "caffeinate", "exec", "command", "builtin", "noglob",
            "stdbuf", "unbuffer", "npx", "bunx", "pnpx", "dotenv", "op", "with-env",
        ]

        /// Shells: a shell unless given a script or `-c` to run.
        static let shells: Set<String> = [
            "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh",
        ]
        /// Always another shell, whatever their arguments.
        static let sessions: Set<String> = ["su", "tmux", "screen", "zellij", "nix-shell"]

        static let connections: Set<String> = ["mosh", "et", "autossh", "telnet", "sftp", "ftp", "lftp"]

        /// Programs the user is inside until they leave.
        static let interactive: Set<String> = [
            "vi", "vim", "nvim", "view", "vimdiff", "nano", "pico", "micro", "emacs", "hx", "helix", "kak",
            "joe", "ne", "less", "more", "most", "man", "info", "top", "htop", "btop", "atop", "gtop",
            "glances", "nvtop", "btm", "iftop", "nethogs", "bmon", "mtr", "lazygit", "lazydocker", "tig",
            "gitui", "k9s", "ranger", "nnn", "lf", "yazi", "mc", "vifm", "broot", "fzf", "sk", "watch",
            "claude", "codex", "agy", "gemini", "aider", "opencode", "goose", "amp", "cursor-agent",
            "iex", "irb", "pry", "ipython", "bpython", "ptpython", "ghci", "cqlsh",
        ]

        /// Interpreters that are a prompt when given no script or code.
        static let repls: Set<String> = [
            "node", "deno", "bun", "ruby", "lua", "luajit", "julia", "R", "scala", "clj", "clojure",
            "erl", "swift", "php", "perl", "racket", "guile", "sbcl", "ocaml", "utop",
        ]

        /// Database clients: a prompt unless told what to run.
        static let databaseClients: Set<String> = [
            "psql", "pgcli", "mysql", "mariadb", "mycli", "sqlite3", "litecli", "redis-cli", "valkey-cli",
            "mongosh", "mongo", "clickhouse-client", "usql", "duckdb",
        ]
        static let databaseRunFlags: Set<String> = [
            "-c", "-e", "-f", "-q", "--command", "--execute", "--file", "--query", "--eval",
        ]

        /// Servers and watchers that run until stopped.
        static let servers: Set<String> = [
            "vite", "nodemon", "watchexec", "entr", "air", "reflex", "modd", "webpack-dev-server",
            "uvicorn", "gunicorn", "hypercorn", "daphne", "http-server", "live-server", "browser-sync",
            "ngrok", "cloudflared", "redis-server", "mongod", "postgres", "stern", "ping", "ping6",
            "tcpdump", "tshark",
        ]
        /// `npm run dev`, `pnpm start`, `yarn watch:css`...
        static let scriptRunners: Set<String> = ["npm", "pnpm", "yarn", "bun"]
        static let serverScripts: Set<String> = ["dev", "start", "serve", "watch", "preview", "storybook"]
        /// `next dev`, `hugo server`, `rails s`, `cargo watch`...
        static let serverSubcommands: [String: Set<String>] = [
            "next": ["dev", "start"], "nuxt": ["dev"], "nuxi": ["dev"], "astro": ["dev"], "remix": ["dev"],
            "webpack": ["serve"], "ng": ["serve"], "expo": ["start"], "react-native": ["start"],
            "hugo": ["server", "serve"], "jekyll": ["serve", "s"], "zola": ["serve"], "mkdocs": ["serve"],
            "rails": ["s", "server"], "flask": ["run"], "cargo": ["watch"], "jupyter": ["notebook", "lab"],
            "ollama": ["serve"], "caddy": ["run"], "artisan": ["serve"], "wrangler": ["dev"],
            "log": ["stream"], "minikube": ["tunnel"],
        ]

        static func kind(of program: String, arguments args: [String]) -> CommandKind {
            if program == "ssh" { return sshRunsCommand(args) ? .batch : .connection }
            if shells.contains(program) { return args.contains(where: { !$0.hasPrefix("-") }) ? .batch : .shell }
            if sessions.contains(program) { return .shell }
            if connections.contains(program) { return .connection }
            if interactive.contains(program) { return .quiet }
            if servers.contains(program) { return .quiet }
            if args.contains(where: { $0.hasPrefix("--watch") || $0.hasPrefix("--follow") }) { return .quiet }
            if let first = args.first(where: { !$0.hasPrefix("-") }),
               serverSubcommands[program]?.contains(first) == true {
                return .quiet
            }
            switch program {
            case "tail", "journalctl", "dmesg":
                return args.contains(where: follows) ? .quiet : .batch
            case "docker", "podman", "docker-compose", "kubectl", "oc":
                return containerKind(args)
            case "tsc", "jest":
                return args.contains("-w") ? .quiet : .batch
            case "vitest":
                return args.contains("run") ? .batch : .quiet
            case "nc", "ncat":
                return args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("l") }) ? .quiet : .batch
            default:
                break
            }
            if scriptRunners.contains(program) {
                let words = args.filter { !$0.hasPrefix("-") }
                let script = words.first == "run" ? words.dropFirst().first : words.first
                if let script, serverScripts.contains(where: { script == $0 || script.hasPrefix($0 + ":") }) {
                    return .quiet
                }
                if program == "bun" && words.isEmpty { return .quiet }
                return .batch
            }
            if program.hasPrefix("python") { return pythonKind(args) }
            if repls.contains(program) {
                if program == "php" && (args.contains("-S") || (args.contains("artisan") && args.contains("serve"))) {
                    return .quiet
                }
                return args.contains(where: { !$0.hasPrefix("-") }) || args.contains("-e") || args.contains("-c")
                    ? .batch : .quiet
            }
            if databaseClients.contains(program) { return databaseKind(program, args) }
            return .batch
        }

        /// `-f`, `-F`, `-fn100`, `--follow`, `-w` for dmesg.
        private static func follows(_ arg: String) -> Bool {
            if arg.hasPrefix("--follow") || arg == "-w" { return true }
            guard arg.hasPrefix("-"), !arg.hasPrefix("--") else { return false }
            return arg.dropFirst().prefix { $0.isLetter }.contains { $0 == "f" || $0 == "F" }
        }

        /// The host a connection goes to: the first word that is neither an
        /// option nor an option's value.
        static func destination(_ args: [String]) -> String? {
            var i = 0
            while i < args.count {
                let arg = args[i]
                if arg.hasPrefix("-") && arg.count > 1 {
                    if arg.count == 2, let flag = arg.last, sshOptionsWithValue.contains(flag) { i += 1 }
                } else {
                    return arg
                }
                i += 1
            }
            return nil
        }

        private static let sshOptionsWithValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

        /// `ssh host` is a connection; `ssh host make` runs a job there.
        private static func sshRunsCommand(_ args: [String]) -> Bool {
            var i = 0
            var host: String?
            while i < args.count {
                let arg = args[i]
                if host != nil { return true }
                if arg.hasPrefix("-") && arg.count > 1 {
                    if arg.count == 2, let flag = arg.last, sshOptionsWithValue.contains(flag) { i += 1 }
                } else {
                    host = arg
                }
                i += 1
            }
            return false
        }

        private static func containerKind(_ args: [String]) -> CommandKind {
            let words = args.filter { !$0.hasPrefix("-") }
            let flags = args.filter { $0.hasPrefix("-") }
            let tty = flags.contains { $0 == "-it" || $0 == "-ti" || $0 == "--interactive" || $0 == "-i" }
            if words.contains("logs") || words.contains("attach") {
                return args.contains(where: follows) ? .quiet : .batch
            }
            if words.contains("exec") || words.contains("run") { return tty ? .shell : .batch }
            if words.contains("up") {
                return flags.contains("-d") || flags.contains("--detach") ? .batch : .quiet
            }
            if words.contains("port-forward") || words.contains("proxy") { return .quiet }
            return .batch
        }

        /// `python` and `python -i` are a prompt, `python -m http.server`
        /// and `manage.py runserver` serve, anything else runs.
        private static func pythonKind(_ args: [String]) -> CommandKind {
            if args.contains("-i") { return .quiet }
            if let m = args.firstIndex(of: "-m"), m + 1 < args.count {
                let module = args[m + 1]
                if ["http.server", "uvicorn", "gunicorn", "hypercorn", "jupyter", "streamlit"].contains(module) {
                    return .quiet
                }
                return module == "flask" && args.contains("run") ? .quiet : .batch
            }
            if args.contains("runserver") { return .quiet }
            return args.contains(where: { !$0.hasPrefix("-") }) || args.contains("-c") ? .batch : .quiet
        }

        private static func databaseKind(_ program: String, _ args: [String]) -> CommandKind {
            if args.contains(where: databaseRunFlags.contains) { return .batch }
            // What follows `-h host` or `-p 6379` is not a command.
            var positional = 0
            var skipNext = false
            for arg in args {
                if skipNext { skipNext = false; continue }
                if arg.hasPrefix("-") {
                    skipNext = ["-h", "-p", "-a", "-n", "-u", "--user", "--pass", "-cmd", "-separator"].contains(arg)
                } else {
                    positional += 1
                }
            }
            switch program {
            case "sqlite3", "duckdb", "litecli": return positional > 1 ? .batch : .quiet
            case "redis-cli", "valkey-cli": return positional > 0 ? .batch : .quiet
            default: return .quiet
            }
        }
    }
}
