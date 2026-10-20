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
import Testing
@testable import Tako

/// The design's clock for states (1b): "На активной вкладке «готово» и
/// «ошибка» гаснут через 2s, на фоновых держатся до фокуса".
@Suite(.serialized) @MainActor
struct MotionTimingRuleTests {
    private func expectFadeIn(_ crab: Tako.CrabTracker, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let due = crab.fadeDue else {
            Issue.record("no fade armed", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(due.timeIntervalSinceNow - MotionSpec.focusedLinger) < 0.15,
                "fades in \(due.timeIntervalSinceNow) s, not \(MotionSpec.focusedLinger)", sourceLocation: sourceLocation)
    }

    @Test(arguments: [Tako.PaneStatus.done, .error])
    func anAgentsOutcomeInTheFocusedTabFadesAfterTwoSeconds(_ status: Tako.PaneStatus) {
        let crab = Tako.CrabTracker()
        crab.isFocused = true
        crab.setStatus(status, text: nil)
        expectFadeIn(crab)
    }

    @Test(arguments: [Int32(0), 1])
    func aCommandsOutcomeInTheFocusedTabFadesAfterTwoSeconds(_ exitCode: Int32) {
        var now = Date()
        let crab = Tako.CrabTracker(now: { now })
        crab.isFocused = true
        crab.commandStarted()
        now += MotionSpec.minimumVisible + 1
        crab.tick()
        crab.commandEnded(exitCode: exitCode)
        expectFadeIn(crab)
    }

    @Test(arguments: [Tako.PaneStatus.done, .error])
    func anOutcomeInABackgroundTabHoldsUntilItIsSeen(_ status: Tako.PaneStatus) {
        let crab = Tako.CrabTracker()
        crab.isFocused = false
        crab.setStatus(status, text: nil)
        #expect(crab.fadeDue == nil, "a background tab's outcome fades unseen")
        #expect(crab.paneStatus == status)
        crab.focused()
        #expect(crab.paneStatus == .idle || status == .error && crab.paneStatus == .error,
                "seen, \(status) became \(crab.paneStatus)")
    }
}
