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

/// Helper for executing local Git commands for worktree operations (C4).
/// Provider-neutral: Tako runs git locally and never pushes.
enum GitWorktreeHelper {
    struct GitResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32

        var isSuccess: Bool { exitCode == 0 }
    }

    /// Executes a git command in the specified directory.
    static func runGit(_ args: [String], in directory: String) -> GitResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return GitResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        } catch {
            return GitResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
    }

    /// Finds the top-level repository root directory for the given path.
    static func findRepoRoot(from path: String) -> String? {
        let res = runGit(["rev-parse", "--show-toplevel"], in: path)
        guard res.isSuccess, !res.stdout.isEmpty else { return nil }
        return (res.stdout as NSString).standardizingPath
    }

    /// Resolves the default base branch or current commit.
    static func resolveBaseBranch(in repoRoot: String) -> String {
        let res = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot)
        if res.isSuccess && !res.stdout.isEmpty && res.stdout != "HEAD" {
            return res.stdout
        }
        return "HEAD"
    }

    /// Creates a new worktree and branch.
    static func createWorktree(
        repoRoot: String,
        worktreePath: String,
        branch: String,
        base: String
    ) throws {
        let expandedWorktree = (worktreePath as NSString).expandingTildeInPath
        let parentDir = (expandedWorktree as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // Try creating with new branch (-b branch base)
        var res = runGit(["worktree", "add", "-b", branch, expandedWorktree, base], in: repoRoot)
        if !res.isSuccess {
            // Branch may already exist: try attaching to existing branch
            res = runGit(["worktree", "add", expandedWorktree, branch], in: repoRoot)
            if !res.isSuccess {
                throw NSError(
                    domain: "GitWorktreeHelper",
                    code: Int(res.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create git worktree: \(res.stderr)"]
                )
            }
        }
    }

    /// Inspects the live status of the worktree (ahead/behind, uncommitted changes, unpushed work).
    static func inspectStatus(
        worktreePath: String,
        baseBranch: String
    ) -> (ahead: Int, behind: Int, changedFiles: Int, hasUncommitted: Bool, hasUnpushed: Bool) {
        let statusRes = runGit(["status", "--porcelain"], in: worktreePath)
        let statusLines = statusRes.stdout.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let changedFiles = statusLines.count
        let hasUncommitted = changedFiles > 0

        var ahead = 0
        var behind = 0
        var hasUnpushed = false

        // Check if tracking branch exists
        let upstreamRes = runGit(["rev-parse", "--verify", "@{u}"], in: worktreePath)
        if upstreamRes.isSuccess {
            let countRes = runGit(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: worktreePath)
            if countRes.isSuccess {
                let parts = countRes.stdout.split(separator: "\t")
                if parts.count >= 2 {
                    behind = Int(parts[0]) ?? 0
                    ahead = Int(parts[1]) ?? 0
                    hasUnpushed = ahead > 0
                }
            }
        } else {
            // No upstream tracking: compare against baseBranch
            let countRes = runGit(["rev-list", "--left-right", "--count", "\(baseBranch)...HEAD"], in: worktreePath)
            if countRes.isSuccess {
                let parts = countRes.stdout.split(separator: "\t")
                if parts.count >= 2 {
                    behind = Int(parts[0]) ?? 0
                    ahead = Int(parts[1]) ?? 0
                    hasUnpushed = ahead > 0
                }
            }
        }

        return (ahead, behind, changedFiles, hasUncommitted, hasUnpushed)
    }

    /// Removes a git worktree safely.
    static func removeWorktree(
        repoRoot: String,
        worktreePath: String,
        force: Bool = false
    ) throws {
        var args = ["worktree", "remove", worktreePath]
        if force {
            args.append("--force")
        }
        let res = runGit(args, in: repoRoot)
        if !res.isSuccess {
            throw NSError(
                domain: "GitWorktreeHelper",
                code: Int(res.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Failed to remove worktree: \(res.stderr)"]
            )
        }
    }
}
