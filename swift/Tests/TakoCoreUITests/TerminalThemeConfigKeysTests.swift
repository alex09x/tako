import CoreGraphics
import Foundation
import XCTest
@testable import TakoCoreUI

/// The seven appearance keys the parser has long accepted but nothing read:
/// `selection-foreground`, `selection-invert-fg-bg`, `cursor-opacity`,
/// `cursor-thickness`, `window-padding-balance`, `window-padding-color` and
/// `window-colorspace`. One test per key proves the parsed value and its
/// default, plus that an invalid value falls back to the default rather than
/// being silently accepted.
final class TerminalThemeConfigKeysTests: XCTestCase {
    private func colorComponents(_ color: CGColor) -> (CGFloat, CGFloat, CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else {
            return (0, 0, 0)
        }
        return (components[0], components[1], components[2])
    }

    // MARK: - selection-foreground

    func testSelectionForegroundParsesAndDefaultsToNil() {
        XCTAssertNil(TerminalTheme.takoDefault.selectionForeground)

        let theme = TerminalTheme.parse(config: "selection-foreground = #ff00ff")
        let color = try? XCTUnwrap(theme.selectionForeground)
        let (r, g, b) = colorComponents(color ?? srgb(r: 0, g: 0, b: 0))
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 1.0, accuracy: 0.01)

        // Invalid color text: falls back to the default (nil), not a bogus color.
        let invalid = TerminalTheme.parse(config: "selection-foreground = not-a-color")
        XCTAssertNil(invalid.selectionForeground)
    }

    // MARK: - selection-invert-fg-bg

    func testSelectionInvertFgBgParsesAndDefaultsToFalse() {
        XCTAssertFalse(TerminalTheme.takoDefault.selectionInvertFgBg)

        let on = TerminalTheme.parse(config: "selection-invert-fg-bg = true")
        XCTAssertTrue(on.selectionInvertFgBg)

        let off = TerminalTheme.parse(config: "selection-invert-fg-bg = false")
        XCTAssertFalse(off.selectionInvertFgBg)

        // Invalid boolean text: falls back to the default (false).
        let invalid = TerminalTheme.parse(config: "selection-invert-fg-bg = maybe")
        XCTAssertFalse(invalid.selectionInvertFgBg)
    }

    // MARK: - cursor-opacity

    func testCursorOpacityParsesClampsAndDefaultsToOne() {
        XCTAssertEqual(TerminalTheme.takoDefault.cursorOpacity, 1.0)

        let half = TerminalTheme.parse(config: "cursor-opacity = 0.5")
        XCTAssertEqual(half.cursorOpacity, 0.5, accuracy: 0.001)

        // Out-of-range values are clamped, matching `background-opacity`.
        let low = TerminalTheme.parse(config: "cursor-opacity = -1")
        XCTAssertEqual(low.cursorOpacity, 0.0)
        let high = TerminalTheme.parse(config: "cursor-opacity = 5")
        XCTAssertEqual(high.cursorOpacity, 1.0)

        // Invalid number text: falls back to the default (1.0).
        let invalid = TerminalTheme.parse(config: "cursor-opacity = not-a-number")
        XCTAssertEqual(invalid.cursorOpacity, 1.0)
    }

    // MARK: - cursor-thickness

    func testCursorThicknessParsesAndDefaultsToNil() {
        XCTAssertNil(TerminalTheme.takoDefault.cursorThickness)

        let theme = TerminalTheme.parse(config: "cursor-thickness = 4.5")
        XCTAssertEqual(theme.cursorThickness, 4.5)

        // Zero or negative thickness is not a usable value: falls back to nil.
        let zero = TerminalTheme.parse(config: "cursor-thickness = 0")
        XCTAssertNil(zero.cursorThickness)
        let negative = TerminalTheme.parse(config: "cursor-thickness = -2")
        XCTAssertNil(negative.cursorThickness)

        // Invalid number text: falls back to the default (nil).
        let invalid = TerminalTheme.parse(config: "cursor-thickness = thick")
        XCTAssertNil(invalid.cursorThickness)
    }

    // MARK: - window-padding-balance

    func testWindowPaddingBalanceParsesAndDefaultsToFalse() {
        XCTAssertFalse(TerminalTheme.takoDefault.windowPaddingBalance)

        let on = TerminalTheme.parse(config: "window-padding-balance = true")
        XCTAssertTrue(on.windowPaddingBalance)

        // Invalid boolean text: falls back to the default (false).
        let invalid = TerminalTheme.parse(config: "window-padding-balance = yes")
        XCTAssertFalse(invalid.windowPaddingBalance)
    }

    // MARK: - window-padding-color

    func testWindowPaddingColorParsesAndDefaultsToBackground() {
        XCTAssertEqual(TerminalTheme.takoDefault.windowPaddingColor, .background)

        let extend = TerminalTheme.parse(config: "window-padding-color = extend")
        XCTAssertEqual(extend.windowPaddingColor, .extend)

        let extendAlways = TerminalTheme.parse(config: "window-padding-color = extend-always")
        XCTAssertEqual(extendAlways.windowPaddingColor, .extendAlways)

        let background = TerminalTheme.parse(config: "window-padding-color = background")
        XCTAssertEqual(background.windowPaddingColor, .background)

        // Invalid keyword: falls back to the default (background).
        let invalid = TerminalTheme.parse(config: "window-padding-color = sparkly")
        XCTAssertEqual(invalid.windowPaddingColor, .background)
    }

    // MARK: - window-colorspace

    func testWindowColorSpaceParsesAndDefaultsToSRGB() {
        XCTAssertEqual(TerminalTheme.takoDefault.windowColorSpace, .srgb)

        let p3 = TerminalTheme.parse(config: "window-colorspace = display-p3")
        XCTAssertEqual(p3.windowColorSpace, .displayP3)

        let srgb = TerminalTheme.parse(config: "window-colorspace = srgb")
        XCTAssertEqual(srgb.windowColorSpace, .srgb)

        // Invalid keyword: falls back to the default (srgb).
        let invalid = TerminalTheme.parse(config: "window-colorspace = rec2020")
        XCTAssertEqual(invalid.windowColorSpace, .srgb)
    }

    // MARK: - A theme (not just a config) can also set these keys.

    func testApplyingThemeCanSetSelectionAndCursorKeysButNotWindowKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalThemeConfigKeysTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        selection-foreground = #00ff00
        selection-invert-fg-bg = true
        cursor-opacity = 0.25
        cursor-thickness = 6
        window-padding-balance = true
        window-padding-color = extend
        window-colorspace = display-p3
        """.write(to: dir.appendingPathComponent("my-theme"), atomically: true, encoding: .utf8)

        let base = TerminalTheme(windowPadding: 20, windowPaddingBalance: false, windowPaddingColor: .background)
        let merged = base.applyingTheme(named: "my-theme", searchPaths: [dir.path])

        // Selection and cursor appearance come from the theme file, like every
        // other color the theme system already carries.
        XCTAssertNotNil(merged.selectionForeground)
        XCTAssertTrue(merged.selectionInvertFgBg)
        XCTAssertEqual(merged.cursorOpacity, 0.25, accuracy: 0.001)
        XCTAssertEqual(merged.cursorThickness, 6)

        // Window layout keys are config-proper, like `window-padding`: a
        // theme file must not override what the user configured directly.
        XCTAssertFalse(merged.windowPaddingBalance)
        XCTAssertEqual(merged.windowPaddingColor, .background)
        XCTAssertEqual(merged.windowColorSpace, .srgb)
    }
}
