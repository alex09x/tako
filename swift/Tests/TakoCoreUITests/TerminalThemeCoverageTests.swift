import CoreGraphics
import Foundation
import XCTest
@testable import TakoCoreUI

final class TerminalThemeCoverageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalThemeCoverageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    private func colorComponents(_ color: CGColor) -> (CGFloat, CGFloat, CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else {
            return (0, 0, 0)
        }
        return (components[0], components[1], components[2])
    }

    func testTerminalThemeMemberwiseInit() {
        let bg = CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1.0)
        let fg = CGColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1.0)
        let sel = CGColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1.0)
        let cur = CGColor(srgbRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)

        let theme = TerminalTheme(
            background: bg,
            foreground: fg,
            selectionBackground: sel,
            cursorColor: cur,
            backgroundOpacity: 0.85,
            backgroundBlur: 12,
            fontFamily: "Courier",
            fontSize: 14.0,
            cellWidth: 8.5,
            cellHeight: 18.0,
            windowPadding: 16.0,
            cursorBlink: false
        )

        XCTAssertEqual(theme.backgroundOpacity, 0.85)
        XCTAssertEqual(theme.backgroundBlur, 12)
        XCTAssertEqual(theme.fontFamily, "Courier")
        XCTAssertEqual(theme.fontSize, 14.0)
        XCTAssertEqual(theme.cellWidth, 8.5)
        XCTAssertEqual(theme.cellHeight, 18.0)
        XCTAssertEqual(theme.windowPadding, 16.0)
        XCTAssertFalse(theme.cursorBlink)
        XCTAssertTrue(theme.palette.isEmpty)
    }

    func testThemeSearchPathsAndAvailableThemes() {
        let paths = TerminalTheme.themeSearchPaths
        // The user's directories come before the bundled themes.
        XCTAssertEqual(paths.first, ("~/.config/tako-core/themes" as NSString).expandingTildeInPath)
        XCTAssertEqual(paths.last, Bundle.main.resourceURL?.appendingPathComponent("themes").path ?? "")

        let available = TerminalTheme.availableThemes()
        XCTAssertNotNil(available)
    }

    func testApplyingThemeNonExistentFallsBackToSelf() {
        let base = TerminalTheme.takoDefault
        let result = base.applyingTheme(named: "non-existent-theme-unlikely-to-exist-12345")
        XCTAssertEqual(result.fontSize, base.fontSize)
        XCTAssertEqual(result.windowPadding, base.windowPadding)
    }

    func testParseAllConfigKeysAndVariants() {
        let config = """
        # This is a comment

        invalid line without equals
        background = #010203
        foreground = 040506
        selection-background = #070809
        cursor-color = 10,20,30
        background-opacity = 0.75
        background-blur = 8
        background-blur-radius = 16
        font-family = JetBrainsMono
        font-size = 15
        cell-width = 9.25
        cell_width = 9.5
        cell-height = 19.25
        cell_height = 19.5
        window-padding-x = 12
        window-padding-y = 14
        cursor-style-blink = false
        palette = 1 = #112233
        palette = bad_format
        palette = abc = #112233
        palette = 2 = bad_color
        unknown-key = should-be-ignored
        """

        let theme = TerminalTheme.parse(config: config)
        XCTAssertEqual(theme.backgroundBlur, 16)
        XCTAssertEqual(theme.backgroundOpacity, 0.75, accuracy: 0.001)
        XCTAssertEqual(theme.fontFamily, "JetBrainsMono")
        XCTAssertEqual(theme.fontSize, 15.0)
        XCTAssertEqual(theme.cellWidth, 9.5)
        XCTAssertEqual(theme.cellHeight, 19.5)
        XCTAssertEqual(theme.padding, TerminalPadding(left: 12, right: 12, top: 14, bottom: 14))
        XCTAssertFalse(theme.cursorBlink)
        XCTAssertNotNil(theme.palette[1])
        XCTAssertNil(theme.palette[2])

        let (selR, selG, selB) = colorComponents(theme.selectionBackground)
        XCTAssertEqual(selR, 7.0 / 255.0, accuracy: 0.005)
        XCTAssertEqual(selG, 8.0 / 255.0, accuracy: 0.005)
        XCTAssertEqual(selB, 9.0 / 255.0, accuracy: 0.005)
    }

    func testParseOpacityClampingAndBlinkTrue() {
        let configLow = """
        background-opacity = -0.5
        cursor-style-blink = true
        cell-width = 8.0
        cell-height = 16.0
        window-padding-x = 6.0
        """
        let themeLow = TerminalTheme.parse(config: configLow)
        XCTAssertEqual(themeLow.backgroundOpacity, 0.0)
        XCTAssertTrue(themeLow.cursorBlink)
        XCTAssertEqual(themeLow.cellWidth, 8.0)
        XCTAssertEqual(themeLow.cellHeight, 16.0)
        XCTAssertEqual(themeLow.windowPadding, 6.0)

        let configHigh = """
        background-opacity = 1.8
        """
        let themeHigh = TerminalTheme.parse(config: configHigh)
        XCTAssertEqual(themeHigh.backgroundOpacity, 1.0)
    }

    func testParseColorFormats() {
        // Hex with #
        XCTAssertNotNil(TerminalTheme.parseColor("#ff0000"))
        // Hex without #
        XCTAssertNotNil(TerminalTheme.parseColor("00ff00"))
        // RGB comma separated
        XCTAssertNotNil(TerminalTheme.parseColor("0, 0, 255"))
        // Invalid formats
        XCTAssertNil(TerminalTheme.parseColor("12, 34"))
        XCTAssertNil(TerminalTheme.parseColor("12, 34, 56, 78"))
        XCTAssertNil(TerminalTheme.parseColor("#12345"))
        XCTAssertNil(TerminalTheme.parseColor("#1234567"))
        XCTAssertNil(TerminalTheme.parseColor("ghijkl"))
        XCTAssertNil(TerminalTheme.parseColor(""))
    }

    func testLoadUserConfig() {
        let theme = TerminalTheme.loadUserConfig()
        XCTAssertGreaterThan(theme.fontSize, 0)
    }

    func testLoadUserConfigWithNonExistentPaths() {
        let theme = TerminalTheme.loadUserConfig(
            paths: [tempDir.appendingPathComponent("nonexistent").path],
            themeSearchPaths: [tempDir.appendingPathComponent("themes").path]
        )
        XCTAssertEqual(theme.fontSize, TerminalTheme.takoDefault.fontSize)
    }
}
