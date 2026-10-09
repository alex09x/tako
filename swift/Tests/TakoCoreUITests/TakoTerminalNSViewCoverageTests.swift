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
import Carbon
import XCTest
@testable import TakoCoreUI

@MainActor
final class TakoTerminalNSViewCoverageTests: XCTestCase {


    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        TakoTerminalNSView.isMetalDisabledForTesting = true
    }

    @MainActor func drawForTesting(_ view: TakoTerminalNSView) {
        let size = NSSize(width: max(view.bounds.width, 10), height: max(view.bounds.height, 10))
        let image = NSImage(size: size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }

    func makeHostedView(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) -> (TakoTerminalNSView, NSWindow) {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let view = TakoTerminalNSView(frame: frame)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    // MARK: - 1. Initialization, Coder, and Subclassing

    func testCoderInitialization() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        let view = TakoTerminalNSView(coder: unarchiver)
        XCTAssertNotNil(view)
        XCTAssertEqual(view?.cols, 80)
        XCTAssertEqual(view?.rows, 24)
    }

    func testSubclassAndTitleDidChange() {
        let view = SubclassedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(view.titleChangedNotifications, 0)
        view.title = "Updated Title"
        XCTAssertEqual(view.title, "Updated Title")
        XCTAssertEqual(view.titleChangedNotifications, 1)
    }

    func testThemeMutationUpdatesMetricsAndInvalidatesDisplay() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var customTheme = TerminalTheme.takoDefault
        customTheme.fontSize = 18.0
        customTheme.fontFamily = "Monaco"
        customTheme.cellWidth = 11.0
        customTheme.cellHeight = 22.0
        customTheme.cursorBlink = true

        view.theme = customTheme
        XCTAssertEqual(CTFontGetSize(view.renderer.metrics.font), 18.0)
        XCTAssertEqual(view.cellWidth, 11.0)
        XCTAssertEqual(view.cellHeight, 22.0)
        XCTAssertTrue(view.redrawPending)
        XCTAssertNotNil(view.blinkTimer)
    }

    // MARK: - 2. Accessibility

    func testAccessibilityProtocolProperties() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Accessible Row 1\r\nAccessible Row 2".utf8))

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityLabel(), "Terminal")

        let value = view.accessibilityValue() as? String
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("Accessible Row 1") == true)
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), value?.count ?? 0)

        XCTAssertNil(view.accessibilitySelectedText())
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 10)
        XCTAssertEqual(view.accessibilitySelectedText(), "Accessible")
    }

    // MARK: - 3. Checkpoints

    func testCheckpointsExportImportAndInspect() throws {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("Preserved before checkpoint\r\n".utf8))

        let version = view.checkpointVersion
        XCTAssertGreaterThan(version, 0)
        XCTAssertTrue(view.supportsCheckpointVersion(version))
        XCTAssertFalse(view.supportsCheckpointVersion(0xFFFFFF))

        let blob = try view.exportCheckpoint()
        XCTAssertFalse(blob.isEmpty)

        let info = try view.inspectCheckpoint(blob)
        XCTAssertEqual(info.version, version)
        XCTAssertEqual(Int(info.cols), view.cols)
        XCTAssertEqual(Int(info.rows), view.rows)

        view.feed(data: Data("Added after checkpoint\r\n".utf8))
        XCTAssertTrue(view.plainText(startRow: 1, maxRows: 1).contains("Added after checkpoint"))

        let restore = try view.importCheckpoint(blob)
        XCTAssertEqual(restore.cols, view.cols)
        XCTAssertEqual(restore.rows, view.rows)
        XCTAssertEqual(delegate.restoredCheckpoints.count, 1)
        XCTAssertGreaterThanOrEqual(delegate.contentChangeCount, 1)
        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("Preserved before checkpoint"))

        XCTAssertThrowsError(try view.importCheckpoint(Data([0, 1, 2, 3])))
    }

    // MARK: - 4. Parser Outcomes & Host Callbacks

    func testWorkingDirectoryAndURLParsing() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}]7;file://localhost/Volumes/data/repo/path\u{07}".utf8))
        XCTAssertEqual(delegate.lastWorkingDirectory, "/Volumes/data/repo/path")
        XCTAssertEqual(view.workingDirectory, "/Volumes/data/repo/path")

        view.feed(data: Data("\u{1b}]7;/direct/unix/path\u{07}".utf8))
        XCTAssertEqual(delegate.lastWorkingDirectory, "/direct/unix/path")
        XCTAssertEqual(view.workingDirectory, "/direct/unix/path")
    }

    func testSynchronizedOutputHoldingRedraw() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        view.feed(data: Data("\u{1b}[?2026h".utf8))
        XCTAssertTrue(view.core.isSynchronizedOutputActive())

        view.scheduleRedraw()
        view.redrawNow()

        view.feed(data: Data("Buffer updated during sync\r\n".utf8))
        XCTAssertTrue(view.core.isSynchronizedOutputActive())

        view.feed(data: Data("\u{1b}[?2026l".utf8))
        XCTAssertFalse(view.core.isSynchronizedOutputActive())
        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("Buffer updated during sync"))
    }

    func testScrollPositionNotificationOnBufferMutation() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        let lines = (0..<100).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        view.scrollPosition = 0.5
        XCTAssertEqual(view.scrollPosition, 0.5, accuracy: 0.05)

        view.scrollViewportUp(lines: 10)
        XCTAssertFalse(delegate.scrollPositions.isEmpty)

        view.scrollViewportDown(lines: 5)
        XCTAssertGreaterThan(delegate.scrollPositions.count, 1)

        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)
    }

    // MARK: - 5. Scroll & Viewport API

    func testScrollAPI() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let lines = (0..<50).map { "Row \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        XCTAssertTrue(view.bufferText.contains("Row 0"))
        XCTAssertGreaterThan(view.scrollbackLength, 0)

        view.scrollToOffset(10)
        XCTAssertEqual(view.viewportOffset, 10)

        view.scrollToOffset(0)
        XCTAssertEqual(view.viewportOffset, 0)

        let edgeText = view.plainText(startRow: 1000, maxRows: 10)
        XCTAssertEqual(edgeText, "")

        let clampedText = view.plainText(startRow: -5, maxRows: -2)
        XCTAssertFalse(clampedText.isEmpty)

        let origin = view.cellOrigin(row: 2, col: 5)
        XCTAssertEqual(origin.x, view.gridLayout.left + 5 * view.cellWidth)

        let cell = view.cellAt(NSPoint(x: origin.x + 2, y: origin.y + 2))
        XCTAssertEqual(cell.row, 2)
        XCTAssertEqual(cell.col, 5)

        let clampedMin = view.cellAt(NSPoint(x: -100, y: 10000))
        XCTAssertEqual(clampedMin.row, 0)
        XCTAssertEqual(clampedMin.col, 0)

        let clampedMax = view.cellAt(NSPoint(x: 10000, y: -10000))
        XCTAssertEqual(clampedMax.row, view.rows - 1)
        XCTAssertEqual(clampedMax.col, view.cols - 1)

        view.setMouseCell((row: 3, col: 4))
        XCTAssertEqual(view.mouseCell?.row, 3)
        XCTAssertEqual(view.mouseCell?.col, 4)
        view.setMouseCell(nil)
        XCTAssertNil(view.mouseCell)

        XCTAssertNotNil(view.presentationCadence)
        XCTAssertNil(view.metalRendererForTesting)
    }

    // MARK: - 6. Metal Palette & Colors

}
