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

/// Helper for read-only Git diff operations for worktree review (D3).
/// Invariant: Tako never commits, pushes, or edits files from this module.
public enum GitDiffHelper {
    /// Prohibited git operations to enforce strict read-only safety.
    private static let prohibitedCommands: Set<String> = [
        "commit", "push", "checkout", "reset", "clean", "rm", "mv",
        "merge", "rebase", "cherry-pick", "stash", "apply"
    ]

    /// Executes a strictly read-only git command.
    private static func runReadOnlyGit(_ args: [String], in directory: String) throws -> GitWorktreeHelper.GitResult {
        guard let first = args.first?.lowercased(), !prohibitedCommands.contains(first) else {
            throw NSError(
                domain: "GitDiffHelper",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Prohibited mutating git operation: \(args.first ?? "")"]
            )
        }
        for arg in args {
            if prohibitedCommands.contains(arg.lowercased()) {
                throw NSError(
                    domain: "GitDiffHelper",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Prohibited mutating git argument: \(arg)"]
                )
            }
        }
        return GitWorktreeHelper.runGit(args, in: directory)
    }

    private static func validateBaseBranch(_ branch: String) throws {
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains(" ") else {
            throw NSError(
                domain: "GitDiffHelper",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid base branch ref: \(branch)"]
            )
        }
    }

    /// Executes a strictly read-only git command safely without throwing.
    private static func runReadOnlyGitSafe(_ args: [String], in directory: String) -> GitWorktreeHelper.GitResult {
        do {
            return try runReadOnlyGit(args, in: directory)
        } catch {
            return GitWorktreeHelper.GitResult(stdout: "", stderr: error.localizedDescription, exitCode: 1)
        }
    }

    /// Obtains the list of changed files between the worktree and its base branch.
    public static func getDiffFiles(worktreePath: String, baseBranch: String) -> [DiffFileEntry] {
        guard (try? validateBaseBranch(baseBranch)) != nil else { return [] }
        var entriesByPath: [String: DiffFileEntry] = [:]

        // 1. Get name-status: M, A, D, R, etc.
        let nameStatusRes = runReadOnlyGitSafe(["diff", "--name-status", "--end-of-options", baseBranch], in: worktreePath)
        if nameStatusRes.isSuccess {
            let lines = nameStatusRes.stdout.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for line in lines {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard !parts.isEmpty else { continue }
                let statusChar = parts[0].prefix(1)
                let status: DiffFileStatus = switch statusChar {
                case "A": .added
                case "D": .deleted
                case "R": .renamed
                default: .modified
                }

                if status == .renamed && parts.count >= 3 {
                    let oldPath = parts[1]
                    let newPath = parts[2]
                    entriesByPath[newPath] = DiffFileEntry(path: newPath, status: .renamed, additions: 0, deletions: 0, oldPath: oldPath)
                } else if parts.count >= 2 {
                    let path = parts[1]
                    entriesByPath[path] = DiffFileEntry(path: path, status: status, additions: 0, deletions: 0)
                }
            }
        }

        // 2. Get numstat additions and deletions
        let numstatRes = runReadOnlyGitSafe(["diff", "--numstat", "--end-of-options", baseBranch], in: worktreePath)
        if numstatRes.isSuccess {
            let lines = numstatRes.stdout.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for line in lines {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count >= 3 else { continue }
                let adds = Int(parts[0]) ?? 0
                let dels = Int(parts[1]) ?? 0
                let path = parts[2]

                if let existing = entriesByPath[path] {
                    entriesByPath[path] = DiffFileEntry(
                        path: existing.path,
                        status: existing.status,
                        additions: adds,
                        deletions: dels,
                        oldPath: existing.oldPath
                    )
                } else {
                    entriesByPath[path] = DiffFileEntry(path: path, status: .modified, additions: adds, deletions: dels)
                }
            }
        }

        // 3. Include untracked files from git status --porcelain
        let statusRes = runReadOnlyGitSafe(["status", "--porcelain"], in: worktreePath)
        if statusRes.isSuccess {
            let lines = statusRes.stdout.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for line in lines {
                if line.hasPrefix("?? ") {
                    let rawPath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if entriesByPath[cleanPath] == nil {
                        // Count lines for untracked file if readable
                        let fullPath = ((worktreePath as NSString).expandingTildeInPath as NSString).appendingPathComponent(cleanPath)
                        let lineCount = (try? String(contentsOfFile: fullPath, encoding: .utf8).components(separatedBy: "\n").count) ?? 0
                        entriesByPath[cleanPath] = DiffFileEntry(path: cleanPath, status: .untracked, additions: lineCount, deletions: 0)
                    }
                }
            }
        }

        return Array(entriesByPath.values).sorted { $0.path < $1.path }
    }

    /// Obtains the unified patch and parsed hunks for a specific file.
    public static func getFileDiff(worktreePath: String, baseBranch: String, file: String) -> DiffFileDetail {
        guard (try? validateBaseBranch(baseBranch)) != nil else {
            return DiffFileDetail(entry: DiffFileEntry(path: file, status: .modified), patch: "", hunks: [])
        }
        let files = getDiffFiles(worktreePath: worktreePath, baseBranch: baseBranch)
        let entry = files.first(where: { $0.path == file }) ?? DiffFileEntry(path: file, status: .modified)

        let patch: String
        if entry.status == .untracked {
            let fullPath = ((worktreePath as NSString).expandingTildeInPath as NSString).appendingPathComponent(file)
            if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                var buf = "--- /dev/null\n+++ b/\(file)\n@@ -0,0 +1,\(lines.count) @@\n"
                for l in lines {
                    buf += "+\(l)\n"
                }
                patch = buf
            } else {
                patch = ""
            }
        } else {
            let res = runReadOnlyGitSafe(["diff", "--end-of-options", baseBranch, "--", file], in: worktreePath)
            patch = res.stdout
        }

        let hunks = parseHunks(from: patch)
        return DiffFileDetail(entry: entry, patch: patch, hunks: hunks)
    }

    /// Obtains the full unified diff of all changes against baseBranch.
    public static func getFullDiff(worktreePath: String, baseBranch: String) -> String {
        guard (try? validateBaseBranch(baseBranch)) != nil else { return "" }
        let res = runReadOnlyGitSafe(["diff", "--end-of-options", baseBranch], in: worktreePath)
        return res.stdout
    }

    /// Parses a unified diff patch string into structured hunks with line numbers.
    public static func parseHunks(from patch: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        let lines = patch.components(separatedBy: "\n")

        var currentHeader = ""
        var oldStart = 0
        var oldLines = 0
        var newStart = 0
        var newLines = 0
        var hunkLines: [DiffLine] = []

        var currentOldLine = 0
        var currentNewLine = 0

        func flushCurrentHunk() {
            if !hunkLines.isEmpty || !currentHeader.isEmpty {
                hunks.append(DiffHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    header: currentHeader,
                    lines: hunkLines
                ))
                hunkLines.removeAll()
            }
        }

        for line in lines {
            if line.hasPrefix("@@ ") {
                flushCurrentHunk()
                currentHeader = line

                // Parse @@ -oldStart,oldLines +newStart,newLines @@
                let components = line.split(separator: "@@")
                if let rangeSpec = components.first {
                    let ranges = rangeSpec.split(separator: " ")
                    for r in ranges {
                        if r.hasPrefix("-") {
                            let sub = r.dropFirst()
                            let parts = sub.split(separator: ",")
                            oldStart = Int(parts[0]) ?? 1
                            oldLines = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
                        } else if r.hasPrefix("+") {
                            let sub = r.dropFirst()
                            let parts = sub.split(separator: ",")
                            newStart = Int(parts[0]) ?? 1
                            newLines = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
                        }
                    }
                }
                currentOldLine = oldStart
                currentNewLine = newStart
            } else if !currentHeader.isEmpty {
                if line.hasPrefix("+") {
                    hunkLines.append(DiffLine(
                        type: .addition,
                        oldLineNum: nil,
                        newLineNum: currentNewLine,
                        content: String(line.dropFirst())
                    ))
                    currentNewLine += 1
                } else if line.hasPrefix("-") {
                    hunkLines.append(DiffLine(
                        type: .deletion,
                        oldLineNum: currentOldLine,
                        newLineNum: nil,
                        content: String(line.dropFirst())
                    ))
                    currentOldLine += 1
                } else if line.hasPrefix(" ") {
                    hunkLines.append(DiffLine(
                        type: .context,
                        oldLineNum: currentOldLine,
                        newLineNum: currentNewLine,
                        content: String(line.dropFirst())
                    ))
                    currentOldLine += 1
                    currentNewLine += 1
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file"
                    continue
                }
            }
        }

        flushCurrentHunk()
        return hunks
    }
}
