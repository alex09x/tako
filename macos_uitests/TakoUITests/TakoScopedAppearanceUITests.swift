/*
 * tako — Real workspace and split-pane appearance journeys
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

final class TakoScopedAppearanceUITests: TakoCustomConfigCase {
    private typealias H = TakoScopedAppearanceHelpers

    @MainActor func testWorkspaceAndPaneMenusAndModalContainment() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let original = try Data(contentsOf: env.configFile)
        let dialog = H.openWorkspaceAppearance(in: app)
        XCTAssertTrue(dialog.label.contains("Workspace: Default"))
        for key in ["1", "2", "4", "5"] {
            dialog.typeKey(key, modifierFlags: .command)
            H.assertValue(dialog, contains: "Themes:")
        }
        dialog.typeKey("d", modifierFlags: .command)
        XCTAssertEqual(H.leafPanes(in: app).count, 1)
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "workspace-editor", to: self)
        H.dismissDialog(dialog, in: app)
        let pane = H.openPaneAppearance(in: app, paneID: try XCTUnwrap(env.primaryPaneID))
        XCTAssertTrue(pane.label.contains("Pane appearance"))
        H.dismissDialog(pane, in: app)
        XCTAssertEqual(try Data(contentsOf: env.configFile), original)
    }

    @MainActor func testWorkspaceThemeAndResetChangeRenderedPixels() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let pane = app.groups["Terminal pane"].firstMatch
        let before = try XCTUnwrap(H.samplePixelColor(from: pane))
        let dialog = H.openWorkspaceAppearance(in: app)
        H.search("Ocean", in: dialog)
        XCTAssertFalse(app.buttons["ThemePresetSaveButton"].exists)
        app.buttons["ThemePresetChoice-Tako Ocean"].click()
        H.assertValue(dialog, contains: "setting_custom_success: theme = Tako Ocean")
        H.dismissDialog(dialog, in: app)
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(before, color) > 0.04 })
        H.attachScreenshot(pane.screenshot(), name: "workspace-theme-rendered", to: self)
        let reset = H.openWorkspaceAppearance(in: app)
        app.buttons["SettingsResetButton"].click()
        H.assertValue(reset, contains: "setting_reset_success: theme")
        H.dismissDialog(reset, in: app)
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(before, color) < 0.03 })
    }

    @MainActor func testSplitPaneOwnsOnlyItsAppearance() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let first = try XCTUnwrap(env.primaryPaneID)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(H.wait { H.leafPanes(in: app).count == 2 })
        let panes = H.leafPanes(in: app)
        XCTAssertEqual(panes.count, 2)
        let left = panes[0], right = panes[1]
        let second = try env.identifyPane(right, title: "Scope Split", slot: "split")
        let beforeLeft = try XCTUnwrap(H.samplePixelColor(from: left))
        let dialog = H.openPaneAppearance(in: app, paneID: second, isChild: true)
        H.search("Ocean", in: dialog)
        app.buttons["ThemePresetChoice-Tako Ocean"].click()
        H.assertValue(dialog, contains: "setting_custom_success: theme = Tako Ocean")
        H.search("", in: dialog)
        app.buttons["ThemePresetEditButton"].click()
        let editor = app.groups["ThemePresetEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeKey("5", modifierFlags: .command)
        for _ in 0..<4 { editor.typeKey(.rightArrow, modifierFlags: []) }
        app.buttons["ThemePresetSaveButton"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(try env.paneThemeConfig(second).contains("font-size = 17"))
        H.dismissDialog(dialog, in: app)
        XCTAssertTrue(H.wait {
            guard let a = H.samplePixelColor(from: left), let b = H.samplePixelColor(from: right) else { return false }
            return H.colorDifference(beforeLeft, a) < 0.03 && H.colorDifference(a, b) > 0.04
        })
        XCTAssertNil(try env.paneStyle(first)["theme"])
        XCTAssertNil(try env.paneStyle(first)["font-size"])
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "independent-split-panes", to: self)
    }

    @MainActor func testFontSizeAndFamilyReachActualRenderedGlyphs() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let id = try XCTUnwrap(env.primaryPaneID)
        let pane = app.groups["Terminal pane"].firstMatch
        pane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        var initial: H.GlyphObservation?
        XCTAssertTrue(H.wait { initial = try? H.glyphs(in: pane); return initial != nil })
        let initialGlyphs = try XCTUnwrap(initial)
        H.attachScreenshot(initialGlyphs.screenshot, name: "font-size-before", to: self)
        let dialog = H.openPaneAppearance(in: app, paneID: id)
        app.buttons["ThemePresetEditButton"].click()
        let sizeEditor = app.groups["ThemePresetEditor"]
        XCTAssertTrue(sizeEditor.waitForExistence(timeout: 5))
        sizeEditor.typeKey("5", modifierFlags: .command)
        for _ in 0..<4 { sizeEditor.typeKey(.rightArrow, modifierFlags: []) }
        XCTAssertNil(try env.paneStyle(id)["font-size"])
        app.buttons["ThemePresetSaveButton"].click()
        XCTAssertTrue(sizeEditor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(try env.paneThemeConfig(id).contains("font-size = 17"))
        H.dismissDialog(dialog, in: app)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).click()
        var enlarged: H.GlyphObservation?
        let grew = H.wait {
            enlarged = try? H.glyphs(in: pane)
            return (enlarged?.bounds.width ?? 0) > initialGlyphs.bounds.width * 1.15
                && (enlarged?.bounds.height ?? 0) > initialGlyphs.bounds.height * 1.15
        }
        if let enlarged { H.attachScreenshot(enlarged.screenshot, name: "font-size-after", to: self) }
        XCTAssertTrue(grew, "Before glyph bounds: \(initialGlyphs.bounds); after: \(String(describing: enlarged?.bounds))")
        H.attachScreenshot(try XCTUnwrap(enlarged).screenshot, name: "font-size-rendered", to: self)
        let reset = H.openPaneAppearance(in: app, paneID: id)
        app.buttons["ThemePresetEditButton"].click()
        let resetEditor = app.groups["ThemePresetEditor"]
        XCTAssertTrue(resetEditor.waitForExistence(timeout: 5))
        resetEditor.typeKey("5", modifierFlags: .command)
        for _ in 0..<4 { resetEditor.typeKey(.leftArrow, modifierFlags: []) }
        app.buttons["ThemePresetSaveButton"].click()
        XCTAssertTrue(resetEditor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(try env.paneThemeConfig(id).contains("font-size = 13"))
        H.dismissDialog(reset, in: app)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).click()
        var resetGlyphs: H.GlyphObservation?
        XCTAssertTrue(H.wait {
            resetGlyphs = try? H.glyphs(in: pane)
            return resetGlyphs?.bounds.size == initialGlyphs.bounds.size && resetGlyphs?.pixels == initialGlyphs.pixels
        }, "Reset must restore the same glyph size and ink mask before testing family changes")
        let familyBaseline = try XCTUnwrap(resetGlyphs)
        XCTAssertNil(try env.paneStyle(id)["font-size"])
        let family = H.openPaneAppearance(in: app, paneID: id)
        app.buttons["ThemePresetEditButton"].click()
        let familyEditor = app.groups["ThemePresetEditor"]
        XCTAssertTrue(familyEditor.waitForExistence(timeout: 5))
        familyEditor.typeKey("4", modifierFlags: .command)
        H.search("Monaco", in: familyEditor)
        familyEditor.typeKey(.return, modifierFlags: [])
        H.assertValue(familyEditor, contains: "setting_custom_success: font-family = Monaco")
        app.buttons["ThemePresetSaveButton"].click()
        XCTAssertTrue(familyEditor.waitForNonExistence(timeout: 5))
        H.dismissDialog(family, in: app)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).click()
        XCTAssertTrue(try env.paneThemeConfig(id).contains("font-family = Monaco"))
        XCTAssertTrue(H.wait { guard let glyphs = try? H.glyphs(in: pane) else { return false }; return glyphs.pixels != familyBaseline.pixels })
        H.attachScreenshot(pane.screenshot(), name: "font-family-rendered", to: self)
    }
}
