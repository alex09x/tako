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
    /// What a command a plain shell runs is, which decides what its tab
    /// shows. Only a job that computes and will finish is "working": ssh,
    /// vim, htop or `tail -f` run for as long as the user keeps them, and a
    /// spinner on them said nothing and drowned the agents that really were
    /// working. A status an agent sets explicitly is never decided here.
    enum CommandKind: Equatable, Sendable {
        /// A job that finishes on its own: a build, tests, a copy. Working
        /// after a few seconds, then done or failed.
        case batch
        /// A program the user is inside, a stream, or a server: quiet while
        /// it runs, and quiet when it ends unless it failed.
        case quiet
        /// A connection to another machine. It exits with whatever the last
        /// command there did, so only its own error (255) is a failure.
        case connection
        /// Another shell. It exits with whatever the last command in it
        /// did, so how it ends says nothing.
        case shell

        /// Whether ending with `exitCode` is worth a red tab.
        func fails(_ exitCode: Int32) -> Bool {
            switch self {
            case .batch: return exitCode != 0
            // 130 is Ctrl-C, 141 a pager whose pipe closed, 143 SIGTERM:
            // the usual ways to stop something that would run on.
            case .quiet: return ![0, 130, 141, 143].contains(exitCode)
            case .connection: return exitCode == 255
            case .shell: return false
            }
        }

        /// The kind of a command line as the shell reported it. `quiet` and
        /// `busy` are the user's program names (`quiet-commands`,
        /// `busy-commands`); busy wins, and both win over the built-in rules.
        /// Of several commands on one line the quietest decides: `cd x &&
        /// ssh host` is a connection, `tail -f log | grep x` a stream.
        static func classify(_ line: String, quiet: Set<String> = [], busy: Set<String> = []) -> CommandKind {
            var result = CommandKind.batch
            for segment in ShellLine.segments(of: line) {
                let words = ShellLine.unwrapped(segment)
                guard let first = words.first else { continue }
                let program = ShellLine.programName(first)
                let kind: CommandKind
                if busy.contains(program) {
                    kind = .batch
                } else if quiet.contains(program) {
                    kind = .quiet
                } else {
                    kind = CommandRules.kind(of: program, arguments: Array(words.dropFirst()))
                }
                if kind.quietness > result.quietness { result = kind }
            }
            return result
        }

        private var quietness: Int {
            switch self {
            case .batch: return 0
            case .quiet: return 1
            case .connection: return 2
            case .shell: return 3
            }
        }
    }

    /// The little of shell syntax a command line needs taking apart for.
    enum ShellLine {
        /// The commands of a line: split at `|`, `||`, `&&`, `;` and `&`
        /// outside quotes, each as its words with quotes removed.
        static func segments(of line: String) -> [[String]] {
            var segments: [[String]] = []
            var words: [String] = []
            var word = ""
            var inWord = false
            var quote: Character?
            var escaped = false
            func endWord() {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            }
            func endSegment() {
                endWord()
                if !words.isEmpty { segments.append(words) }
                words = []
            }
            for ch in line {
                if escaped {
                    word.append(ch); inWord = true; escaped = false
                } else if let q = quote {
                    if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true } else { word.append(ch) }
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "'" || ch == "\"" {
                    quote = ch; inWord = true
                } else if ch == "|" || ch == ";" || ch == "&" || ch == "\n" {
                    endSegment()
                } else if ch == " " || ch == "\t" {
                    endWord()
                } else {
                    word.append(ch); inWord = true
                }
            }
            endSegment()
            return segments
        }

        /// The command's own words: variable assignments in front and
        /// wrappers that run it (`sudo`, `env`, `time`, `nohup`,
        /// `caffeinate`, `npx`, `bundle exec`, ...) with their options taken
        /// off. `sudo -i` and `sudo -s` open a shell, so they stay.
        static func unwrapped(_ words: [String]) -> [String] {
            var rest = ArraySlice(words)
            while let first = rest.first {
                let name = programName(first)
                if isAssignment(first) {
                    rest = rest.dropFirst()
                } else if name == "sudo" || name == "doas" {
                    let options = rest.dropFirst().prefix { $0.hasPrefix("-") }
                    if options.contains(where: { $0 == "-i" || $0 == "-s" || $0 == "--login" || $0 == "--shell" }) {
                        return ["sh"]
                    }
                    rest = rest.dropFirst(1 + options.count)
                } else if name == "nice" || name == "ionice" {
                    rest = rest.dropFirst()
                    if rest.first == "-n" || rest.first == "-c" { rest = rest.dropFirst(2) }
                    rest = rest.drop { $0.hasPrefix("-") }
                } else if CommandRules.wrappers.contains(name) {
                    rest = rest.dropFirst().drop { $0.hasPrefix("-") || isAssignment($0) }
                } else if name == "bundle" || name == "poetry" || name == "pipenv" || name == "uv" || name == "pdm",
                          rest.dropFirst().first == "exec" || rest.dropFirst().first == "run" {
                    rest = rest.dropFirst(2)
                } else {
                    break
                }
            }
            return Array(rest)
        }

        /// `/usr/bin/ssh` and `\ssh` are ssh.
        static func programName(_ word: String) -> String {
            let name = word.split(separator: "/").last.map(String.init) ?? word
            return name.hasPrefix("\\") ? String(name.dropFirst()) : name
        }

        static func isAssignment(_ word: String) -> Bool {
            guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
            return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }
}
