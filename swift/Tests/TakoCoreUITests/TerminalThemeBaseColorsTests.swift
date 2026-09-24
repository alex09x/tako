import CoreGraphics
import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit)
import AppKit

/// The view hands its theme to the engine as base colors. Before this, the
/// app fed the theme in as OSC 10/11/4 once at startup: a program that reset
/// its colors on exit (OSC 110/111/104) got the engine's built-ins, a config
/// reload never reached the engine, and the iOS app never sent a palette.
@MainActor
final class TerminalThemeBaseColorsTests: XCTestCase {
    private func theme(fg: (UInt8, UInt8, UInt8), bg: (UInt8, UInt8, UInt8), red: (UInt8, UInt8, UInt8)) -> TerminalTheme {
        var theme = TerminalTheme.takoDefault
        theme.foreground = srgb(r: fg.0, g: fg.1, b: fg.2)
        theme.background = srgb(r: bg.0, g: bg.1, b: bg.2)
        theme.palette[1] = srgb(r: red.0, g: red.1, b: red.2)
        return theme
    }

    private func fg(_ core: TakoCore, col: UInt32) throws -> [UInt8] {
        let cell = try XCTUnwrap(core.getCell(row: 0, col: col))
        return [cell.fgR, cell.fgG, cell.fgB]
    }

    private func bg(_ core: TakoCore, col: UInt32) throws -> [UInt8] {
        let cell = try XCTUnwrap(core.getCell(row: 0, col: col))
        return [cell.bgR, cell.bgG, cell.bgB]
    }

    func testANewViewGivesTheEngineItsThemeColors() throws {
        let core = TakoCore(cols: 20, rows: 2)
        let view = TakoTerminalNSView(core: core, theme: theme(fg: (1, 2, 3), bg: (4, 5, 6), red: (7, 8, 9)))

        core.feed(bytes: Data("A\u{1b}[31mB".utf8))

        XCTAssertEqual(try fg(core, col: 0), [1, 2, 3])
        XCTAssertEqual(try bg(core, col: 0), [4, 5, 6])
        XCTAssertEqual(try fg(core, col: 1), [7, 8, 9])
        _ = view
    }

    func testAProgramResettingItsColorsLandsOnTheThemeNotTheBuiltIns() throws {
        let core = TakoCore(cols: 20, rows: 2)
        let view = TakoTerminalNSView(core: core, theme: theme(fg: (1, 2, 3), bg: (4, 5, 6), red: (7, 8, 9)))

        core.feed(bytes: Data("\u{1b}]10;#ffffff\u{07}\u{1b}]4;1;#ffffff\u{07}".utf8))
        core.feed(bytes: Data("\u{1b}]110\u{07}\u{1b}]104\u{07}A\u{1b}[31mB".utf8))

        XCTAssertEqual(try fg(core, col: 0), [1, 2, 3])
        XCTAssertEqual(try fg(core, col: 1), [7, 8, 9])
        _ = view
    }

    func testChangingTheThemeRecolorsWhatTheProgramLeftAlone() throws {
        let core = TakoCore(cols: 20, rows: 2)
        let view = TakoTerminalNSView(core: core, theme: theme(fg: (1, 2, 3), bg: (4, 5, 6), red: (7, 8, 9)))
        // The program picks its own background; the foreground stays themed.
        core.feed(bytes: Data("\u{1b}]11;#0a0b0c\u{07}".utf8))

        view.theme = theme(fg: (11, 12, 13), bg: (14, 15, 16), red: (17, 18, 19))
        core.feed(bytes: Data("A\u{1b}[31mB".utf8))

        XCTAssertEqual(try fg(core, col: 0), [11, 12, 13])
        XCTAssertEqual(try bg(core, col: 0), [10, 11, 12])
        XCTAssertEqual(try fg(core, col: 1), [17, 18, 19])
    }

    func testAResetKeepsTheThemeColors() throws {
        let core = TakoCore(cols: 20, rows: 2)
        let view = TakoTerminalNSView(core: core, theme: theme(fg: (1, 2, 3), bg: (4, 5, 6), red: (7, 8, 9)))

        core.reset()
        core.feed(bytes: Data("A".utf8))

        XCTAssertEqual(try fg(core, col: 0), [1, 2, 3])
        _ = view
    }

    func testColorsAreSentAsRoundedSRGBBytes() throws {
        let half = try XCTUnwrap(TakoCore.rgb(srgb(0.5, 0.25, 1)))
        XCTAssertEqual([half.r, half.g, half.b], [128, 64, 255])

        // Every byte a `#rrggbb` can spell survives the trip unchanged.
        for value in UInt8.min...UInt8.max {
            let rgb = try XCTUnwrap(TakoCore.rgb(srgb(r: value, g: value, b: value)))
            XCTAssertEqual(rgb.r, value)
        }

        // Out-of-gamut components are clamped rather than wrapped.
        let p3 = try XCTUnwrap(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [1, 0, 0, 1]))
        let red = try XCTUnwrap(TakoCore.rgb(p3))
        XCTAssertEqual(red.r, 255)
    }
}
#endif
