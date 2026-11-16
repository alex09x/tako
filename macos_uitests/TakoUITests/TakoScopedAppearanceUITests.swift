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

/// Each level's appearance is edited where a person reaches it now: a workspace row's or
/// a terminal's own «Appearance ▸» menu, which opens native Settings › Terminal
/// Appearance at that level (theme cards, Font & Size, ↺ Inherit) or drops the level's
/// own appearance («Inherit · …»). A level's font and size are its own scoped values
/// (Appearance.json); its theme is a preset it selects.
final class TakoScopedAppearanceUITests: TakoCustomConfigCase {
    private typealias H = TakoScopedAppearanceHelpers

    @MainActor func testMovingAnInheritedCustomThemeKeepsPixelsPaneAndShell() throws {
        let env = try H(); defer { env.cleanup() }
        let initial = "00000000-0000-0000-0000-000000000001"
        let destination = UUID().uuidString
        try FileManager.default.createDirectory(at: env.support, withIntermediateDirectories: true)
        let workspaces: [String: Any] = ["activeWorkspaceId": initial, "workspaces": [
            ["id": initial, "name": "Default", "tabIdentifiers": [], "createdAt": 0] as [String: Any],
            ["id": destination, "name": "Destination", "tabIdentifiers": [], "createdAt": 0] as [String: Any]
        ]]
        let workspaceDirectory = env.support.appendingPathComponent("Workspaces")
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: workspaces).write(to: workspaceDirectory.appendingPathComponent("workspaces.json"))
        let themes = env.testRoot.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "# tako-preset-version: 1\nbackground = #123456\nfont-family = Monaco\nfont-size = 19\n".write(to: themes.appendingPathComponent("Move Witness"), atomically: true, encoding: .utf8)
        let styles: [String: Any] = ["version": 1, "panes": [:], "workspaces": [initial: ["theme": "Move Witness"]]]
        try JSONSerialization.data(withJSONObject: styles).write(to: env.support.appendingPathComponent("Appearance.json"))
        let app = try env.launchIsolatedApp()
        let id = try XCTUnwrap(env.primaryPaneID)
        try env.recordControlSocket()
        let pane = H.terminalPane(in: app)
        let ocean = NSColor(srgbRed: 18.0 / 255, green: 52.0 / 255, blue: 86.0 / 255, alpha: 1)
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(color, ocean) < 0.03 })
        func shell(_ slot: String) throws -> String {
            let name = "shell-" + slot
            pane.typeText("sh -c 'printf %s \"$PPID\"' > '\(name)'\n")
            let file = env.testRoot.appendingPathComponent(name)
            XCTAssertTrue(H.wait { ((try? String(contentsOf: file, encoding: .utf8)) ?? "").isEmpty == false })
            return try String(contentsOf: file, encoding: .utf8)
        }
        let process = try shell("before")
        H.openSidebar(in: app)
        let rows = app.descendants(matching: .any).matching(identifier: "session-tab-" + id.lowercased())
        let row = try XCTUnwrap(rows.allElementsBoundByIndex.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItems["Move to Workspace"].click()
        // AppKit exposes titles through the identifiers query; its main-menu
        // workspace switch also has this title, but is a different action.
        app.menuItems.matching(identifier: "Destination")
            .matching(NSPredicate(format: "identifier != %@", "selectWorkspaceFromMenu:")).firstMatch.click()
        // The source workspace's style is carried into the moved session's own record
        // (its stable tab identity, from the live tree), not copied onto each pane.
        let session = H.sessionKey(try env.stableTabID(ofPane: id))
        XCTAssertTrue(H.wait { (try? env.sessionStyles()[session]?["theme"]) == "Move Witness" })
        XCTAssertEqual(try env.sessionStyles().count, 1, "one session record: the moved session's")
        XCTAssertNil(try env.paneStyle(id)["theme"], "the pane keeps no copy of its own")
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(color, ocean) < 0.03 })
        XCTAssertEqual(try env.identifyPane(pane, title: "Moved", slot: "moved"), id)
        XCTAssertEqual(try shell("after"), process)
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "moved-session-keeps-inherited-theme", to: self)
        // The session row's «Appearance ▸ Inherit»: the theme it carried over is dropped.
        H.inheritAppearance(from: H.sessionRow(id, in: app), in: app)
        XCTAssertTrue(H.wait { (try? env.sessionStyles()[session]?["theme"]) == nil })
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(color, ocean) > 0.04 })
    }

    @MainActor func testWorkspaceAndPaneMenusAndModalContainment() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let original = try Data(contentsOf: env.configFile)
        let root = H.openAppearance(.allThemes, from: H.workspaceRow(in: app), in: app)
        let level = H.currentLevel(in: root)
        XCTAssertTrue(level.contains("workspace") && level.contains("Default"), "editing level: \(level)")
        // Nothing of its own yet: the workspace inherits, so there is nothing to inherit back.
        XCTAssertFalse(root.buttons["DesktopInherit-theme"].exists)
        // Keys stay in Settings: typing goes to its theme filter, not to the terminal.
        let filter = root.textFields["DesktopThemeFilter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("dr")
        XCTAssertEqual(filter.value as? String, "dr")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.support.appendingPathComponent("Appearance.json").path))
        H.replaceText(of: filter, with: "")
        for key in ["1", "2", "4", "5"] {
            root.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(root.exists, "⌘\(key) left Settings")
            XCTAssertTrue(H.currentLevel(in: root).contains("Default"), "⌘\(key) changed the edited level")
        }
        root.typeKey("d", modifierFlags: .command)
        XCTAssertEqual(H.leafPanes(in: app).count, 1)
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "workspace-editor", to: self)
        H.closeSettings(root)
        let pane = H.openAppearance(.allThemes, from: H.terminalPane(in: app), in: app)
        XCTAssertTrue(H.currentLevel(in: pane).contains("terminal"), "editing level: \(H.currentLevel(in: pane))")
        H.closeSettings(pane)
        XCTAssertEqual(try Data(contentsOf: env.configFile), original)
    }

    @MainActor func testWorkspaceThemeAndResetChangeRenderedPixels() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let id = try XCTUnwrap(env.primaryPaneID)
        try env.recordControlSocket()
        let pane = H.terminalPane(in: app)
        let before = try XCTUnwrap(H.samplePixelColor(from: pane))
        let root = H.openAppearance(.allThemes, from: H.workspaceRow(in: app), in: app)
        // Settings covers the window: the pane is read from its own renderer while it is open.
        let behindCatalog = try XCTUnwrap(env.rendererColor(of: id))
        let forest = H.themeCard("Tako Forest", in: root)
        forest.click()
        XCTAssertTrue(H.wait { (try? env.workspaceStyles().values.first?["theme"]) == "Tako Forest" })
        XCTAssertTrue(H.wait {
            guard let color = env.rendererColor(of: id) else { return false }
            return H.colorDifference(behindCatalog, color) > 0.04
        }, "One click must visibly apply the theme while its catalog remains open")
        XCTAssertTrue(root.exists)
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "theme-click-live-catalog", to: self)
        // Choosing a theme is not editing one: no draft, nothing to save.
        XCTAssertFalse(root.buttons["DesktopThemeSave"].exists)
        H.themeCard("Tako Ocean", in: root).click()
        XCTAssertTrue(H.wait { (try? env.workspaceStyles().values.first?["theme"]) == "Tako Ocean" })
        H.closeSettings(root)
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(before, color) > 0.04 })
        H.attachScreenshot(pane.screenshot(), name: "workspace-theme-rendered", to: self)
        let reset = H.openAppearance(.allThemes, from: H.workspaceRow(in: app), in: app)
        let inherit = reset.buttons["DesktopInherit-theme"].firstMatch
        XCTAssertTrue(inherit.waitForExistence(timeout: 5))
        inherit.click()
        XCTAssertTrue(H.wait { (try? env.workspaceStyles().values.first?["theme"]) == nil })
        H.closeSettings(reset)
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
        // The right terminal's own «Appearance ▸ All Themes…» edits that terminal only.
        let root = H.openAppearance(.allThemes, from: right, in: app, expectedPane: second)
        XCTAssertTrue(H.currentLevel(in: root).contains("terminal"))
        H.themeCard("Tako Ocean", in: root).click()
        XCTAssertTrue(H.wait { (try? env.paneStyle(second)["theme"]) == "Tako Ocean" })
        H.setFontSize("17", in: root)
        XCTAssertTrue(H.wait { (try? env.paneStyle(second)["font-size"]) == "17" })
        H.closeSettings(root)
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
        let pane = H.terminalPane(in: app)
        pane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        var initial: H.GlyphObservation?
        XCTAssertTrue(H.wait { initial = try? H.glyphs(in: pane); return initial != nil })
        let initialGlyphs = try XCTUnwrap(initial)
        H.attachScreenshot(initialGlyphs.screenshot, name: "font-size-before", to: self)
        let size = H.openAppearance(.allThemes, from: pane, in: app)
        XCTAssertNil(try env.paneStyle(id)["font-size"])
        H.setFontSize("17", in: size)
        XCTAssertTrue(H.wait { (try? env.paneStyle(id)["font-size"]) == "17" })
        H.closeSettings(size)
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
        // ↺ Inherit drops the terminal's own size.
        let reset = H.openAppearance(.allThemes, from: pane, in: app)
        let inheritSize = reset.buttons["DesktopInherit-font-size"].firstMatch
        XCTAssertTrue(inheritSize.waitForExistence(timeout: 5))
        inheritSize.click()
        XCTAssertTrue(H.wait { (try? env.paneStyle(id)["font-size"]) == nil })
        H.closeSettings(reset)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).click()
        var resetGlyphs: H.GlyphObservation?
        XCTAssertTrue(H.wait {
            resetGlyphs = try? H.glyphs(in: pane)
            return resetGlyphs?.bounds.size == initialGlyphs.bounds.size && resetGlyphs?.pixels == initialGlyphs.pixels
        }, "Reset must restore the same glyph size and ink mask before testing family changes")
        let familyBaseline = try XCTUnwrap(resetGlyphs)
        XCTAssertNil(try env.paneStyle(id)["font-size"])
        let family = H.openAppearance(.allThemes, from: pane, in: app)
        H.chooseFont("Monaco", in: family)
        XCTAssertTrue(H.wait { (try? env.paneStyle(id)["font-family"]) == "Monaco" })
        H.closeSettings(family)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).click()
        XCTAssertTrue(H.wait { guard let glyphs = try? H.glyphs(in: pane) else { return false }; return glyphs.pixels != familyBaseline.pixels })
        H.attachScreenshot(pane.screenshot(), name: "font-family-rendered", to: self)
    }
}
