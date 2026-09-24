import AppKit
import CoreText
import Foundation
import Testing
@testable import Tako

/// Reload Configuration applies the font keys to terminals already open, as
/// upstream does: the styled faces, synthesis, features and the adjusted
/// cell and underline metrics all change on the surface on screen.
@Suite
struct SurfaceFontConfigReloadTests {
    private func name(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }

    private func installed(_ family: String) -> Bool {
        CTFontCopyFamilyName(CTFontCreateWithName(family as CFString, 13, nil)) as String == family
    }

    @Test @MainActor
    func reloadingAppliesTheStyledFamiliesAndMetricAdjustments() throws {
        let config = try TemporaryConfig("font-family = Menlo\n")
        let app = Tako.App(configPath: config.temporaryFile.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }
        let before = view.renderer.metrics
        #expect(name(before.boldFont) == "Menlo-Bold")
        #expect(!before.hasFontFeatures)

        try """
        font-family = Menlo
        font-family-bold = Courier New
        font-family-italic = Courier New
        font-family-bold-italic = Courier New
        font-feature = -calt
        adjust-cell-width = +2
        adjust-cell-height = +4
        adjust-font-baseline = +1
        adjust-underline-position = +3
        adjust-underline-thickness = +1
        """.write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        app.reloadConfig()

        let after = view.renderer.metrics
        if installed("Courier New") {
            #expect(name(after.boldFont) == "CourierNewPS-BoldMT")
            #expect(name(after.italicFont) == "CourierNewPS-ItalicMT")
            #expect(name(after.boldItalicFont) == "CourierNewPS-BoldItalicMT")
        }
        #expect(after.hasFontFeatures)
        #expect(view.cellWidth == before.cellWidth + 2)
        #expect(view.cellHeight == before.cellHeight + 4)
        // Two points from centring the taller cell, one from the key.
        #expect(after.baseline == before.baseline + 3)
        #expect(after.underlinePosition == before.underlinePosition + 2 + 3)
        #expect(after.underlineThickness == 2)
        if let metal = view.metalRenderer {
            #expect(metal.planner.metrics.cellWidth == view.cellWidth)
            #expect(metal.planner.metrics.underlineThickness == 2)
        }
    }

    @Test @MainActor
    func reloadingAppliesTheFaceStyles() throws {
        guard installed("Helvetica Neue") else { return }
        let config = try TemporaryConfig("font-family = Helvetica Neue\n")
        let app = Tako.App(configPath: config.temporaryFile.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }
        #expect(name(view.renderer.metrics.font) == "HelveticaNeue")

        try """
        font-family = Helvetica Neue
        font-style = Light
        font-style-bold = Medium
        font-style-italic = Light Italic
        font-style-bold-italic = false
        """.write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        app.reloadConfig()

        let metrics = view.renderer.metrics
        #expect(name(metrics.font) == "HelveticaNeue-Light")
        #expect(name(metrics.boldFont) == "HelveticaNeue-Medium")
        #expect(name(metrics.italicFont) == "HelveticaNeue-LightItalic")
        #expect(name(metrics.boldItalicFont) == "HelveticaNeue-Light", "disabled: the regular face")
    }

    @Test @MainActor
    func reloadingAppliesSyntheticStyle() throws {
        guard installed("Monaco") else { return }
        let config = try TemporaryConfig("font-family = Monaco\n")
        let app = Tako.App(configPath: config.temporaryFile.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }
        #expect(view.renderer.metrics.boldIsSynthetic)

        try "font-family = Monaco\nfont-synthetic-style = no-bold\n"
            .write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        app.reloadConfig()

        #expect(!view.renderer.metrics.boldIsSynthetic)
        #expect(view.renderer.metrics.boldItalicIsSynthetic)
    }
}
