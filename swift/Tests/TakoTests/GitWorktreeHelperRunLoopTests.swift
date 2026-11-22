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
import Testing
@testable import Tako

/// A git call made while SwiftUI updates a view (the diff review reads its
/// files in `body`) must not run the main run loop: that re-entered SwiftUI's
/// update cycle from inside itself, and the app crashed.
@Suite(.serialized) @MainActor
struct GitWorktreeHelperRunLoopTests {
    private final class Flag { var raised = false }

    @Test func waitingForGitDoesNotRunTheMainRunLoop() {
        let flag = Flag()
        RunLoop.main.perform { flag.raised = true }
        // A git that takes a while, so a run-loop-spinning wait would spin.
        let result = GitWorktreeHelper.runGit(["-c", "alias.pause=!sleep 0.3", "pause"],
                                              in: NSTemporaryDirectory())
        #expect(result.isSuccess, "git ran: \(result.stderr)")
        #expect(!flag.raised, "the main run loop ran while waiting for git")
    }
}
