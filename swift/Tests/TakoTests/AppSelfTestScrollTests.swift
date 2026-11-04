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

@Suite(.serialized) @MainActor
struct AppSelfTestScrollTests {
    @Test func submissionWaitYieldsUntilTheCountAdvances() async {
        var submitted: UInt64 = 7
        let update = Task { @MainActor in submitted += 1 }
        let advanced = await Tako.waitForSelfTestSubmission(after: 7, timeout: 1) { submitted }
        await update.value
        #expect(advanced)
        #expect(submitted == 8)
    }

    @Test func submissionWaitRejectsAnOldNonzeroCount() async {
        let advanced = await Tako.waitForSelfTestSubmission(after: 7, timeout: 0.02) { 7 }
        #expect(!advanced)
    }

    @Test func submissionWaitAcceptsAnAlreadyAdvancedCount() async {
        let advanced = await Tako.waitForSelfTestSubmission(after: 7, timeout: 0) { 8 }
        #expect(advanced)
    }

    @Test func submissionWaitStopsWhenCancelled() async {
        let wait = Task { @MainActor in
            await Tako.waitForSelfTestSubmission(after: 7) { 7 }
        }
        wait.cancel()
        #expect(await wait.value == false)
    }
}
