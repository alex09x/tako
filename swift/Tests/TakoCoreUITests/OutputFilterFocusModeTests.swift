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
final class OutputFilterFocusModeTests: XCTestCase {
    private func makeView() -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.layoutSubtreeIfNeeded()
        return view
    }

    // MARK: - E5: Output Filtering (Focus Mode) Tests

    func testTextFilterFiltersMatchingLines() {
        let view = makeView()
        let output = """
        [INFO] build started\r
        [ERROR] cannot find symbol 'Foo'\r
        [INFO] compiling submodules\r
        [ERROR] failed with exit code 1\r
        [DEBUG] cleanup complete\r

        """
        view.feed(data: Data(output.utf8))

        var filterReportedActive: Bool?
        var filterMatchCount: Int?
        var filterTotalCount: Int?
        view.onOutputFilterChanged = { active, matches, total in
            filterReportedActive = active
            filterMatchCount = matches
            filterTotalCount = total
        }

        // Set output filter for "[ERROR]"
        view.setOutputFilter(query: "[ERROR]", isRegex: false)

        XCTAssertTrue(view.isOutputFilterActive)
        XCTAssertEqual(view.outputFilterMatchingLines.count, 2)
        XCTAssertEqual(filterReportedActive, true)
        XCTAssertEqual(filterMatchCount, 2)
        XCTAssertGreaterThanOrEqual(filterTotalCount ?? 0, 5)

        let matchingTexts = view.outputFilterMatchingLines.map { $0.text }
        XCTAssertTrue(matchingTexts.contains { $0.contains("cannot find symbol 'Foo'") })
        XCTAssertTrue(matchingTexts.contains { $0.contains("failed with exit code 1") })
        XCTAssertFalse(matchingTexts.contains { $0.contains("compiling submodules") })

        let filteredPlainText = view.plainText()
        XCTAssertTrue(filteredPlainText.contains("cannot find symbol 'Foo'"))
        XCTAssertTrue(filteredPlainText.contains("failed with exit code 1"))
        XCTAssertFalse(filteredPlainText.contains("compiling submodules"))
    }

    func testRegexFilterFiltersMatchingLines() {
        let view = makeView()
        let output = """
        GET /index.html 200 OK\r
        POST /api/login 401 Unauthorized\r
        GET /assets/style.css 304 Not Modified\r
        POST /api/checkout 500 Internal Server Error\r
        GET /favicon.ico 404 Not Found\r

        """
        view.feed(data: Data(output.utf8))

        // Match HTTP 4xx and 5xx errors with regex
        view.setOutputFilter(query: "\\b[45]\\d{2}\\b", isRegex: true)

        XCTAssertTrue(view.isOutputFilterActive)
        XCTAssertEqual(view.outputFilterMatchingLines.count, 3)

        let matchingTexts = view.outputFilterMatchingLines.map { $0.text }
        XCTAssertTrue(matchingTexts.contains { $0.contains("401 Unauthorized") })
        XCTAssertTrue(matchingTexts.contains { $0.contains("500 Internal Server Error") })
        XCTAssertTrue(matchingTexts.contains { $0.contains("404 Not Found") })
        XCTAssertFalse(matchingTexts.contains { $0.contains("200 OK") })
        XCTAssertFalse(matchingTexts.contains { $0.contains("304 Not Modified") })
    }

    func testLineOrderingPreserved() {
        let view = makeView()
        var lines: [String] = []
        for i in 1...20 {
            if i % 3 == 0 {
                lines.append("Match item \(i)")
            } else {
                lines.append("Other item \(i)")
            }
        }
        let output = lines.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(output.utf8))

        view.setOutputFilter(query: "Match item", isRegex: false)

        XCTAssertEqual(view.outputFilterMatchingLines.count, 6)

        // Verify order is strictly monotonically increasing
        var previousRetainedIndex = -1
        for match in view.outputFilterMatchingLines {
            XCTAssertGreaterThan(match.retainedRowIndex, previousRetainedIndex)
            previousRetainedIndex = match.retainedRowIndex
        }

        // Verify content order matches chronological output
        let matchedNumbers = view.outputFilterMatchingLines.compactMap { line -> Int? in
            let components = line.text.components(separatedBy: "Match item ")
            guard components.count > 1, let num = Int(components[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return num
        }
        XCTAssertEqual(matchedNumbers, [3, 6, 9, 12, 15, 18])
    }

    func testNonMatchingLinesTemporarilyHidden() {
        let view = makeView()
        let output = """
        Line Alpha\r
        Line Beta\r
        Line Gamma\r
        Line Delta\r

        """
        view.feed(data: Data(output.utf8))

        view.setOutputFilter(query: "Beta", isRegex: false)

        XCTAssertEqual(view.outputFilterMatchingLines.count, 1)
        XCTAssertTrue(view.outputFilterMatchingLines[0].text.contains("Beta"))

        let filteredPlainText = view.plainText()
        XCTAssertTrue(filteredPlainText.contains("Beta"))
        XCTAssertFalse(filteredPlainText.contains("Alpha"))
        XCTAssertFalse(filteredPlainText.contains("Gamma"))
        XCTAssertFalse(filteredPlainText.contains("Delta"))
    }

    func testScrollingOverFilteredMatches() {
        let view = makeView()
        // Feed 40 lines
        var lines: [String] = []
        for i in 1...40 {
            lines.append("FilterMatch row \(i)")
        }
        let output = lines.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(output.utf8))

        view.setOutputFilter(query: "FilterMatch", isRegex: false)
        XCTAssertGreaterThanOrEqual(view.outputFilterMatchingLines.count, 40)
        XCTAssertEqual(view.outputFilterScrollOffset, 0)

        // Scroll up
        view.scrollViewportUp(lines: 5)
        XCTAssertEqual(view.outputFilterScrollOffset, 5)

        view.scrollViewportUp(lines: 10)
        XCTAssertEqual(view.outputFilterScrollOffset, 15)

        // Scroll down
        view.scrollViewportDown(lines: 4)
        XCTAssertEqual(view.outputFilterScrollOffset, 11)

        // Scroll to offset
        view.scrollToOffset(2)
        XCTAssertEqual(view.outputFilterScrollOffset, 2)

        // Scroll to bottom
        view.scrollViewportToBottom()
        XCTAssertEqual(view.outputFilterScrollOffset, 0)
    }

    func testClearOutputFilterRestoresCompleteScrollbackWithoutMutation() {
        let view = makeView()
        let output = """
        First line of output\r
        Targeted match line\r
        Last line of output\r

        """
        view.feed(data: Data(output.utf8))

        let originalPlainText = view.plainText()
        XCTAssertTrue(originalPlainText.contains("First line of output"))
        XCTAssertTrue(originalPlainText.contains("Targeted match line"))
        XCTAssertTrue(originalPlainText.contains("Last line of output"))

        // Activate filter
        view.setOutputFilter(query: "Targeted match", isRegex: false)
        XCTAssertTrue(view.isOutputFilterActive)
        XCTAssertEqual(view.outputFilterMatchingLines.count, 1)
        XCTAssertFalse(view.plainText().contains("First line of output"))

        // Clear filter
        view.clearOutputFilter()
        XCTAssertFalse(view.isOutputFilterActive)
        XCTAssertEqual(view.outputFilterMatchingLines.count, 0)

        // Complete scrollback is immediately restored without mutation
        let restoredPlainText = view.plainText()
        XCTAssertTrue(restoredPlainText.contains("First line of output"))
        XCTAssertTrue(restoredPlainText.contains("Targeted match line"))
        XCTAssertTrue(restoredPlainText.contains("Last line of output"))
    }

    func testToggleOutputFilter() {
        let view = makeView()
        let output = "Test line 1\r\nTest line 2\r\n"
        view.feed(data: Data(output.utf8))

        XCTAssertFalse(view.isOutputFilterActive)

        // Toggle on
        view.toggleOutputFilter()
        XCTAssertTrue(view.isOutputFilterActive)

        // Toggle off
        view.toggleOutputFilter()
        XCTAssertFalse(view.isOutputFilterActive)
    }

    func testEmptyMatchesShowsStateWithoutCrash() {
        let view = makeView()
        let output = "Normal output text line\r\n"
        view.feed(data: Data(output.utf8))

        view.setOutputFilter(query: "NON_EXISTENT_PATTERN_XYZ", isRegex: false)
        XCTAssertTrue(view.isOutputFilterActive)
        XCTAssertEqual(view.outputFilterMatchingLines.count, 0)

        // Verify filtered frame rendering does not crash and handles zero matches
        view.setNeedsDisplay(view.bounds)
        view.displayIfNeeded()
    }
}
#endif
