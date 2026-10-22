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

/// `takoctl close` asks the way closing by hand does, polls the question every
/// 0.1 s and, if nobody answers within `closeWait`, withdraws it: an abort is
/// not a yes, and a late click must not close what takoctl was told it kept.
@Suite(.serialized) @MainActor
struct ControlCloseWithdrawTests {
    final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ControlResponse?
        var response: ControlResponse? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ r: ControlResponse) { lock.lock(); value = r; lock.unlock() }
        var state: String? {
            if case .ok(let result)? = response, case .string(let s)? = result["state"] { return s }
            return nil
        }
    }

    @Test func anUnansweredCloseQuestionIsWithdrawnAndTakoctlHearsCancelled() async throws {
        setenv("TAKO_CLOSE_WAIT", "0.6", 1)
        defer { unsetenv("TAKO_CLOSE_WAIT") }
        let (controller, window) = TerminalTestSupport.loaded()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let surface = try #require(controller.surfaceTree.first)
        // A pane with a sub-agent asks before it closes, with no process needed.
        SubagentHierarchyStore.shared.registerChild(childId: UUID(), parentId: surface.id)
        defer { SubagentHierarchyStore.shared.unregister(paneId: surface.id) }

        let reply = Reply()
        ControlLayout.close(surface) { reply.set($0) }
        for _ in 0..<200 where TerminalDialogView.pending(in: window) == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(TerminalDialogView.pending(in: window) != nil, "no question was asked")
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(reply.response == nil, "takoctl was answered while the question was still up")
        #expect(TerminalDialogView.pending(in: window) != nil, "the question went away before its time")

        for _ in 0..<100 where reply.response == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(reply.state == "cancelled", "got \(String(describing: reply.response))")
        #expect(TerminalDialogView.pending(in: window) == nil, "the question stayed up after takoctl was told")
        #expect(controller.surfaceTree.contains(surface), "the pane closed")
    }
}
