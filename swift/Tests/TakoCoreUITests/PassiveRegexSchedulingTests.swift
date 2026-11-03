/*
 * tako — Passive trigger scheduling tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class PassiveRegexSchedulingTests: XCTestCase {
    func testWaitingInNotificationDoesNotPermanentlyDisableASafePattern() throws {
        _ = NSApplication.shared
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(data: Data("xyz\r\nxyz\r\n".utf8))
        let trigger = try XCTUnwrap(TerminalRegexTrigger(pattern: "xyz", action: .both))
        var notifications = 0
        view.onTriggerMatched = { _, _, _ in
            notifications += 1
            Thread.sleep(forTimeInterval: 0.01)
        }

        view.regexTriggers = [trigger]
        XCTAssertEqual(notifications, 2, "both rows must be scanned within the CPU budget")
        view.updateRegexTriggerHighlights()

        XCTAssertEqual(notifications, 2)
        XCTAssertFalse(view.disabledTriggerIDs.contains(trigger.id))
        XCTAssertGreaterThan(view.triggerHighlightsLayer.sublayers?.count ?? 0, 0)
    }
}
#endif
