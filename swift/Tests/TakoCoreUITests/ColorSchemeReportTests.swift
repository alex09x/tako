/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation
import XCTest
@testable import TakoCoreUI

/// A program asks the terminal whether it is dark or light (`CSI ? 996 n`)
/// to pick its own colours; with mode 2031 it is told when that changes. The
/// answer follows the theme's background, which is what the program draws on.
final class ColorSchemeReportTests: XCTestCase {
    func testTheBackgroundDecidesTheScheme() {
        XCTAssertTrue(TakoCore.isDark(CGColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0e / 255, alpha: 1)))
        XCTAssertTrue(TakoCore.isDark(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)))
        XCTAssertFalse(TakoCore.isDark(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
        XCTAssertFalse(TakoCore.isDark(CGColor(srgbRed: 0.93, green: 0.9, blue: 0.85, alpha: 1)))
    }

    func testTheCoreAnswersWithTheThemesScheme() {
        let core = TakoCore(cols: 20, rows: 4)
        core.setColorScheme(from: .takoDefault)
        core.feed(bytes: Data("\u{1b}[?996n".utf8))
        XCTAssertEqual(String(decoding: core.takeOutput(), as: UTF8.self), "\u{1b}[?997;1n")
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class ColorSchemeReportNSViewTests: XCTestCase {
    private func makeView() -> (TakoTerminalNSView, CoverageMockDelegate) {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate
        return (view, delegate)
    }

    private func light(_ theme: TerminalTheme) -> TerminalTheme {
        var theme = theme
        theme.background = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return theme
    }

    func testTheDefaultThemeIsReportedDark() {
        let (view, delegate) = makeView()
        view.feed(data: Data("\u{1b}[?996n".utf8))
        XCTAssertEqual(String(decoding: delegate.deviceReplyDataReceived, as: UTF8.self), "\u{1b}[?997;1n")
    }

    func testAProgramWithMode2031IsToldAtOnceWhenTheThemeTurnsLight() {
        let (view, delegate) = makeView()
        view.feed(data: Data("\u{1b}[?2031h".utf8))
        delegate.deviceReplyDataReceived = Data()

        view.theme = light(view.theme)
        XCTAssertEqual(String(decoding: delegate.deviceReplyDataReceived, as: UTF8.self), "\u{1b}[?997;2n",
                       "sent with the theme change, not held until the program prints")

        delegate.deviceReplyDataReceived = Data()
        view.theme = light(view.theme)
        XCTAssertTrue(delegate.deviceReplyDataReceived.isEmpty, "the same scheme again says nothing")
    }

    func testWithoutMode2031AThemeChangeSendsNothing() {
        let (view, delegate) = makeView()
        view.theme = light(view.theme)
        XCTAssertTrue(delegate.deviceReplyDataReceived.isEmpty)
    }
}
#endif
