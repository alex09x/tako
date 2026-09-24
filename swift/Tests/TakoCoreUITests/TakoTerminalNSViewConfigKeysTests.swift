import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Metal

/// The seven appearance keys reach an *open* terminal on a theme reload --
/// the same path upstream's `theme` and `cursor-style` already use, since a
/// theme assignment rebuilds both the CoreText renderer and (if available)
/// the Metal one from the new value.
@MainActor
final class TakoTerminalNSViewConfigKeysTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func testReloadingTheThemeAppliesTheNewKeysToTheCoreTextRenderer() {
        TakoTerminalNSView.isMetalDisabledForTesting = true
        defer { TakoTerminalNSView.isMetalDisabledForTesting = false }

        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertNil(view.renderer.selectionForeground)
        XCTAssertFalse(view.renderer.selectionInvertFgBg)
        XCTAssertEqual(view.renderer.cursorOpacity, 1.0)
        XCTAssertNil(view.renderer.cursorThickness)

        view.theme = TerminalTheme.parse(config: """
        selection-foreground = #ff00ff
        selection-invert-fg-bg = true
        cursor-opacity = 0.4
        cursor-thickness = 5
        """)

        XCTAssertNotNil(view.renderer.selectionForeground)
        XCTAssertTrue(view.renderer.selectionInvertFgBg)
        XCTAssertEqual(view.renderer.cursorOpacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(view.renderer.cursorThickness, 5)
    }

    func testReloadingTheThemeAppliesWindowPaddingKeysToTheNextDraw() {
        TakoTerminalNSView.isMetalDisabledForTesting = true
        defer { TakoTerminalNSView.isMetalDisabledForTesting = false }

        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.theme = TerminalTheme.parse(config: """
        window-padding-balance = true
        window-padding-color = extend
        """)
        XCTAssertTrue(view.theme.windowPaddingBalance)
        XCTAssertEqual(view.theme.windowPaddingColor, .extend)
    }

    // MARK: - window-colorspace / cursor-thickness on the Metal path

    /// The standalone Simulator/CLI XCTest runner links no default metallib,
    /// so the shader source is compiled here the same way the other Metal
    /// tests in this target do it.
    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    func testReloadingTheThemeAppliesColorSpaceAndCursorThicknessToTheMetalRenderer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let library = try makeLibrary(device: device)
        TakoTerminalNSView.metalLibraryProviderForTesting = { _ in library }
        defer { TakoTerminalNSView.metalLibraryProviderForTesting = nil }

        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        let defaultRenderer = try XCTUnwrap(view.metalRendererForTesting, "no Metal renderer built")
        XCTAssertEqual(defaultRenderer.planner.colorSpace, .sRGB)
        XCTAssertNil(defaultRenderer.planner.cursorThickness)

        view.theme = TerminalTheme.parse(config: """
        window-colorspace = display-p3
        cursor-thickness = 7
        """)

        let reloaded = try XCTUnwrap(view.metalRendererForTesting, "theme reload dropped the Metal renderer")
        XCTAssertEqual(reloaded.planner.colorSpace, .displayP3)
        XCTAssertEqual(reloaded.planner.cursorThickness, 7)

        // An invalid keyword on reload leaves the prior value alone rather
        // than resetting to the default.
        view.theme = TerminalTheme.parse(config: "window-colorspace = not-a-space", base: view.theme)
        let fallback = try XCTUnwrap(view.metalRendererForTesting)
        XCTAssertEqual(fallback.planner.colorSpace, .displayP3)
    }
}
#endif
