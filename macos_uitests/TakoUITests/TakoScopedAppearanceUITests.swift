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
        for key in ["1", "2"] {
            dialog.typeKey(key, modifierFlags: .command)
            H.assertValue(dialog, contains: "Themes:")
        }
        dialog.typeKey("d", modifierFlags: .command)
        XCTAssertEqual(try env.paneIDs().count, 1)
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "workspace-editor", to: self)
        H.dismissDialog(dialog, in: app)
        let pane = H.openPaneAppearance(in: app)
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
        dialog.typeKey(.return, modifierFlags: [])
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
        let first = try XCTUnwrap(env.paneIDs().first)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(H.wait { (try? env.paneIDs().count) == 2 })
        let second = try XCTUnwrap(env.paneIDs().first { $0 != first })
        _ = try env.control(["title", "Scope Split", "--target", second])
        let panes = app.groups.matching(identifier: "Terminal pane").allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(panes.count, 2)
        let left = panes[0], right = panes[1]
        let beforeLeft = try XCTUnwrap(H.samplePixelColor(from: left))
        let dialog = H.openPaneAppearance(in: app, title: "Scope Split", isChild: true)
        H.search("Ocean", in: dialog)
        dialog.typeKey(.return, modifierFlags: [])
        H.assertValue(dialog, contains: "setting_custom_success: theme = Tako Ocean")
        H.search("", in: dialog)
        dialog.typeKey("5", modifierFlags: .command)
        for _ in 0..<4 { dialog.typeKey(.rightArrow, modifierFlags: []) }
        XCTAssertTrue(H.wait { (try? env.paneStyle(second)["font-size"]) == "17" })
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
        let id = try XCTUnwrap(env.paneIDs().first)
        let pane = app.groups["Terminal pane"].firstMatch
        pane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        var initial: H.GlyphObservation?
        XCTAssertTrue(H.wait { initial = try? H.glyphs(in: pane); return initial != nil })
        let initialGlyphs = try XCTUnwrap(initial)
        let dialog = H.openPaneAppearance(in: app)
        dialog.typeKey("5", modifierFlags: .command)
        for _ in 0..<4 { dialog.typeKey(.rightArrow, modifierFlags: []) }
        XCTAssertTrue(H.wait { (try? env.paneStyle(id)["font-size"]) == "17" })
        H.dismissDialog(dialog, in: app)
        var enlarged: H.GlyphObservation?
        XCTAssertTrue(H.wait {
            enlarged = try? H.glyphs(in: pane)
            return (enlarged?.bounds.width ?? 0) > initialGlyphs.bounds.width * 1.15
                && (enlarged?.bounds.height ?? 0) > initialGlyphs.bounds.height * 1.15
        })
        H.attachScreenshot(try XCTUnwrap(enlarged).screenshot, name: "font-size-rendered", to: self)
        let reset = H.openPaneAppearance(in: app)
        reset.typeKey("5", modifierFlags: .command)
        app.buttons["SettingsResetButton"].click()
        H.assertValue(reset, contains: "setting_reset_success: font-size")
        H.dismissDialog(reset, in: app)
        XCTAssertTrue(H.wait {
            guard let glyphs = try? H.glyphs(in: pane) else { return false }
            return abs(glyphs.bounds.width - initialGlyphs.bounds.width) < initialGlyphs.bounds.width * 0.08
        })
        XCTAssertNil(try env.paneStyle(id)["font-size"])
        let family = H.openPaneAppearance(in: app)
        family.typeKey("4", modifierFlags: .command)
        H.search("Monaco", in: family)
        family.typeKey(.return, modifierFlags: [])
        H.assertValue(family, contains: "setting_custom_success: font-family = Monaco")
        H.dismissDialog(family, in: app)
        XCTAssertTrue(H.wait { (try? env.paneStyle(id)["font-family"]) == "Monaco" })
        XCTAssertTrue(H.wait { guard let glyphs = try? H.glyphs(in: pane) else { return false }; return glyphs.pixels != initialGlyphs.pixels })
        H.attachScreenshot(pane.screenshot(), name: "font-family-rendered", to: self)
    }
}
