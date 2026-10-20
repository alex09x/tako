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
import Combine
import Foundation
import Testing
@testable import Tako

@Suite
struct OutputActivityMeterTests {
    @Test func countsTheLinesAPanePrints() {
        let meter = Tako.OutputActivityMeter()
        meter.noteOutput(Data("one\ntwo\nthree\n".utf8), at: 10)
        meter.noteOutput(Data("no newline".utf8), at: 10)
        #expect(meter.take() == 3)
        #expect(meter.take() == 0)
    }

    @Test func theEchoOfTypingIsNotOutput() {
        let meter = Tako.OutputActivityMeter()
        meter.noteInput(at: 10)
        meter.noteOutput(Data("ls\r\n".utf8), at: 10.05)
        #expect(meter.take() == 0)
        meter.noteOutput(Data("a\nb\n".utf8), at: 10.5)
        #expect(meter.take() == 2)
    }
}

@Suite @MainActor
struct CrabLiveTests {
    private final class Lines { var next = 0 }

    private func liveCrab(_ lines: Lines, program: String? = "tail") -> Tako.CrabTracker {
        let crab = Tako.CrabTracker(now: { Date(timeIntervalSince1970: 0) })
        crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(
            takeOutputLines: { defer { lines.next = 0 }; return lines.next }, program: program))
        return crab
    }

    @Test func aQuietProgramIsLiveFromItsStart() {
        let crab = liveCrab(Lines())
        #expect(crab.live == Tako.LiveActivity(program: "tail"))
        #expect(crab.paneStatus.surfaceState(live: crab.live) == .live(flowing: false))
    }

    @Test func outputMakesItFlowAndRipple() {
        let lines = Lines()
        let crab = liveCrab(lines)
        lines.next = 114
        crab.sampleLive()
        #expect(crab.live?.isFlowing == true)
        #expect(crab.live?.linesPerSecond == 114)
        #expect(crab.live?.rateLabel == "114/s")
        #expect(crab.live?.pulses == 1)
        lines.next = 1
        crab.sampleLive()
        #expect(crab.live?.pulses == 2)
        #expect(crab.paneStatus.surfaceState(live: crab.live) == .live(flowing: true))
    }

    @Test func aRareLineShowsTheProgramNotARate() {
        let lines = Lines()
        let crab = liveCrab(lines)
        lines.next = 1
        crab.sampleLive()
        #expect(crab.live?.isFlowing == true)
        #expect(crab.live?.rateLabel == nil)
        #expect(crab.live?.metaLabel == "tail")
    }

    @Test func threeSilentSecondsMakeItQuietAgain() {
        let lines = Lines()
        let crab = liveCrab(lines)
        lines.next = 40
        crab.sampleLive()
        for _ in 0..<3 { crab.sampleLive() }
        #expect(crab.live?.isFlowing == false)
        #expect(crab.live?.linesPerSecond == 0)
        #expect(crab.live?.quietLabel == "quiet")
    }

    @Test func aQuietProgramPublishesOnlyOnceAMinute() {
        var now = Date(timeIntervalSince1970: 0)
        let crab = Tako.CrabTracker(now: { now })
        crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(takeOutputLines: { 0 }, program: "tail"))
        var published = 0
        let sink = crab.$live.dropFirst().sink { _ in published += 1 }
        defer { sink.cancel() }
        for _ in 0..<59 {
            now += 1
            crab.sampleLive()
        }
        #expect(published == 0)
        now += 1
        crab.sampleLive()
        #expect(published == 1)
        #expect(crab.live?.quietLabel == "quiet 1m")
    }

    @Test func theEndOfTheProgramEndsIt() {
        let crab = liveCrab(Lines())
        crab.commandEnded(exitCode: 0)
        #expect(crab.live == nil)
    }

    @Test func aBatchJobIsNeverLiveButTurnsLiveFullScreen() {
        var alternate = false
        var now = Date(timeIntervalSince1970: 0)
        let crab = Tako.CrabTracker(now: { now })
        crab.commandStarted(kind: .batch, probe: Tako.LiveProbe(
            takeOutputLines: { 0 }, isAlternateScreen: { alternate }, program: "git"))
        #expect(crab.live == nil)
        alternate = true
        now = now.addingTimeInterval(1)
        crab.tick()
        #expect(crab.live?.program == "git")
    }

    @Test func anAgentsOwnStatusOutranksLive() {
        let crab = liveCrab(Lines(), program: "claude")
        crab.setStatus(.working, text: nil)
        #expect(crab.paneStatus.surfaceState(live: crab.live) == .working)
    }
}

@Suite
struct LiveActivityLabelTests {
    @Test func quietIsCountedInMinutesThenHours() {
        var live = Tako.LiveActivity(program: "ssh")
        live.quietSeconds = 59
        #expect(live.quietLabel == "quiet")
        live.quietSeconds = 240
        #expect(live.quietLabel == "quiet 4m")
        live.quietSeconds = 2 * 3600 + 14 * 60
        #expect(live.quietLabel == "quiet 2h 14m")
    }

    @Test func liveRanksBelowDoneAndAboveIdle() {
        #expect(Tako.SurfaceState.live(flowing: true).priority < Tako.SurfaceState.done.priority)
        #expect(Tako.SurfaceState.live(flowing: false).priority > Tako.SurfaceState.idle.priority)
    }

    @Test func aCommandLineNamesItsProgramAndHost() {
        let ssh = Tako.CommandKind.describe("ssh -p 22 alex@ram11")
        #expect(ssh.program == "ssh")
        #expect(ssh.detail == "alex@ram11")
        #expect(Tako.CommandKind.describe("cd logs && tail -f voice.log | grep INFO").program == "tail")
        #expect(Tako.CommandKind.describe("sudo htop").program == "htop")
        #expect(Tako.CommandKind.describe("").program == nil)
    }

    @Test func aSidebarRowShowsTheProgramOrTheExitCodeNeverARate() {
        var live = Tako.LiveActivity(program: "tail")
        live.isFlowing = true
        live.linesPerSecond = 38
        let flowing = SessionSidebarItem(id: "a", index: 0, isSelected: false, title: "log", live: live)
        #expect(flowing.surfaceState == .live(flowing: true))
        #expect(flowing.metaDisplayText == "tail")
        #expect(flowing.metaStyle == .dim)

        live.isFlowing = false
        live.linesPerSecond = 0
        let quiet = SessionSidebarItem(id: "b", index: 0, isSelected: false, title: "log", live: live)
        #expect(quiet.metaDisplayText == "tail")
        #expect(quiet.metaStyle == .dim)

        let failed = SessionSidebarItem(id: "c", index: 0, isSelected: false, title: "dev",
                                        status: .error, crabState: .failed(code: 1))
        #expect(failed.metaDisplayText == "exit 1")
        #expect(failed.metaStyle == .exitCode)
    }
}

@Suite(.serialized) @MainActor
struct OverviewLiveTests {
    private final class Lines { var next = 0 }

    @Test func aCardFollowsAStreamThatGoesQuiet() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let controller = BaseTerminalController(Tako.App(), surfaceTree: SplitTree<Tako.SurfaceView>(view: surface))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.windowController = controller
        controller.window = window
        let store = PaneOverviewStore()
        store.refresh(fromControllers: [controller])

        let lines = Lines()
        surface.crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(
            takeOutputLines: { defer { lines.next = 0 }; return lines.next }, program: "tail"))
        lines.next = 40
        surface.crab.sampleLive()
        #expect(store.items.first?.surfaceState == .live(flowing: true))

        // Quiet: the crab publishes this once, and not again for a minute.
        for _ in 0..<3 { surface.crab.sampleLive() }
        #expect(store.items.first?.surfaceState == .live(flowing: false))
        #expect(store.items.first?.metaDisplayText == "quiet")

        surface.crab.commandEnded(exitCode: 0)
        #expect(store.items.first?.live == nil)
    }
}
