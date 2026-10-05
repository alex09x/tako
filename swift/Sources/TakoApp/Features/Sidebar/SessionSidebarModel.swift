import AppKit
import Foundation
import SwiftUI
import TakoKit

/// Sourced information for a single tab/workspace row in the session sidebar (B5).
///
/// Every field documents its authoritative source to satisfy the B5 contract:
/// - `title`: Sourced from `SurfaceView.title`, `window.title`, or directory-derived name.
/// - `status`: Sourced from Track B1 `Tako.PaneStatus` (OSC 133 / OSC 1337 / `takoctl status`).
/// - `progress`: Sourced from Track B2 progress reporting (OSC 9;4 or `takoctl progress`).
/// - `elapsed`: Sourced from command mark timer (`CrabTracker.elapsedLabel`).
/// - `workingDirectory`: Sourced from shell integration OSC 7 (`SurfaceView.pwd`).
/// - `gitBranch` & `gitDirty`: Sourced locally from `.git` repository metadata (opt-in, off until enabled).
/// - `latestNotification`: Sourced from Track B4 notification records (`NotificationStore.shared`).
/// - `userDescription`: Sourced from user-defined note in `UserDefaults.tako` (user-editable).
/// - `listeningPorts`: Sourced from local process inspection of pane child PID (opt-in, off until enabled).
struct SessionSidebarItem: Identifiable, Equatable, Sendable {
    let id: String
    let surfaceId: UUID?
    let index: Int
    let isSelected: Bool
    let title: String
    let status: Tako.PaneStatus
    let crabState: Tako.CrabState
    let progress: Double?
    let progressState: TakoTerminalNSView.ProgressState
    let elapsed: String?
    let workingDirectory: String?
    let gitBranch: String?
    let gitDirty: Bool?
    let latestNotification: String?
    let userDescription: String?
    let listeningPorts: [Int]?
    let unreadCount: Int
    let needsAttention: Bool
    let totalCount: Int

    var canMoveUp: Bool { index > 0 }
    var canMoveDown: Bool { index < totalCount - 1 }

    init(
        id: String,
        surfaceId: UUID? = nil,
        index: Int,
        totalCount: Int = 1,
        isSelected: Bool,
        title: String,
        status: Tako.PaneStatus = .idle,
        crabState: Tako.CrabState = .idle,
        progress: Double? = nil,
        progressState: TakoTerminalNSView.ProgressState = .none,
        elapsed: String? = nil,
        workingDirectory: String? = nil,
        gitBranch: String? = nil,
        gitDirty: Bool? = nil,
        latestNotification: String? = nil,
        userDescription: String? = nil,
        listeningPorts: [Int]? = nil,
        unreadCount: Int = 0,
        needsAttention: Bool = false
    ) {
        self.id = id
        self.surfaceId = surfaceId
        self.index = index
        self.totalCount = totalCount
        self.isSelected = isSelected
        self.title = title
        self.status = status
        self.crabState = crabState
        self.progress = progress
        self.progressState = progressState
        self.elapsed = elapsed
        self.workingDirectory = workingDirectory
        self.gitBranch = gitBranch
        self.gitDirty = gitDirty
        self.latestNotification = latestNotification
        self.userDescription = userDescription
        self.listeningPorts = listeningPorts
        self.unreadCount = unreadCount
        self.needsAttention = needsAttention
    }
}

/// Local git repository inspection without network access or background polling.
enum LocalGitInspection {
    struct GitInfo: Equatable, Sendable {
        let branch: String
        let isDirty: Bool

        init(branch: String, isDirty: Bool) {
            self.branch = branch
            self.isDirty = isDirty
        }
    }

    /// Synchronously resolves the repository root and branch name from `.git/HEAD` without launching any subprocess.
    static func resolveBranch(directory: String) -> (repoRoot: String, branch: String)? {
        guard !directory.isEmpty else { return nil }
        var current = URL(fileURLWithPath: directory)
        var gitDir: URL?

        // Traverse up to find .git directory or file (for worktrees/submodules)
        for _ in 0..<16 {
            let candidate = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    gitDir = candidate
                } else if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("gitdir:") {
                        let rawPath = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                        if rawPath.hasPrefix("/") {
                            gitDir = URL(fileURLWithPath: rawPath)
                        } else {
                            gitDir = current.appendingPathComponent(rawPath).standardized
                        }
                    }
                }
                break
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        guard let git = gitDir else { return nil }

        // Read branch name from HEAD file
        let headURL = git.appendingPathComponent("HEAD")
        guard let headContent = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let headTrimmed = headContent.trimmingCharacters(in: .whitespacesAndNewlines)

        let branch: String
        if headTrimmed.hasPrefix("ref: refs/heads/") {
            branch = String(headTrimmed.dropFirst("ref: refs/heads/".count))
        } else {
            // Detached HEAD: display short commit hash
            branch = String(headTrimmed.prefix(7))
        }

        return (repoRoot: current.path, branch: branch)
    }

    /// Reads local git branch and dirty status from a directory.
    /// Strictly operates on the local filesystem: no network, no polling.
    static func inspect(directory: String) -> GitInfo? {
        guard let resolved = resolveBranch(directory: directory) else { return nil }
        let isDirty = checkDirtyState(repoRoot: resolved.repoRoot)
        return GitInfo(branch: resolved.branch, isDirty: isDirty)
    }

    private static func checkDirtyState(repoRoot: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot, "status", "--porcelain", "--ignore-submodules=dirty"]
        process.environment = ["GIT_OPTIONAL_LOCKS": "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return !data.isEmpty
        } catch {
            return false
        }
    }
}

/// Local process port inspection without network calls.
enum LocalPortInspection {
    /// Inspects TCP listening ports for a given process PID using local `lsof`.
    /// Off by default; called only when explicitly enabled.
    static func inspectListeningPorts(pid: Int) -> [Int] {
        guard pid > 0 else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-iTCP", "-sTCP:LISTEN", "-p", "\(pid)", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            var ports: Set<Int> = []
            for line in output.split(separator: "\n") {
                if line.hasPrefix("n") {
                    let address = line.dropFirst()
                    if let colonIdx = address.lastIndex(of: ":") {
                        let portStr = address[address.index(after: colonIdx)...]
                        if let port = Int(portStr) {
                            ports.insert(port)
                        }
                    }
                }
            }
            return ports.sorted()
        } catch {
            return []
        }
    }
}
