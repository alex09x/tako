import CoreGraphics
import Foundation
import XCTest
@testable import TakoCoreUI

final class TerminalThemeTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalThemeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testALaterConfigFileOverridesAnEarlierOnesThemeAndKeepsTheRest() throws {
        let themeDirectory = temporaryDirectory.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectory, withIntermediateDirectories: true)
        try """
        background = #101112
        foreground = #202122
        cursor-color = #303132
        palette = 1=#404142
        """.write(
            to: themeDirectory.appendingPathComponent("TokyoNight"),
            atomically: true,
            encoding: .utf8)

        let earlierConfig = temporaryDirectory.appendingPathComponent("earlier-config")
        try """
        theme = TokyoNight
        font-size = 17
        """.write(to: earlierConfig, atomically: true, encoding: .utf8)

        let laterConfig = temporaryDirectory.appendingPathComponent("later-config")
        try "foreground = #abcdef\n".write(to: laterConfig, atomically: true, encoding: .utf8)

        let theme = TerminalTheme.loadUserConfig(
            paths: [earlierConfig.path, laterConfig.path],
            themeSearchPaths: [themeDirectory.path])

        assertRGB(theme.background, 0x10, 0x11, 0x12)
        assertRGB(theme.foreground, 0xab, 0xcd, 0xef)
        assertRGB(theme.cursorColor, 0x30, 0x31, 0x32)
        assertRGB(try XCTUnwrap(theme.palette[1]), 0x40, 0x41, 0x42)
        XCTAssertEqual(theme.fontSize, 17)
    }

    func testExplicitColorsOutrankThemeRegardlessOfConfigOrder() throws {
        let themeDirectory = temporaryDirectory.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectory, withIntermediateDirectories: true)
        try """
        background = #111111
        foreground = #222222
        palette = 2=#333333
        """.write(
            to: themeDirectory.appendingPathComponent("Fixture"),
            atomically: true,
            encoding: .utf8)

        let theme = TerminalTheme.parse(
            config: """
            foreground = #aabbcc
            palette = 2=#ddeeff
            theme = Fixture
            """,
            base: .takoDefault,
            honourTheme: true,
            themeSearchPaths: [themeDirectory.path])

        assertRGB(theme.background, 0x11, 0x11, 0x11)
        assertRGB(theme.foreground, 0xaa, 0xbb, 0xcc)
        assertRGB(try XCTUnwrap(theme.palette[2]), 0xdd, 0xee, 0xff)
    }

    func testDefaultMetricsAreNilAndPreserveDerivedMetrics() {
        let theme = TerminalTheme.takoDefault
        XCTAssertNil(theme.cellWidth)
        XCTAssertNil(theme.cellHeight)

        let derived = TerminalRenderer.Metrics(fontSize: theme.fontSize, fontName: theme.fontFamily)
        let fromTheme = TerminalRenderer.Metrics(theme: theme)

        XCTAssertEqual(fromTheme.cellWidth, derived.cellWidth)
        XCTAssertEqual(fromTheme.cellHeight, derived.cellHeight)
        XCTAssertEqual(fromTheme.baseline, derived.baseline)
    }

    func testFinitePositiveCellOverridesAreAccepted() {
        let exactWidth: CGFloat = 369.0 / 53.0
        let exactHeight: CGFloat = 764.0 / 53.0
        let theme = TerminalTheme(cellWidth: exactWidth, cellHeight: exactHeight)

        XCTAssertEqual(theme.cellWidth, exactWidth)
        XCTAssertEqual(theme.cellHeight, exactHeight)

        let metrics = TerminalRenderer.Metrics(theme: theme)
        XCTAssertEqual(metrics.cellWidth, exactWidth)
        XCTAssertEqual(metrics.cellHeight, exactHeight)
    }

    func testInvalidCellOverridesFallbackToDerivedMetrics() {
        let derived = TerminalRenderer.Metrics(fontSize: 13)

        let nonPositiveMetrics = TerminalRenderer.Metrics(fontSize: 13, cellWidth: 0, cellHeight: -10)
        XCTAssertEqual(nonPositiveMetrics.cellWidth, derived.cellWidth)
        XCTAssertEqual(nonPositiveMetrics.cellHeight, derived.cellHeight)

        let nanInfMetrics = TerminalRenderer.Metrics(fontSize: 13, cellWidth: .nan, cellHeight: .infinity)
        XCTAssertEqual(nanInfMetrics.cellWidth, derived.cellWidth)
        XCTAssertEqual(nanInfMetrics.cellHeight, derived.cellHeight)

        let negInfMetrics = TerminalRenderer.Metrics(fontSize: 13, cellWidth: -.infinity, cellHeight: 0)
        XCTAssertEqual(negInfMetrics.cellWidth, derived.cellWidth)
        XCTAssertEqual(negInfMetrics.cellHeight, derived.cellHeight)
    }

    func testThemeApplyingAndParsingPreservesCellOverrides() throws {
        let themeDirectory = temporaryDirectory.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDirectory, withIntermediateDirectories: true)
        try """
        background = #010203
        foreground = #040506
        """.write(
            to: themeDirectory.appendingPathComponent("CustomPal"),
            atomically: true,
            encoding: .utf8)

        let baseTheme = TerminalTheme(
            fontSize: 14,
            cellWidth: 369.0 / 53.0,
            cellHeight: 764.0 / 53.0
        )
        let merged = baseTheme.applyingTheme(named: "CustomPal", searchPaths: [themeDirectory.path])

        XCTAssertEqual(merged.cellWidth, 369.0 / 53.0)
        XCTAssertEqual(merged.cellHeight, 764.0 / 53.0)
        XCTAssertEqual(merged.fontSize, 14)
        assertRGB(merged.background, 0x01, 0x02, 0x03)
        assertRGB(merged.foreground, 0x04, 0x05, 0x06)

        let parsed = TerminalTheme.parse(
            config: """
            cell-width = 12.5
            cell-height = 25.0
            """
        )
        XCTAssertEqual(parsed.cellWidth, 12.5)
        XCTAssertEqual(parsed.cellHeight, 25.0)
    }

    private func assertRGB(
        _ color: CGColor,
        _ red: UInt8,
        _ green: UInt8,
        _ blue: UInt8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = color.converted(to: space, intent: .defaultIntent, options: nil)
        guard let components = converted?.components, components.count >= 3 else {
            XCTFail("Color could not be converted to sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(components[0], CGFloat(red) / 255, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(components[1], CGFloat(green) / 255, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(components[2], CGFloat(blue) / 255, accuracy: 0.0001, file: file, line: line)
    }
}
