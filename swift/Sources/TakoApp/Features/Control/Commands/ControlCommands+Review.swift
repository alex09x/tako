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
import AppKit

extension ControlCommands {
    /// Handles `takoctl review open|status|files|diff|comment|send|close` (D3).
    static func reviewCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "review")
        let sub = (try? ControlInput.text(request.args, "subcommand")) ?? "status"

        switch sub {
        case "open":
            guard let taskName = (request.args["task"]?.string ?? request.args["name"]?.string ?? request.args["worktree"]?.string), !taskName.isEmpty else {
                throw ControlError(.invalid, "missing \"task\" argument")
            }
            let baseBranch = request.args["base"]?.string
            let targetPaneStr = request.args["target_pane"]?.string
            let targetPaneId = targetPaneStr.flatMap(UUID.init) ?? request.from

            do {
                let session = try DiffReviewStore.shared.openReview(
                    paneId: surface.id,
                    taskName: taskName,
                    projectPath: surface.pwd,
                    baseBranch: baseBranch,
                    targetPaneId: targetPaneId
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "task": .string(session.taskName),
                    "worktree": .string(session.worktreePath),
                    "base": .string(session.baseBranch),
                    "files_count": .number(Double(session.files.count)),
                    "comments_count": .number(Double(session.comments.count)),
                    "open": .bool(true),
                ]
            } catch {
                throw ControlError(.invalid, error.localizedDescription)
            }

        case "status":
            if let session = DiffReviewStore.shared.session(for: surface.id) {
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(true),
                    "task": .string(session.taskName),
                    "worktree": .string(session.worktreePath),
                    "base": .string(session.baseBranch),
                    "files_count": .number(Double(session.files.count)),
                    "comments_count": .number(Double(session.comments.count)),
                ]
            } else {
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(false),
                ]
            }

        case "files":
            guard let session = DiffReviewStore.shared.session(for: surface.id) else {
                throw ControlError(.notFound, "no active diff review session on this pane")
            }
            let fileJSONs: [JSON] = session.files.map { f in
                var dict: [String: JSON] = [
                    "path": .string(f.path),
                    "status": .string(f.status.rawValue),
                    "additions": .number(Double(f.additions)),
                    "deletions": .number(Double(f.deletions)),
                ]
                if let old = f.oldPath {
                    dict["old_path"] = .string(old)
                }
                return .object(dict)
            }
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "task": .string(session.taskName),
                "base": .string(session.baseBranch),
                "files": .array(fileJSONs),
            ]

        case "diff":
            guard let session = DiffReviewStore.shared.session(for: surface.id) else {
                throw ControlError(.notFound, "no active diff review session on this pane")
            }
            if let file = request.args["file"]?.string, !file.isEmpty {
                let detail = GitDiffHelper.getFileDiff(
                    worktreePath: session.worktreePath,
                    baseBranch: session.baseBranch,
                    file: file
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "task": .string(session.taskName),
                    "file": .string(file),
                    "patch": .string(detail.patch),
                ]
            } else {
                let patch = GitDiffHelper.getFullDiff(
                    worktreePath: session.worktreePath,
                    baseBranch: session.baseBranch
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "task": .string(session.taskName),
                    "patch": .string(patch),
                ]
            }

        case "comment":
            let action = (try? ControlInput.text(request.args, "action")) ?? "list"
            switch action {
            case "add":
                guard let file = request.args["file"]?.string, !file.isEmpty else {
                    throw ControlError(.invalid, "missing \"file\" argument")
                }
                let lineNum = Int(request.args["line"]?.number ?? 1)
                guard let text = request.args["text"]?.string, !text.isEmpty else {
                    throw ControlError(.invalid, "missing \"text\" argument")
                }
                do {
                    let comment = try DiffReviewStore.shared.addComment(
                        paneId: surface.id,
                        file: file,
                        line: lineNum,
                        text: text
                    )
                    return [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "comment_id": .string(comment.id.uuidString.lowercased()),
                        "file": .string(comment.file),
                        "line": .number(Double(comment.line)),
                        "text": .string(comment.text),
                    ]
                } catch {
                    throw ControlError(.invalid, error.localizedDescription)
                }

            case "list":
                guard let session = DiffReviewStore.shared.session(for: surface.id) else {
                    throw ControlError(.notFound, "no active diff review session on this pane")
                }
                let commentJSONs: [JSON] = session.comments.map { c in
                    .object([
                        "id": .string(c.id.uuidString.lowercased()),
                        "file": .string(c.file),
                        "line": .number(Double(c.line)),
                        "text": .string(c.text),
                    ])
                }
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "comments": .array(commentJSONs),
                ]

            case "remove":
                guard let commentIdStr = request.args["comment_id"]?.string ?? request.args["id"]?.string,
                      let commentId = UUID(uuidString: commentIdStr) else {
                    throw ControlError(.invalid, "missing or invalid \"comment_id\" argument")
                }
                let removed = DiffReviewStore.shared.removeComment(paneId: surface.id, commentId: commentId)
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "removed": .bool(removed),
                ]

            case "clear":
                DiffReviewStore.shared.clearComments(paneId: surface.id)
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "cleared": .bool(true),
                ]

            default:
                throw ControlError(.invalid, "unknown review comment action: \(action)")
            }

        case "send":
            let explicitTargetStr = request.args["target_pane"]?.string ?? request.args["to"]?.string
            let targetPaneId = explicitTargetStr.flatMap(UUID.init)
            let destSurface: Tako.SurfaceView = try {
                if let targetPaneId {
                    guard let p = all.first(where: { $0.surface.id == targetPaneId }) else {
                        throw ControlError(.notFound, "target pane \(targetPaneId) not found")
                    }
                    return p.surface
                }
                if let storedTarget = DiffReviewStore.shared.session(for: surface.id)?.targetPaneId,
                   let p = all.first(where: { $0.surface.id == storedTarget }) {
                    return p.surface
                }
                return surface
            }()
            do {
                let (msg, destId) = try DiffReviewStore.shared.sendFeedback(
                    paneId: surface.id,
                    targetSurface: destSurface
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "target": .string(destId),
                    "sent": .bool(true),
                    "message": .string(msg),
                ]
            } catch {
                throw ControlError(.invalid, error.localizedDescription)
            }

        case "close":
            let closed = DiffReviewStore.shared.closeReview(paneId: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "closed": .bool(closed),
            ]

        default:
            throw ControlError(.invalid, "unknown review subcommand: \(sub)")
        }
    }
}
