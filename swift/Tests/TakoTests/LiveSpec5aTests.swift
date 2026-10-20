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
import QuartzCore
import Testing
@testable import Tako

/// Sessions UI 5a, line by line of its spec card: what a quiet program --
/// ssh, vim, `tail -f`, a dev server -- shows on its tab, its sidebar row,
/// its Overview card and its ring, and what it never shows.
@Suite(.serialized) @MainActor
struct LiveSpec5aTests {
    private final class Lines { var next = 0 }

    private func liveSurface(_ lines: Lines, kind: Tako.CommandKind = .quiet,
                             program: String = "tail", detail: String? = nil) -> Tako.SurfaceView {
        let surface = Tako.SurfaceView(frame: .zero)
        surface.crab.commandStarted(kind: kind, probe: Tako.LiveProbe(
            takeOutputLines: { defer { lines.next = 0 }; return lines.next }, program: program, detail: detail))
        return surface
    }

    private func window(with surfaces: Tako.SurfaceView..., title: String = "tab") -> NSWindow {
        let window = makeWindow(title: title)
        if surfaces.count == 1 {
            window.contentView = surfaces[0]
        } else {
            let content = NSView(frame: .zero)
            surfaces.forEach(content.addSubview)
            window.contentView = content
        }
        return window
    }

    // MARK: - The tab

    @Test func aQuietTabShowsItsProgramDimWhereATimerWouldStand() {
        let window = window(with: liveSurface(Lines()))
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.pillSurfaceState(for: window) == .live(flowing: false))
        #expect(bar.pillMetaText(for: window) == "tail")
        #expect(bar.pillMetaStyle(for: window) == .dim)
    }

    /// A rate changed every second, as the timer did: neither is shown.
    @Test func denseOutputShowsTheProgramNotARate() {
        let lines = Lines()
        let surface = liveSurface(lines, program: "ssh", detail: "alex@ram11")
        let window = window(with: surface)
        lines.next = 38
        surface.crab.sampleLive()
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.pillSurfaceState(for: window) == .live(flowing: true))
        #expect(bar.pillMetaText(for: window) == "ssh")
        #expect(bar.pillMetaStyle(for: window) == .dim)
    }

    @Test func aRareLineFlowsButShowsTheProgramNotARate() {
        let lines = Lines()
        let surface = liveSurface(lines)
        let window = window(with: surface)
        lines.next = 1
        surface.crab.sampleLive()
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.pillSurfaceState(for: window) == .live(flowing: true))
        #expect(bar.pillMetaText(for: window) == "tail")
        #expect(bar.pillMetaStyle(for: window) == .dim)
    }

    @Test func ofTwoPanesTheOneWhoseOutputArrivesSpeaksForTheTab() {
        let quietLines = Lines(), busyLines = Lines()
        let quiet = liveSurface(quietLines, program: "vim")
        let busy = liveSurface(busyLines, program: "tail")
        let window = window(with: quiet, busy)
        busyLines.next = 12
        quiet.crab.sampleLive()
        busy.crab.sampleLive()
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.pillSurfaceState(for: window) == .live(flowing: true))
        #expect(bar.pillMetaText(for: window) == "tail")
    }

    @Test func aFailureShowsItsExitCodeInARedChip() {
        let server = liveSurface(Lines(), program: "npm")
        let serverWindow = window(with: server)
        server.crab.commandEnded(exitCode: 1)
        let ssh = liveSurface(Lines(), kind: .connection, program: "ssh")
        let sshWindow = window(with: ssh)
        ssh.crab.commandEnded(exitCode: 255)

        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.pillSurfaceState(for: serverWindow) == .failed)
        #expect(bar.pillMetaText(for: serverWindow) == "exit 1")
        #expect(bar.pillMetaStyle(for: serverWindow) == .exitCode)
        #expect(bar.pillMetaText(for: sshWindow) == "exit 255")
        #expect(server.crab.live == nil)
    }

    @Test func stoppingAQuietProgramIsRestNotAFailureOrDone() {
        for code: Int32 in [0, 130, 141, 143] {
            let surface = liveSurface(Lines())
            let window = window(with: surface)
            surface.crab.commandEnded(exitCode: code)
            let bar = Tako.TabBarView(frame: .zero)
            #expect(bar.pillSurfaceState(for: window) == .idle, "exit \(code)")
            #expect(!surface.crab.unread, "exit \(code)")
        }
        for code: Int32 in [0, 1, 130] {
            let ssh = liveSurface(Lines(), kind: .connection, program: "ssh")
            ssh.crab.commandEnded(exitCode: code)
            #expect(ssh.crab.paneStatus == .idle, "ssh exit \(code)")
        }
    }

    // MARK: - The ring

    private func ringStroke(_ layer: Tako.TabStatusLayer) -> CGColor? {
        layer.ringContainer.sublayers?
            .first { $0.name != "liveRipple" }
            .flatMap { ($0 as? CAShapeLayer)?.strokeColor }
    }

    private let pill = CGRect(x: 0, y: 0, width: 160, height: 28)

    @Test func theRingIsDimEmberInSilenceAndFullWhileOutputArrives() {
        let layer = Tako.TabStatusLayer()
        layer.apply(state: .live(flowing: false), in: pill, hideRing: false, reduceMotion: false, paused: false)
        #expect(abs((ringStroke(layer)?.alpha ?? 0) - CGFloat(LiveRingStyle.quietOpacity)) < 0.001)
        #expect(LiveRingStyle.quietOpacity == 0.45)
        layer.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: false, paused: false)
        #expect(ringStroke(layer)?.alpha == 1)
    }

    private func rippled(_ layer: Tako.TabStatusLayer) -> Bool {
        layer.ringContainer.sublayers?.first { $0.name == "liveRipple" }?.animation(forKey: "liveRipple") != nil
    }

    @Test func eachBurstRipplesOnceAndNothingElseDoes() {
        let layer = Tako.TabStatusLayer()
        layer.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: false, paused: false, pulses: 0)
        #expect(!rippled(layer))
        layer.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: false, paused: false, pulses: 1)
        #expect(rippled(layer))

        // The same count again -- a redraw, not a burst -- adds none.
        layer.ringContainer.sublayers?.forEach { $0.removeAllAnimations() }
        layer.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: false, paused: false, pulses: 1)
        #expect(!rippled(layer))
    }

    @Test func noRippleInSilenceUnderReduceMotionOrWhileHidden() {
        let quiet = Tako.TabStatusLayer()
        quiet.apply(state: .live(flowing: false), in: pill, hideRing: false, reduceMotion: false, paused: false, pulses: 1)
        #expect(!rippled(quiet))

        let reduced = Tako.TabStatusLayer()
        reduced.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: true, paused: false, pulses: 1)
        #expect(!rippled(reduced))
        #expect(ringStroke(reduced)?.alpha == 1)

        let hidden = Tako.TabStatusLayer()
        hidden.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: false, paused: true, pulses: 1)
        #expect(!rippled(hidden))
    }

    @Test func aRippleIsASecondOfOutputNotALine() {
        let lines = Lines()
        let surface = liveSurface(lines)
        lines.next = 5000
        surface.crab.sampleLive()
        #expect(surface.crab.live?.pulses == 1)
        surface.crab.sampleLive()
        #expect(surface.crab.live?.pulses == 1)
    }

    // MARK: - The rate

    @Test func theRateIsTheAverageOfTheLastThreeSeconds() {
        let lines = Lines()
        let crab = liveSurface(lines).crab
        lines.next = 6
        crab.sampleLive()
        crab.sampleLive()
        crab.sampleLive()
        #expect(crab.live?.linesPerSecond == 2)
        #expect(crab.live?.rateLabel == "2/s")
        crab.sampleLive()
        #expect(crab.live?.isFlowing == false)
        #expect(crab.live?.rateLabel == nil)
    }

    @Test func belowTwoLinesASecondTheProgramSaysMore() {
        let lines = Lines()
        let crab = liveSurface(lines).crab
        lines.next = 4
        crab.sampleLive()
        crab.sampleLive()
        crab.sampleLive()
        #expect(crab.live?.linesPerSecond == 1)
        #expect(crab.live?.rateLabel == nil)
        #expect(crab.live?.metaLabel == "tail")
    }

    @Test func outputJustAfterAKeystrokeIsItsEcho() {
        let meter = Tako.OutputActivityMeter()
        meter.noteInput(at: 10)
        meter.noteOutput(Data("x\n".utf8), at: 10.14)
        #expect(meter.take() == 0)
        meter.noteOutput(Data("x\n".utf8), at: 10.16)
        #expect(meter.take() == 1)
        #expect(Tako.OutputActivityMeter.echoWindow == 0.15)
    }

    // MARK: - The sidebar

    @Test func aSidebarRowSaysWhereItRunsWhileOutputArrives() {
        var live = Tako.LiveActivity(program: "ssh", detail: "alex09x@ram11")
        live.isFlowing = true
        live.linesPerSecond = 38
        let ssh = SessionSidebarItem(id: "a", index: 0, isSelected: false, title: "ram11", live: live)
        #expect(ssh.liveSecondLine == "ssh · alex09x@ram11")

        var tail = Tako.LiveActivity(program: "tail")
        tail.isFlowing = true
        let log = SessionSidebarItem(id: "b", index: 0, isSelected: false, title: "voice-p.log", live: tail,
                                     workingDirectory: "/tmp/codehaus")
        #expect(log.liveSecondLine == "tail · \(Tako.formatCompactDirectory("/tmp/codehaus"))")
    }

    @Test func aQuietSidebarRowSaysHowLongItHasBeenQuiet() {
        var live = Tako.LiveActivity(program: "tail")
        live.quietSeconds = 240
        let row = SessionSidebarItem(id: "a", index: 0, isSelected: false, title: "voice-p.log", live: live)
        #expect(row.liveSecondLine == "quiet 4m")
        #expect(SessionSidebarItem(id: "b", index: 0, isSelected: false, title: "~/tako").liveSecondLine == nil)
    }

    @Test func aLiveTabInTheBackgroundDoesNotNeedYou() {
        let store = SessionSidebarStore(defaults: UserDefaults(suiteName: "LiveSpec5a-\(UUID().uuidString)")!)
        let shell = Tako.SurfaceView(frame: .zero)
        shell.title = "front"
        let lines = Lines()
        let streaming = liveSurface(lines)
        streaming.title = "back"
        let front = window(with: shell, title: "front")
        let back = window(with: streaming, title: "back")
        defer {
            Tako.CustomTabGroup.leave(back)
            Tako.CustomTabGroup.leave(front)
        }
        Tako.CustomTabGroup.join(back, to: front, select: false)
        Tako.CustomTabGroup.group(for: front).select(front)
        lines.next = 40
        streaming.crab.sampleLive()

        store.filterNeedsAttention = false
        let row = store.items(for: front).first { $0.title == "back" }
        #expect(row?.surfaceState == .live(flowing: true))
        #expect(row?.needsAttention == false)
        #expect(!streaming.crab.unread)
        store.filterNeedsAttention = true
        #expect(!store.items(for: front).contains { $0.title == "back" })
        #expect(Tako.TabBarView(frame: .zero).pillSurfaceState(for: back) != .waiting)
    }

    // MARK: - Overview

    @Test func anOverviewCardShowsHowLongItHasBeenQuietNeverARate() {
        var live = Tako.LiveActivity(program: "ssh")
        live.isFlowing = true
        live.linesPerSecond = 38
        let flowing = PaneOverviewItem(id: UUID(), title: "ram11", live: live)
        #expect(flowing.surfaceState == .live(flowing: true))
        #expect(flowing.metaDisplayText == nil)

        live.isFlowing = false
        live.linesPerSecond = 0
        live.quietSeconds = 240
        let quiet = PaneOverviewItem(id: UUID(), title: "voice-p.log", live: live)
        #expect(quiet.metaDisplayText == "quiet 4m")
    }

    @Test func liveIsNeitherWorkingNorNeedsYouInOverviewsCounts() {
        var live = Tako.LiveActivity(program: "tail")
        live.isFlowing = true
        let item = PaneOverviewItem(id: UUID(), title: "log", live: live)
        #expect(!PaneOverviewStore.StatusFilter.working.matches(item))
        #expect(!PaneOverviewStore.StatusFilter.needsYou.matches(item))
    }

    // MARK: - After Tako restarts

    @Test func aRestartedTakoTakesOnAQuietProgramStillRunning() {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        surface.adoptRunningCommand("tail -f /var/log/app.log")
        defer { surface.crab.commandEnded(exitCode: 0) }
        #expect(surface.isCommandRunning)
        #expect(surface.crab.live?.program == "tail")
        #expect(surface.crab.paneStatus == .idle)

        surface.outputMeter.noteOutput(Data("a\nb\nc\n".utf8))
        surface.crab.sampleLive()
        #expect(surface.crab.live?.rateLabel == "3/s")
    }

    @Test func aRestartedTakoLeavesAJobAndARunningCommandAlone() {
        _ = NSApplication.shared
        let job = Tako.SurfaceView(frame: .zero)
        job.adoptRunningCommand("cargo build --release")
        #expect(!job.isCommandRunning)
        #expect(job.crab.live == nil)

        let busy = Tako.SurfaceView(frame: .zero)
        busy.commandStarted()
        busy.adoptRunningCommand("ssh alex09x@ram11")
        #expect(busy.crab.live == nil)
    }
}
