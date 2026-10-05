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
import Combine
import AppKit

/// Central store managing active diff review sessions and local comment collection (D3).
/// Invariant: Tako never commits, pushes, or edits files from this store.
@MainActor
public final class DiffReviewStore: ObservableObject {
    public static let shared = DiffReviewStore()

    /// Active review sessions keyed by pane ID.
    @Published public private(set) var sessions: [UUID: DiffReviewSession] = [:]

    public init() {}

    /// Retrieves the active review session for a pane, if any.
    public func session(for paneId: UUID) -> DiffReviewSession? {
        sessions[paneId]
    }

    /// Whether an active review session is open on the pane.
    public func hasSession(paneId: UUID) -> Bool {
        sessions[paneId] != nil
    }

    /// Opens a new diff review session on the specified pane for a worktree task or path.
    @discardableResult
    public func openReview(
        paneId: UUID,
        taskName: String,
        projectPath: String? = nil,
        baseBranch: String? = nil,
        targetPaneId: UUID? = nil
    ) throws -> DiffReviewSession {
        let repoRoot = projectPath.flatMap { GitWorktreeHelper.findRepoRoot(from: $0) }
        let (resolvedWorktreePath, resolvedBaseBranch, displayName): (String, String, String) = {
            if let task = WorktreeTaskStore.shared.task(named: taskName, in: repoRoot) {
                return (task.worktreePath, baseBranch ?? task.baseBranch, task.name)
            } else {
                // Check if taskName is a directory path
                let expanded = (taskName as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                    let base = baseBranch ?? GitWorktreeHelper.resolveBaseBranch(in: expanded)
                    let name = (expanded as NSString).lastPathComponent
                    return (expanded, base, name)
                }
                // Fallback to checking projectRoot/.tako/worktrees/taskName
                if let root = repoRoot ?? GitWorktreeHelper.findRepoRoot(from: FileManager.default.currentDirectoryPath) {
                    let candidate = ((root as NSString).appendingPathComponent(".tako/worktrees") as NSString).appendingPathComponent(taskName)
                    if FileManager.default.fileExists(atPath: candidate) {
                        let base = baseBranch ?? GitWorktreeHelper.resolveBaseBranch(in: root)
                        return (candidate, base, taskName)
                    }
                }
                // Default to using project root
                let root = repoRoot ?? FileManager.default.currentDirectoryPath
                let base = baseBranch ?? GitWorktreeHelper.resolveBaseBranch(in: root)
                return (root, base, taskName)
            }
        }()

        let files = GitDiffHelper.getDiffFiles(worktreePath: resolvedWorktreePath, baseBranch: resolvedBaseBranch)

        let session = DiffReviewSession(
            paneId: paneId,
            taskName: displayName,
            worktreePath: resolvedWorktreePath,
            baseBranch: resolvedBaseBranch,
            files: files,
            selectedFile: files.first?.path,
            comments: [],
            targetPaneId: targetPaneId
        )

        sessions[paneId] = session
        return session
    }

    /// Closes the diff review session for a pane.
    @discardableResult
    public func closeReview(paneId: UUID) -> Bool {
        sessions.removeValue(forKey: paneId) != nil
    }

    /// Selects a file to inspect in the review session.
    public func selectFile(paneId: UUID, file: String) {
        guard var session = sessions[paneId] else { return }
        session.selectedFile = file
        sessions[paneId] = session
    }

    /// Adds a line review comment to the local review session.
    @discardableResult
    public func addComment(
        paneId: UUID,
        file: String,
        line: Int,
        text: String
    ) throws -> DiffReviewComment {
        guard var session = sessions[paneId] else {
            throw NSError(
                domain: "DiffReviewStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No active diff review session on pane \(paneId)"]
            )
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw NSError(
                domain: "DiffReviewStore",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Comment text cannot be empty"]
            )
        }

        let comment = DiffReviewComment(file: file, line: line, text: trimmedText)
        session.comments.append(comment)
        sessions[paneId] = session
        return comment
    }

    /// Removes a comment by ID from the review session.
    @discardableResult
    public func removeComment(paneId: UUID, commentId: UUID) -> Bool {
        guard var session = sessions[paneId] else { return false }
        let countBefore = session.comments.count
        session.comments.removeAll { $0.id == commentId }
        if session.comments.count != countBefore {
            sessions[paneId] = session
            return true
        }
        return false
    }

    /// Clears all local comments from the review session.
    public func clearComments(paneId: UUID) {
        guard var session = sessions[paneId] else { return }
        session.comments.removeAll()
        sessions[paneId] = session
    }

    /// Sends batched review feedback as plain text into a target pane (D3).
    ///
    /// Takes all collected comments, formats them into a structured Markdown message,
    /// and sends them directly to the chosen pane.
    @discardableResult
    func sendFeedback(
        paneId: UUID,
        targetSurface: Tako.SurfaceView
    ) throws -> (message: String, targetId: String) {
        guard var session = sessions[paneId] else {
            throw NSError(
                domain: "DiffReviewStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No active diff review session on pane \(paneId)"]
            )
        }

        guard !session.comments.isEmpty else {
            throw NSError(
                domain: "DiffReviewStore",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "No comments collected to send in review session"]
            )
        }

        // Format message
        let feedbackMessage = DiffReviewFormatter.formatFeedbackMessage(session: session)

        // Send plain text into target pane
        try ControlInput.send(targetSurface, text: feedbackMessage, enter: true)

        let targetId = targetSurface.id.uuidString.lowercased()

        // Clear sent comments from the review session
        session.comments.removeAll()
        sessions[paneId] = session

        return (feedbackMessage, targetId)
    }

    /// Cleans up all sessions (for tests/teardown).
    public func resetForTesting() {
        sessions.removeAll()
    }
}
