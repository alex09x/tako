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

/// A shell that marks a start but sends no command line -- a fish older than
/// its integration's cmdline_url, kept for weeks by a persistent session --
/// made every command a job: `tail -f` spun as working. What runs is read
/// off the process in front of the shell instead.
@Suite(.serialized) @MainActor
struct UnreportedCommandTests {
    @Test func aCommandTheShellDidNotNameIsReadOffItsProcess() {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        // The shell is still in front at the first look; then `tail` is.
        var reads = 0
        surface.frontCommand = { reads += 1; return reads > 1 ? "tail -f /var/log/app.log" : nil }
        surface.shellStartedCommand("")
        defer { surface.crab.commandEnded(exitCode: nil) }
        #expect(surface.crab.commandKind == .batch)

        #expect(TerminalTestSupport.waitUntil(timeout: 2.5) { surface.crab.live != nil })
        #expect(reads == 2)
        #expect(surface.crab.commandKind == .quiet)
        #expect(surface.crab.live?.program == "tail")
        #expect(surface.crab.paneStatus == .idle)

        // Ctrl-C ends it as a stream ends, not as a failed job.
        surface.crab.commandEnded(exitCode: 130)
        #expect(surface.crab.state == .idle)
    }

    @Test func aJobOrALineTheShellNamedIsLeftAsItIs() {
        _ = NSApplication.shared
        var read = false
        let job = Tako.SurfaceView(frame: .zero)
        job.frontCommand = { read = true; return "make -j8" }
        job.shellStartedCommand("")
        defer { job.crab.commandEnded(exitCode: nil) }

        var asked = false
        let named = Tako.SurfaceView(frame: .zero)
        named.frontCommand = { asked = true; return "tail -f /var/log/app.log" }
        named.shellStartedCommand("cargo build")
        defer { named.crab.commandEnded(exitCode: nil) }

        TerminalTestSupport.waitUntil(timeout: 0.7) { false }
        #expect(read)
        #expect(job.crab.commandKind == .batch)
        #expect(job.crab.live == nil)
        #expect(named.crab.commandKind == .batch)
        #expect(!asked)
    }

    /// A command that ended before its process was read is not taken on.
    @Test func aCommandThatEndedIsNotTakenOn() {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        surface.frontCommand = { "ssh alex09x@ram11" }
        surface.shellStartedCommand("")
        surface.crab.commandEnded(exitCode: 0)
        surface.commandEnded(exitCode: 0)

        TerminalTestSupport.waitUntil(timeout: 0.7) { false }
        #expect(surface.crab.live == nil)
        #expect(surface.crab.commandKind == nil)
    }
}
