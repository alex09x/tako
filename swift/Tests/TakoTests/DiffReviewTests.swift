/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@Suite("DiffReviewTests")
struct DiffReviewTests {

    @Test("DiffReviewFormatter formats batched line comments correctly")
    func testFeedbackFormatting() {
        let paneId = UUID()
        var session = DiffReviewSession(
            paneId: paneId,
            taskName: "agent-task-1",
            worktreePath: "/tmp/worktree",
            baseBranch: "main"
        )

        // Empty comments
        let emptyMsg = DiffReviewFormatter.formatFeedbackMessage(session: session)
        #expect(emptyMsg.contains("No comments"))

        // Add comments
        session.comments.append(DiffReviewComment(file: "src/main.rs", line: 42, text: "Check bounds here"))
        session.comments.append(DiffReviewComment(file: "src/main.rs", line: 85, text: "Consider using map_err"))
        session.comments.append(DiffReviewComment(file: "Cargo.toml", line: 10, text: "Pin version strictly"))

        let msg = DiffReviewFormatter.formatFeedbackMessage(session: session)
        #expect(msg.contains("Review feedback for worktree 'agent-task-1' (base: main):"))
        #expect(msg.contains("## Cargo.toml"))
        #expect(msg.contains("• Line 10: Pin version strictly"))
        #expect(msg.contains("## src/main.rs"))
        #expect(msg.contains("• Line 42: Check bounds here"))
        #expect(msg.contains("• Line 85: Consider using map_err"))
    }

    @Test("GitDiffHelper parses unified diff hunks and line numbers accurately")
    func testDiffHunkParsing() {
        let samplePatch = """
        --- a/src/lib.rs
        +++ b/src/lib.rs
        @@ -10,6 +10,8 @@ fn compute() {
             let x = 1;
             let y = 2;
        -    let z = x + y;
        +    let z = x * y;
        +    let extra = 100;
             println!("{}", z);
             z
         }
        """

        let hunks = GitDiffHelper.parseHunks(from: samplePatch)
        #expect(hunks.count == 1)

        let hunk = hunks[0]
        #expect(hunk.oldStart == 10)
        #expect(hunk.oldLines == 6)
        #expect(hunk.newStart == 10)
        #expect(hunk.newLines == 8)

        // Verify line types and numbering
        let additions = hunk.lines.filter { $0.type == .addition }
        let deletions = hunk.lines.filter { $0.type == .deletion }
        let context = hunk.lines.filter { $0.type == .context }

        #expect(additions.count == 2)
        #expect(deletions.count == 1)
        #expect(context.count == 5)

        #expect(deletions[0].oldLineNum == 12)
        #expect(deletions[0].newLineNum == nil)
        #expect(deletions[0].content == "    let z = x + y;")

        #expect(additions[0].newLineNum == 12)
        #expect(additions[0].content == "    let z = x * y;")
        #expect(additions[1].newLineNum == 13)
        #expect(additions[1].content == "    let extra = 100;")
    }

    @Test("DiffReviewStore manages comments and feedback lifecycle")
    @MainActor
    func testReviewStoreCommentLifecycle() throws {
        let store = DiffReviewStore.shared
        store.resetForTesting()

        let paneId = UUID()
        let tempDir = NSTemporaryDirectory()

        let session = try store.openReview(
            paneId: paneId,
            taskName: "test-feature",
            projectPath: tempDir,
            baseBranch: "main"
        )
        #expect(store.hasSession(paneId: paneId))
        #expect(session.taskName == "test-feature")

        // Add comments
        let c1 = try store.addComment(paneId: paneId, file: "foo.rs", line: 5, text: "First comment")
        _ = try store.addComment(paneId: paneId, file: "bar.rs", line: 20, text: "Second comment")

        let current = store.session(for: paneId)
        #expect(current?.comments.count == 2)

        // Remove one comment
        let removed = store.removeComment(paneId: paneId, commentId: c1.id)
        #expect(removed == true)
        #expect(store.session(for: paneId)?.comments.count == 1)

        // Clear comments
        store.clearComments(paneId: paneId)
        #expect(store.session(for: paneId)?.comments.isEmpty == true)

        // Close review
        let closed = store.closeReview(paneId: paneId)
        #expect(closed == true)
        #expect(store.hasSession(paneId: paneId) == false)
    }

    @Test("ControlCommands reviewCommand dispatches open, comment, files, diff, and close")
    @MainActor
    func testControlReviewCommand() throws {
        let store = DiffReviewStore.shared
        store.resetForTesting()

        let app = Tako.App()
        let surface = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())
        let controller = TerminalController(app)
        let pane = ControlCommands.Pane(surface: surface, windowID: "w1", tabID: "t1", controller: controller)
        let all = [pane]

        // 1. Open review
        let openReq = ControlRequest(cmd: "review", args: [
            "subcommand": .string("open"),
            "task": .string("my-task"),
            "base": .string("main"),
        ], from: nil)
        let openRes = try ControlCommands.reviewCommand(openReq, all: all)
        #expect(openRes["open"]?.bool == true)
        #expect(openRes["task"]?.string == "my-task")

        // 2. Add comment
        let addCommentReq = ControlRequest(cmd: "review", args: [
            "subcommand": .string("comment"),
            "action": .string("add"),
            "file": .string("src/main.rs"),
            "line": .number(42),
            "text": .string("Review feedback line 42"),
        ], from: nil)
        let addCommentRes = try ControlCommands.reviewCommand(addCommentReq, all: all)
        #expect(addCommentRes["file"]?.string == "src/main.rs")
        #expect(addCommentRes["line"]?.number == 42)
        #expect(addCommentRes["text"]?.string == "Review feedback line 42")

        // 3. List comments
        let listCommentReq = ControlRequest(cmd: "review", args: [
            "subcommand": .string("comment"),
            "action": .string("list"),
        ], from: nil)
        let listCommentRes = try ControlCommands.reviewCommand(listCommentReq, all: all)
        let commentsArray = listCommentRes["comments"]?.array
        #expect(commentsArray?.count == 1)

        // 4. Status
        let statusReq = ControlRequest(cmd: "review", args: ["subcommand": .string("status")], from: nil)
        let statusRes = try ControlCommands.reviewCommand(statusReq, all: all)
        #expect(statusRes["open"]?.bool == true)
        #expect(statusRes["comments_count"]?.number == 1)

        // 5. Close review
        let closeReq = ControlRequest(cmd: "review", args: ["subcommand": .string("close")], from: nil)
        let closeRes = try ControlCommands.reviewCommand(closeReq, all: all)
        #expect(closeRes["closed"]?.bool == true)

        let statusAfter = try ControlCommands.reviewCommand(statusReq, all: all)
        #expect(statusAfter["open"]?.bool == false)
    }
}
