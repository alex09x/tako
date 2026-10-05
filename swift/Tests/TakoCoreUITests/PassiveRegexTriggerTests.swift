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
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class PassiveRegexTriggerTests: XCTestCase {
    func testTriggerParsingFromConfigLine() {
        // 1. Full specification: pattern = action:color:style:title
        let line1 = #"error:.* = highlight:red:box:Error Notice"#
        let trigger1 = TerminalRegexTrigger.parse(line: line1)
        XCTAssertNotNil(trigger1)
        XCTAssertEqual(trigger1?.pattern, "error:.*")
        XCTAssertEqual(trigger1?.action, .highlight)
        XCTAssertEqual(trigger1?.colorName, "red")
        XCTAssertEqual(trigger1?.style, .box)
        XCTAssertEqual(trigger1?.notificationTitle, "Error Notice")
        XCTAssertEqual(trigger1?.onlyUnfocused, true)
        XCTAssertEqual(trigger1?.isDynamic, false)

        // 2. Both action with custom hex color and underline style
        let line2 = #"test result: FAILED = both:#ff0055:underline:Test Suite"#
        let trigger2 = TerminalRegexTrigger.parse(line: line2)
        XCTAssertNotNil(trigger2)
        XCTAssertEqual(trigger2?.pattern, "test result: FAILED")
        XCTAssertEqual(trigger2?.action, .both)
        XCTAssertEqual(trigger2?.colorName, "#ff0055")
        XCTAssertEqual(trigger2?.style, .underline)
        XCTAssertEqual(trigger2?.notificationTitle, "Test Suite")

        // 3. Notify only
        let line3 = #"Build completed = notify:green:background:Build System"#
        let trigger3 = TerminalRegexTrigger.parse(line: line3)
        XCTAssertNotNil(trigger3)
        XCTAssertEqual(trigger3?.action, .notify)
        XCTAssertEqual(trigger3?.colorName, "green")
        XCTAssertEqual(trigger3?.style, .background)

        // 4. Default fallback when no specs are given
        let line4 = #"TODO:"#
        let trigger4 = TerminalRegexTrigger.parse(line: line4)
        XCTAssertNotNil(trigger4)
        XCTAssertEqual(trigger4?.pattern, "TODO:")
        XCTAssertEqual(trigger4?.action, .highlight)
        XCTAssertEqual(trigger4?.colorName, "yellow")
        XCTAssertEqual(trigger4?.style, .background)

        // 5. Invalid / comment lines
        XCTAssertNil(TerminalRegexTrigger.parse(line: ""))
        XCTAssertNil(TerminalRegexTrigger.parse(line: "   "))
        XCTAssertNil(TerminalRegexTrigger.parse(line: "# this is a comment"))
        XCTAssertNil(TerminalRegexTrigger.parse(line: "= highlight:red"))
    }

    func testColorResolution() {
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "red"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "green"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "blue"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "yellow"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "orange"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "purple"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "pink"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "cyan"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "white"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "gray"))
        XCTAssertNotNil(TerminalRegexTrigger.resolveColor(named: "#123456"))
        XCTAssertNil(TerminalRegexTrigger.resolveColor(named: "invalid_nonexistent_color"))
    }

    func testTriggerHighlightRenderingInTerminalView() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("[ERROR] Database failure\n".utf8))

        let trigger = TerminalRegexTrigger(
            pattern: "\\[ERROR\\]",
            action: .highlight,
            colorName: "red",
            style: .box
        )!
        view.regexTriggers = [trigger]
        view.updateRegexTriggerHighlights()

        let sublayers = view.triggerHighlightsLayer.sublayers ?? []
        XCTAssertEqual(sublayers.count, 1)

        let layer = sublayers[0]
        XCTAssertGreaterThan(layer.frame.width, 0)
        XCTAssertGreaterThan(layer.frame.height, 0)
        XCTAssertEqual(layer.borderWidth, 1.5)
        XCTAssertEqual(layer.cornerRadius, 2.0)
    }

    func testHighlightStyles() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("line 1: background style\r\nline 2: underline style\r\nline 3: box style\r\nline 4: bold style\r\n".utf8))

        let bgTrigger = TerminalRegexTrigger(pattern: "background style", action: .highlight, colorName: "yellow", style: .background)!
        let ulTrigger = TerminalRegexTrigger(pattern: "underline style", action: .highlight, colorName: "blue", style: .underline)!
        let boxTrigger = TerminalRegexTrigger(pattern: "box style", action: .highlight, colorName: "green", style: .box)!
        let boldTrigger = TerminalRegexTrigger(pattern: "bold style", action: .highlight, colorName: "orange", style: .bold)!

        view.regexTriggers = [bgTrigger, ulTrigger, boxTrigger, boldTrigger]
        view.updateRegexTriggerHighlights()

        let sublayers = view.triggerHighlightsLayer.sublayers ?? []
        XCTAssertEqual(sublayers.count, 4)

        // Underline style has a small height (2.0)
        let underlineLayer = sublayers[1]
        XCTAssertEqual(underlineLayer.frame.height, 2.0)

        // Box style has border 1.5
        let boxLayer = sublayers[2]
        XCTAssertEqual(boxLayer.borderWidth, 1.5)

        // Bold style has border 1.0
        let boldLayer = sublayers[3]
        XCTAssertEqual(boldLayer.borderWidth, 1.0)
    }

    func testMultipleTriggersAndLayerCleanup() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("warning 1\nwarning 2\nwarning 3\n".utf8))

        let trigger = TerminalRegexTrigger(pattern: "warning", action: .highlight, colorName: "yellow", style: .background)!
        view.regexTriggers = [trigger]
        view.updateRegexTriggerHighlights()

        XCTAssertEqual(view.triggerHighlightsLayer.sublayers?.count, 3)

        // Clearing triggers removes highlight sublayers
        view.regexTriggers = []
        XCTAssertEqual(view.triggerHighlightsLayer.sublayers?.count ?? 0, 0)
    }

    func testTriggerNotificationCallbackAndDeduplication() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Build failed with exit code 1\n".utf8))

        let trigger = TerminalRegexTrigger(
            pattern: "Build failed",
            action: .both,
            colorName: "red",
            style: .underline,
            notificationTitle: "Compiler Alert"
        )!

        var matchedCount = 0
        var lastMatchedText = ""
        view.onTriggerMatched = { matchedTrigger, text, row in
            XCTAssertEqual(matchedTrigger.id, trigger.id)
            matchedCount += 1
            lastMatchedText = text
        }

        view.regexTriggers = [trigger]
        view.updateRegexTriggerHighlights()

        XCTAssertEqual(matchedCount, 1)
        XCTAssertEqual(lastMatchedText, "Build failed")

        // Redrawing or calling updateRegexTriggerHighlights again on unchanged buffer does not duplicate notification
        view.updateRegexTriggerHighlights()
        XCTAssertEqual(matchedCount, 1)
    }

    func testStrictPassiveSafety() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let mockDelegate = MockDelegate()
        view.delegate = mockDelegate

        view.feed(data: Data("npm ERR! code ELIFECYCLE\n".utf8))
        let trigger = TerminalRegexTrigger(pattern: "npm ERR!", action: .both, colorName: "red")!
        view.regexTriggers = [trigger]
        view.updateRegexTriggerHighlights()

        // Strictly passive: no input data was dispatched to terminal PTY
        XCTAssertTrue(mockDelegate.sentInputData.isEmpty)
        XCTAssertTrue(mockDelegate.sentDeviceReplyData.isEmpty)
    }

    func testPathologicalRegexRejectionAndSafetyBounds() {
        // 1. Nested quantifiers, quantified groups, and ambiguous overlapping repetitions causing ReDoS are rejected
        let pathologicalPatterns = [
            "^(a+)+$",
            "(a*)*",
            "([0-9]+)+",
            #"(\w+)+"#,
            "^(a|aa)+$",
            "(a|b)+",
            "(test){2,}",
            "a++",
            "a**",
            "^a*a*a*a*a*a*a*b$",
            "^(a*a*a*a*a*a*a*b)$",
            "((a*a*))",
            "a*(a*)",
            "a*a*",
            ".*.*",
            #"\w+\w+"#,
            "a*b*a*"
        ]
        for pat in pathologicalPatterns {
            let safety = TerminalRegexTrigger.isSafePattern(pat)
            XCTAssertFalse(safety.isSafe, "Expected \(pat) to be flagged unsafe")
            XCTAssertNil(TerminalRegexTrigger(pattern: pat), "Expected TerminalRegexTrigger to reject \(pat)")
            XCTAssertNil(TerminalRegexTrigger.parse(line: "\(pat)=highlight:red"), "Expected parse to reject \(pat)")
        }

        // 2. Safe patterns are accepted
        let safePatterns = ["error: \\[E[0-9]+\\]", "warning: .*", "build (failed|succeeded)", "hello world", "task-[0-9]+", "https?://[^\\s]+"]
        for pat in safePatterns {
            let safety = TerminalRegexTrigger.isSafePattern(pat)
            XCTAssertTrue(safety.isSafe, "Expected \(pat) to be safe")
            XCTAssertNotNil(TerminalRegexTrigger(pattern: pat))
        }

        // 3. Excessively long pattern (>512 chars) rejected
        let longPat = String(repeating: "a", count: 600)
        XCTAssertFalse(TerminalRegexTrigger.isSafePattern(longPat).isSafe)
        XCTAssertNil(TerminalRegexTrigger(pattern: longPat))

        // 4. Abnormal output row text is capped and executes safely without UI starvation
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let massiveLine = String(repeating: "xyz ", count: 500) + "\r\n"
        view.feed(data: Data(massiveLine.utf8))

        let trigger = TerminalRegexTrigger(pattern: "xyz", action: .highlight, colorName: "yellow")!
        view.regexTriggers = [trigger]

        let start = Date()
        view.updateRegexTriggerHighlights()
        let elapsed = Date().timeIntervalSince(start)

        // Must complete in under 50ms without blocking UI
        XCTAssertLessThan(elapsed, 0.05)
        XCTAssertGreaterThan(view.triggerHighlightsLayer.sublayers?.count ?? 0, 0)

        // 5. Triggers are tracked and disabledTriggerIDs suppresses execution without leaking background jobs
        let safeTrigger = TerminalRegexTrigger(pattern: "xyz", action: .highlight, colorName: "yellow")!
        view.regexTriggers = [safeTrigger]
        XCTAssertTrue(view.disabledTriggerIDs.isEmpty)
        view.updateRegexTriggerHighlights()
        XCTAssertTrue(view.disabledTriggerIDs.isEmpty)
    }
}

private final class MockDelegate: TakoTerminalNSViewDelegate {
    var sentInputData: [Data] = []
    var sentDeviceReplyData: [Data] = []

    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
        sentInputData.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {
        sentDeviceReplyData.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {}
}
#endif
