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
final class CommandDurationsAndTimestampsTests: XCTestCase {
    func testDurationFormatting() {
        XCTAssertEqual(TakoTerminalNSView.formatDuration(0.0005), "<1ms")
        XCTAssertEqual(TakoTerminalNSView.formatDuration(0.05), "50ms")
        XCTAssertEqual(TakoTerminalNSView.formatDuration(0.999), "999ms")
        XCTAssertEqual(TakoTerminalNSView.formatDuration(1.23), "1.2s")
        XCTAssertEqual(TakoTerminalNSView.formatDuration(9.94), "9.9s")
        XCTAssertEqual(TakoTerminalNSView.formatDuration(15.2), "15s")
        XCTAssertEqual(TakoTerminalNSView.formatDuration(65.0), "1m 05s")
        XCTAssertEqual(TakoTerminalNSView.formatDuration(125.0), "2m 05s")
    }

    func testStartTimeFormatting() {
        let date = Date(timeIntervalSince1970: 1728144000) // Fixed timestamp
        let formatted = TakoTerminalNSView.formatStartTime(date)
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertEqual(formatted.split(separator: ":").count, 3)
    }

    func testGutterLayoutExpandsForDurationsAndTimestamps() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.commandMarksEnabled = true
        view.commandDurationsEnabled = false
        view.commandTimestampsEnabled = false

        let defaultLeft = view.gridLayout.left

        // Enable durations: gutter should expand to at least 44.0
        view.commandDurationsEnabled = true
        let durationLeft = view.gridLayout.left
        XCTAssertGreaterThanOrEqual(durationLeft, 44.0)
        XCTAssertGreaterThanOrEqual(durationLeft, defaultLeft)

        // Enable timestamps: gutter should expand to at least 64.0
        view.commandTimestampsEnabled = true
        let timestampLeft = view.gridLayout.left
        XCTAssertGreaterThanOrEqual(timestampLeft, 64.0)
        XCTAssertGreaterThanOrEqual(timestampLeft, durationLeft)
    }

    func testCommandDurationLifecycleAndParity() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.commandMarksEnabled = true
        view.commandDurationsEnabled = true

        // 1. Command start (133;A and 133;C)
        let seq1 = Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}echo test\r\n".utf8)
        view.feed(data: seq1)

        let marks1 = view.core.commandMarks()
        XCTAssertEqual(marks1.count, 1)
        let cmdId = marks1[0].commandId

        // Started at should be populated
        let startedAt = view.commandStartedAt(id: cmdId)
        XCTAssertNotNil(startedAt)

        // While running, commandDuration is nil (only finished commands record duration)
        XCTAssertNil(view.commandDuration(id: cmdId))

        // 2. Command end (133;D;0)
        Thread.sleep(forTimeInterval: 0.01) // Ensure measurable duration
        let seq2 = Data("\u{1b}]133;D;0\u{07}".utf8)
        view.feed(data: seq2)

        let dur = view.commandDuration(id: cmdId)
        XCTAssertNotNil(dur)
        if let dur {
            XCTAssertGreaterThan(dur, 0.0)
        }

        // Epoch mismatch returns nil
        XCTAssertNil(view.commandDuration(id: cmdId, epoch: 999999))

        // Correct epoch returns duration
        XCTAssertNotNil(view.commandDuration(id: cmdId, epoch: view.core.stateEpoch()))
    }

    func testGutterMarksTextLayersRendered() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.commandMarksEnabled = true
        view.commandDurationsEnabled = true

        // Feed command with start and end
        let seq = Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}echo ok\r\n\u{1b}]133;D;0\u{07}".utf8)
        view.feed(data: seq)
        view.updateGutterMarks()

        let gutterSublayers = view.gutterMarksLayer.sublayers ?? []
        XCTAssertFalse(gutterSublayers.isEmpty)

        // Gutter layer should contain both thin color bar (CALayer) and text layer (CATextLayer)
        let textLayers = gutterSublayers.compactMap { $0 as? CATextLayer }
        XCTAssertEqual(textLayers.count, 1)
        XCTAssertNotNil(textLayers.first?.string)
    }
}
#endif
