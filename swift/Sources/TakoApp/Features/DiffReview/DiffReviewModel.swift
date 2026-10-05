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

/// Git modification status of a file in the diff (D3).
public enum DiffFileStatus: String, Codable, Sendable {
    case modified = "modified"
    case added = "added"
    case deleted = "deleted"
    case renamed = "renamed"
    case untracked = "untracked"

    public var badgeLetter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }
}

/// A file changed between the worktree and its base branch (D3).
public struct DiffFileEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let status: DiffFileStatus
    public let additions: Int
    public let deletions: Int
    public let oldPath: String?

    public init(
        path: String,
        status: DiffFileStatus,
        additions: Int = 0,
        deletions: Int = 0,
        oldPath: String? = nil
    ) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.oldPath = oldPath
    }
}

/// Line type in a unified diff hunk.
public enum DiffLineType: String, Codable, Sendable {
    case context
    case addition
    case deletion
    case hunkHeader
}

/// A single line in a unified diff with original and modified line numbers.
public struct DiffLine: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        "\(type.rawValue)-\(oldLineNum ?? -1)-\(newLineNum ?? -1)-\(content.hashValue)"
    }
    public let type: DiffLineType
    public let oldLineNum: Int?
    public let newLineNum: Int?
    public let content: String

    public init(type: DiffLineType, oldLineNum: Int? = nil, newLineNum: Int? = nil, content: String) {
        self.type = type
        self.oldLineNum = oldLineNum
        self.newLineNum = newLineNum
        self.content = content
    }
}

/// A diff hunk with header range and lines.
public struct DiffHunk: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(oldStart):\(newStart)" }
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let header: String
    public let lines: [DiffLine]

    public init(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        header: String,
        lines: [DiffLine]
    ) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.header = header
        self.lines = lines
    }
}

/// Detailed unified diff for a single file.
public struct DiffFileDetail: Codable, Equatable, Sendable {
    public let entry: DiffFileEntry
    public let patch: String
    public let hunks: [DiffHunk]

    public init(entry: DiffFileEntry, patch: String, hunks: [DiffHunk]) {
        self.entry = entry
        self.patch = patch
        self.hunks = hunks
    }
}

/// A line review comment collected locally before sending (D3).
public struct DiffReviewComment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let file: String
    public let line: Int
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        file: String,
        line: Int,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.file = file
        self.line = line
        self.text = text
        self.createdAt = createdAt
    }
}

/// Active diff review session state for a worktree against its base (D3).
public struct DiffReviewSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let paneId: UUID
    public let taskName: String
    public let worktreePath: String
    public let baseBranch: String
    public var files: [DiffFileEntry]
    public var selectedFile: String?
    public var comments: [DiffReviewComment]
    public var targetPaneId: UUID?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        paneId: UUID,
        taskName: String,
        worktreePath: String,
        baseBranch: String,
        files: [DiffFileEntry] = [],
        selectedFile: String? = nil,
        comments: [DiffReviewComment] = [],
        targetPaneId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.paneId = paneId
        self.taskName = taskName
        self.worktreePath = worktreePath
        self.baseBranch = baseBranch
        self.files = files
        self.selectedFile = selectedFile ?? files.first?.path
        self.comments = comments
        self.targetPaneId = targetPaneId
        self.createdAt = createdAt
    }
}

/// Formatter for batched review feedback plain text.
public enum DiffReviewFormatter {
    /// Formats all collected comments into a structured, readable Markdown feedback text.
    public static func formatFeedbackMessage(session: DiffReviewSession) -> String {
        guard !session.comments.isEmpty else {
            return "Review feedback for worktree '\(session.taskName)' (base: \(session.baseBranch)): No comments."
        }

        var lines: [String] = []
        lines.append("Review feedback for worktree '\(session.taskName)' (base: \(session.baseBranch)):")

        // Group comments by file
        let sortedComments = session.comments.sorted {
            if $0.file != $1.file {
                return $0.file < $1.file
            }
            return $0.line < $1.line
        }

        var currentFile: String? = nil
        for comment in sortedComments {
            if currentFile != comment.file {
                currentFile = comment.file
                lines.append("\n## \(comment.file)")
            }
            lines.append("• Line \(comment.line): \(comment.text)")
        }

        return lines.joined(separator: "\n")
    }
}
