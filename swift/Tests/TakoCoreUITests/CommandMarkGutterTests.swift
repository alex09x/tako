/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Metal
import XCTest
@testable import TakoCoreUI

/// Command marks keep a gutter of their own at the left edge while they are
/// on, also with the default zero padding: there they used to have no room
/// and were never drawn.
@MainActor
final class CommandMarkGutterTests: XCTestCase {
    private func makeView(padding: CGFloat = 0) throws -> TakoTerminalNSView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: shaders, encoding: .utf8), options: nil)
        TakoTerminalNSView.metalLibraryProviderForTesting = { _ in library }
        addTeardownBlock { TakoTerminalNSView.metalLibraryProviderForTesting = nil }
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var theme = view.theme
        theme.windowPadding = padding
        view.theme = theme
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func feedCommands(_ view: TakoTerminalNSView) {
        for i in 0..<60 {
            view.feed(data: Data("\u{1b}]133;A\u{07}$ cmd\(i)\r\n\u{1b}]133;C\u{07}out\(i)\r\n\u{1b}]133;D;\(i % 2)\u{07}".utf8))
        }
        view.updateScroller()
    }

    func testWithZeroPaddingTheMarksAreDrawnLeftOfTheFirstCell() throws {
        let view = try makeView()
        XCTAssertEqual(view.theme.padding.left, 0, "the theme itself keeps its zero padding")
        XCTAssertEqual(view.gridLayout.left, TakoTerminalNSView.commandMarkGutter)
        feedCommands(view)
        let marks = view.gutterMarksLayer.sublayers ?? []
        XCTAssertFalse(marks.isEmpty, "no command marks drawn")
        for mark in marks {
            XCTAssertGreaterThan(mark.frame.width, 0)
            XCTAssertGreaterThanOrEqual(mark.frame.minX, 0)
            XCTAssertLessThanOrEqual(mark.frame.maxX, view.gridLayout.left, "a mark over the first cell")
        }
    }

    func testWithMarksOffThereIsNoGutter() throws {
        let view = try makeView()
        view.commandMarksEnabled = false
        XCTAssertEqual(view.gridLayout.left, 0)
        XCTAssertEqual(view.effectivePadding.left, 0)
        feedCommands(view)
        XCTAssertTrue(view.gutterMarksLayer.sublayers?.isEmpty ?? true)
    }

    func testAWiderConfiguredPaddingIsKept() throws {
        let view = try makeView(padding: 10)
        XCTAssertEqual(view.gridLayout.left, 10)
        XCTAssertEqual(view.effectivePadding.right, 10, "only the left edge carries the gutter")
    }

    func testDurationsAndTimesKeepTheirWiderGutters() throws {
        let view = try makeView()
        view.commandDurationsEnabled = true
        XCTAssertEqual(view.gridLayout.left, 44)
        view.commandTimestampsEnabled = true
        XCTAssertEqual(view.gridLayout.left, 64)
    }

    func testTheGridDoesNotMoveAsMarksComeAndAFullScreenProgramHidesThem() throws {
        let view = try makeView()
        let before = view.gridLayout
        feedCommands(view)
        XCTAssertEqual(view.gridLayout.left, before.left)
        XCTAssertEqual(view.fittedGridLayout(for: view.bounds.size).cols, before.cols)
        view.feed(data: Data("\u{1b}[?1049h".utf8))
        view.updateScroller()
        XCTAssertTrue(view.gutterMarksLayer.sublayers?.isEmpty ?? true, "marks are hidden on the alternate screen")
        XCTAssertEqual(view.gridLayout.left, before.left)
        XCTAssertEqual(view.fittedGridLayout(for: view.bounds.size).cols, before.cols)
    }

    func testAViewSizedWithTheEffectivePaddingFitsExactlyTheCellsAskedFor() throws {
        let view = try makeView()
        let padding = view.effectivePadding
        let size = CGSize(width: view.cellWidth * 80 + padding.left + padding.right,
                          height: view.cellHeight * 20 + padding.top + padding.bottom)
        let fitted = view.fittedGridLayout(for: size)
        XCTAssertEqual(fitted.cols, 80)
        XCTAssertEqual(fitted.rows, 20)
    }
}
#endif
