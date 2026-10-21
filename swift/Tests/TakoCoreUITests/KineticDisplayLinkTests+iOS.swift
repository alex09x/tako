/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import UIKit
import XCTest
@testable import TakoCoreUI

/// A flick on the phone coasts on the display's own clock: the kinetic link
/// wakes for it, steps it until it has slowed to a stop, and sleeps again.
final class KineticDisplayLinkTests: XCTestCase {
    @MainActor
    func testAFlickCoastsOnTheDisplayLinkAndItSleepsOnceStill() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let view = TakoTerminalView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.feed(data: Data(String(repeating: "a line of scrollback\r\n", count: 400).utf8))
        view.startKineticDisplayLink()
        let link = try XCTUnwrap(view.kineticDisplayLink)
        view.startKineticScroll(initialVelocityY: 2500, location: CGPoint(x: 100, y: 300))
        XCTAssertFalse(link.isPaused, "the link did not wake for a flick")
        let coasted = expectation(description: "coasted")
        func check() {
            if !view.kineticDeceleration.isDecelerating { coasted.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
        }
        check()
        wait(for: [coasted], timeout: 5)
        XCTAssertTrue(link.isPaused || view.kineticDisplayLink == nil, "the link kept running once the flick had stopped")
    }
}
#endif
