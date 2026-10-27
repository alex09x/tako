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

/// A Codex turn stopped with Esc: the Interrupt hook sets the pane idle in
/// 150 ms, but the agent had been printing, so the pane went on as a live
/// program whose output flows -- a bright ember ring for the rest of the
/// three-second window. An agent that says it stopped is quiet at once.
@Suite @MainActor
struct AgentStopQuietsLiveTests {
    private final class Lines { var next = 0 }

    private func streamingAgent(_ lines: Lines) -> Tako.CrabTracker {
        let crab = Tako.CrabTracker()
        crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(
            takeOutputLines: { defer { lines.next = 0 }; return lines.next }, program: "codex"))
        crab.setStatus(.working, text: "Thinking...")
        lines.next = 12
        crab.sampleLive()
        return crab
    }

    private func drawn(_ crab: Tako.CrabTracker) -> Tako.SurfaceState {
        crab.paneStatus.surfaceState(progressState: crab.progressState, live: crab.live)
    }

    @Test(arguments: [Tako.PaneStatus.idle, .done])
    func anAgentThatStopsIsQuietAtOnce(_ status: Tako.PaneStatus) throws {
        let lines = Lines()
        let crab = streamingAgent(lines)
        #expect(crab.live?.isFlowing == true, "the agent was printing")
        crab.setStatus(status, text: nil)
        #expect(crab.live?.isFlowing == false)
        #expect(crab.live?.linesPerSecond == 0)
        if status == .idle { #expect(drawn(crab) == .live(flowing: false)) }
        // Nothing printed since: the next sample keeps it quiet.
        crab.sampleLive()
        #expect(crab.live?.isFlowing == false)
    }

    /// Lines printed after the last sample and before the stop -- a turn
    /// shorter than the 1 s sampler -- are the agent's, not new output.
    @Test func linesNotYetSampledWhenItStopsDoNotLightItUp() {
        let lines = Lines()
        let crab = Tako.CrabTracker()
        crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(
            takeOutputLines: { defer { lines.next = 0 }; return lines.next }, program: "codex"))
        crab.setStatus(.working, text: "Thinking...")
        #expect(crab.live?.isFlowing == false)
        lines.next = 9
        crab.setStatus(.idle, text: nil)
        crab.sampleLive()
        #expect(crab.live?.isFlowing == false)
        #expect(crab.live?.linesPerSecond == 0)
    }

    @Test func outputAfterTheStopFlowsAgain() {
        let lines = Lines()
        let crab = streamingAgent(lines)
        crab.setStatus(.idle, text: nil)
        lines.next = 5
        crab.sampleLive()
        #expect(crab.live?.isFlowing == true, "a program printing again is live again")
    }

    @Test(arguments: [Tako.PaneStatus.working, .needsApproval, .waitingForInput])
    func aStatusThatIsNotAStopLeavesTheOutputAlone(_ status: Tako.PaneStatus) {
        let lines = Lines()
        let crab = streamingAgent(lines)
        crab.setStatus(status, text: nil)
        #expect(crab.live?.isFlowing == true)
    }

    @Test func aPaneWithNoLiveProgramIsUntouched() {
        let crab = Tako.CrabTracker()
        crab.setStatus(.working, text: nil)
        crab.setStatus(.idle, text: nil)
        #expect(crab.live == nil)
        #expect(crab.paneStatus == .idle)
    }
}
