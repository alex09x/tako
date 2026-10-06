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

@Suite
@MainActor
struct WhatsNewNoticeTests {
    @Test func currentVersionIsNonEmpty() {
        #expect(!WhatsNewNotice.currentVersion.isEmpty)
    }

    @Test func releaseNotesContainKeyHighlights() {
        let notes = WhatsNewNotice.releaseNotes(for: "0.1.7")
        #expect(notes.contains("What's New in Tako v0.1.7"))
        #expect(notes.contains("Interactive Scrollbar"))
        #expect(notes.contains("Zero-Privilege CLI"))
        #expect(notes.contains("In-App Updater Relaunch"))
        #expect(notes.contains("Top-Bar About & Quick Controls"))
        #expect(notes.contains("Session Durability"))
    }

    @Test func linesProducesFormattedTUIElements() {
        let lines = WhatsNewNotice.lines(for: "0.1.7", width: 60)
        #expect(!lines.isEmpty)
        #expect(lines.contains { line in
            line.runs.contains { $0.text.contains("Fast, native, GPU-accelerated") }
        })
        #expect(lines.contains { line in
            line.runs.contains { $0.kind == .heading && $0.text.contains("What's New in Tako v0.1.7") }
        })
    }

    @Test func relaunchAppIsSafeInTestEnvironment() {
        // Calling relaunchApp during tests must safely return without terminating the test runner
        AppUpdater.relaunchApp()
        #expect(true)
    }

}

