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

/// Sessions UI 5a over the control socket: `takoctl tree`, `status` and
/// `status tab` read a quiet program as the tab shows it.
@Suite(.serialized) @MainActor
struct ControlLiveTests {
    private final class Lines { var next = 0 }

    private func liveSurface(_ lines: Lines, kind: Tako.CommandKind = .quiet,
                             program: String, detail: String? = nil) -> Tako.SurfaceView {
        let surface = Tako.SurfaceView(frame: .zero)
        surface.crab.commandStarted(kind: kind, probe: Tako.LiveProbe(
            takeOutputLines: { defer { lines.next = 0 }; return lines.next }, program: program, detail: detail))
        return surface
    }

    private func treePane(_ surface: Tako.SurfaceView) -> [String: JSON]? {
        let pane = ControlCommands.Pane(surface: surface, windowID: "w", tabID: "t", stableTabID: "t")
        return ControlCommands.tree([pane], active: nil)["windows"]?.array?.first?.object?["tabs"]?
            .array?.first?.object?["panes"]?.array?.first?.object
    }

    @Test func theTreeSaysWhatAQuietProgramIsDoing() {
        let lines = Lines()
        let ssh = liveSurface(lines, program: "ssh", detail: "alex@ram11")
        lines.next = 38
        ssh.crab.sampleLive()
        let live = treePane(ssh)?["live"]?.object
        #expect(live?["summary"]?.string == "ssh alex@ram11 · 38/s")
        #expect(live?["rate"]?.string == "38/s")
        #expect(live?["flowing"]?.bool == true)
        #expect(live?["program"]?.string == "ssh")
        #expect(live?["detail"]?.string == "alex@ram11")

        let tail = liveSurface(Lines(), program: "tail")
        let quiet = treePane(tail)?["live"]?.object
        #expect(quiet?["summary"]?.string == "tail · quiet")
        #expect(quiet?["quiet"]?.string == "quiet")
        #expect(quiet?["rate"]?.string == nil)

        #expect(treePane(Tako.SurfaceView(frame: .zero))?.keys.contains("live") == false)
    }

    @Test func aFailureCarriesItsExitCode() {
        let server = liveSurface(Lines(), program: "npm")
        server.crab.commandEnded(exitCode: 1)
        let pane = treePane(server)
        #expect(pane?["exitCode"]?.number == 1)
        #expect(pane?.keys.contains("live") == false)
    }

    @Test func aTabWithAQuietProgramIsLive() {
        let surface = liveSurface(Lines(), program: "tail")
        let window = makeWindow(title: "log")
        window.contentView = surface
        let tab = ControlCommands.tabJSON(for: surface)
        #expect(tab["state"]?.string == "live")
        #expect(tab["index"]?.number == 1, "counted from 1, as tree counts")
        #expect(tab["live"]?.object?["summary"]?.string == "tail · quiet")

        // An agent's own status outranks it, as on the tab.
        surface.crab.setStatus(.working, text: nil)
        let working = ControlCommands.tabJSON(for: surface)
        #expect(working["state"]?.string != "live")
        #expect(!working.keys.contains("live"))
    }

    @Test func aTabOutsideAWindowIsLiveToo() {
        let surface = liveSurface(Lines(), program: "vim")
        #expect(ControlCommands.tabJSON(for: surface)["state"]?.string == "live")
    }
}
