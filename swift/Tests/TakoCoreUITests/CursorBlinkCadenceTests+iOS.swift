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

/// The phone's cursor blinks as the Mac's (Mobile UI: "мигание 1.2s (60% on
/// / 40% off)"). It blinked every second, half on, half off.
final class IOSCursorBlinkCadenceTests: XCTestCase {
    @MainActor
    func testTheIOSCursorIsLitFor720msThenOutFor480ms() async throws {
        var blinking = TerminalTheme.takoDefault
        blinking.cursorBlink = true
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), theme: blinking)
        view.updateBlinkTimer()
        XCTAssertTrue(view.blinkStateVisible)

        let lit = try XCTUnwrap(view.blinkTimer)
        XCTAssertEqual(lit.fireDate.timeIntervalSinceNow, 0.72, accuracy: 0.05, "lit for")
        lit.fire()
        try await waitFor { !view.blinkStateVisible }
        let out = try XCTUnwrap(view.blinkTimer)
        XCTAssertFalse(out === lit, "the next phase has a timer of its own")
        XCTAssertEqual(out.fireDate.timeIntervalSinceNow, 0.48, accuracy: 0.05, "out for")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
#endif
