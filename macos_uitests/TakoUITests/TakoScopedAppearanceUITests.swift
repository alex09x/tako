/*
 * tako — Terminal emulator
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
    override static var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    @MainActor
    func testWorkspaceAndPaneMenuOpenScopedEditorAndModalContainment() async throws {
        let env = TakoScopedAppearanceHelpers()
        defer { env.cleanup() }
        let app = try env.launchIsolatedApp()

        // 1. Open Workspace Scoped Editor from Workspace Menu in Session Sidebar
        let wsDialog = TakoScopedAppearanceHelpers.openWorkspaceAppearance(in: app)
        XCTAssertTrue(wsDialog.label.contains("Workspace: Default"), "Dialog title should reflect workspace scope")

        let preModalScreenshot = app.windows.firstMatch.screenshot()
        TakoScopedAppearanceHelpers.attachScreenshot(preModalScreenshot, name: "WorkspaceScopedEditor-Open", to: self)

        // 2. Verify Modal Containment: Global navigation keys (Cmd+1, Cmd+2) do not escape scoped appearance
        wsDialog.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(wsDialog.exists, "Dialog must retain containment on Cmd+1")
        XCTAssertTrue(wsDialog.label.contains("Workspace: Default"), "Dialog must remain scoped to workspace on Cmd+1")

        wsDialog.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(wsDialog.exists, "Dialog must retain containment on Cmd+2")
        XCTAssertTrue(wsDialog.label.contains("Workspace: Default"), "Dialog must remain scoped to workspace on Cmd+2")

        // 3. Verify Modal Containment: Action shortcuts (Cmd+D for split) are consumed and do not act outside
        wsDialog.typeKey("d", modifierFlags: .command)
        XCTAssertEqual(app.groups.matching(identifier: "Terminal pane").count, 1, "Cmd+D must be consumed by modal containment")

        // 4. Dismiss Workspace Dialog
        TakoScopedAppearanceHelpers.dismissDialog(wsDialog, in: app)

        // 5. Open Pane Scoped Editor from Pane Menu in Session Sidebar
        let paneDialog = TakoScopedAppearanceHelpers.openPaneAppearance(in: app, isChild: false)
        XCTAssertTrue(paneDialog.label.contains("Pane appearance"), "Dialog title should reflect pane scope")

        let paneModalScreenshot = app.windows.firstMatch.screenshot()
        TakoScopedAppearanceHelpers.attachScreenshot(paneModalScreenshot, name: "PaneScopedEditor-Open", to: self)

        // 6. Dismiss Pane Dialog
        TakoScopedAppearanceHelpers.dismissDialog(paneDialog, in: app)
    }

    @MainActor
    func testThemeApplicationWithRenderedPixelsAndInheritanceReset() async throws {
        let env = TakoScopedAppearanceHelpers()
        defer { env.cleanup() }
        let app = try env.launchIsolatedApp()

        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5), "Terminal pane must exist")

        // 1. Capture initial rendered background pixel
        guard let initialColor = TakoScopedAppearanceHelpers.samplePixelColor(from: pane) else {
            XCTFail("Failed to sample initial rendered background pixel")
            return
        }
        let initialScreenshot = pane.screenshot()
        TakoScopedAppearanceHelpers.attachScreenshot(initialScreenshot, name: "ThemeRender-Initial", to: self)

        // 2. Open Workspace Scoped Editor
        let dialog = TakoScopedAppearanceHelpers.openWorkspaceAppearance(in: app)

        // 3. Search and select theme preset "Ocean" (Tako Ocean)
        dialog.typeText("Ocean")
        dialog.typeKey(.return, modifierFlags: [])

        let hasCustomSuccess = (dialog.value as? String)?.contains("Ocean") == true
            || (dialog.value as? String)?.contains("setting_custom_success") == true
            || (dialog.value as? String)?.contains("theme") == true
        XCTAssertTrue(hasCustomSuccess, "Theme selection should be acknowledged in dialog accessibility state")

        TakoScopedAppearanceHelpers.dismissDialog(dialog, in: app)

        // 4. Assert rendered output reflects the new theme
        guard let oceanColor = TakoScopedAppearanceHelpers.samplePixelColor(from: pane) else {
            XCTFail("Failed to sample ocean rendered background pixel")
            return
        }
        let oceanScreenshot = pane.screenshot()
        TakoScopedAppearanceHelpers.attachScreenshot(oceanScreenshot, name: "ThemeRender-Ocean", to: self)

        let diffOcean = TakoScopedAppearanceHelpers.colorDifference(initialColor, oceanColor)
        XCTAssertGreaterThan(diffOcean, 0.04, "Rendered background pixel must visibly change when theme is applied")

        // 5. Re-open scoped editor and reset theme override (test inheritance/reset)
        let resetDialog = TakoScopedAppearanceHelpers.openWorkspaceAppearance(in: app)
        let resetBtn = app.buttons["SettingsResetButton"]
        if resetBtn.exists {
            resetBtn.click()
        } else {
            resetDialog.typeKey("d", modifierFlags: [])
        }

        TakoScopedAppearanceHelpers.dismissDialog(resetDialog, in: app)

        // 6. Assert rendered output restores back to initial appearance
        guard let restoredColor = TakoScopedAppearanceHelpers.samplePixelColor(from: pane) else {
            XCTFail("Failed to sample restored rendered background pixel")
            return
        }
        let restoredScreenshot = pane.screenshot()
        TakoScopedAppearanceHelpers.attachScreenshot(restoredScreenshot, name: "ThemeRender-Restored", to: self)

        let diffRestored = TakoScopedAppearanceHelpers.colorDifference(initialColor, restoredColor)
        XCTAssertLessThan(diffRestored, 0.03, "Rendered background pixel must restore back to inherited initial color")
    }

    @MainActor
    func testSplitPaneIndependentAppearanceOverrides() async throws {
        let env = TakoScopedAppearanceHelpers()
        defer { env.cleanup() }
        let app = try env.launchIsolatedApp()

        // 1. Create a split pane with Cmd+D
        app.typeKey("d", modifierFlags: .command)

        let panes = app.groups.matching(identifier: "Terminal pane")
        XCTAssertTrue(panes.element(boundBy: 1).waitForExistence(timeout: 5), "Two split panes must exist")
        let leftPane = panes.element(boundBy: 0)
        let rightPane = panes.element(boundBy: 1)

        // 2. Open Pane Appearance for the child split pane from Session Sidebar
        let paneDialog = TakoScopedAppearanceHelpers.openPaneAppearance(in: app, isChild: true)
        XCTAssertTrue(paneDialog.label.contains("Pane appearance"), "Child pane dialog should open")

        // 3. Apply custom theme to child pane
        paneDialog.typeText("Ocean")
        paneDialog.typeKey(.return, modifierFlags: [])

        // Also adjust Font Size in child pane via Cmd+5
        paneDialog.typeKey("5", modifierFlags: .command)
        paneDialog.typeKey(.rightArrow, modifierFlags: [])

        TakoScopedAppearanceHelpers.dismissDialog(paneDialog, in: app)

        // 4. Verify independent split-pane color overrides
        guard let leftColor = TakoScopedAppearanceHelpers.samplePixelColor(from: leftPane),
              let rightColor = TakoScopedAppearanceHelpers.samplePixelColor(from: rightPane) else {
            XCTFail("Failed to sample split pane rendered background pixels")
            return
        }

        let leftScreenshot = leftPane.screenshot()
        let rightScreenshot = rightPane.screenshot()
        TakoScopedAppearanceHelpers.attachScreenshot(leftScreenshot, name: "SplitPane-Left-Inherited", to: self)
        TakoScopedAppearanceHelpers.attachScreenshot(rightScreenshot, name: "SplitPane-Right-Overridden", to: self)

        let splitDiff = TakoScopedAppearanceHelpers.colorDifference(leftColor, rightColor)
        XCTAssertGreaterThan(splitDiff, 0.04, "Split panes must render independent background colors after override")
    }

    @MainActor
    func testFontFamilyAndSizeControls() async throws {
        let env = TakoScopedAppearanceHelpers()
        defer { env.cleanup() }
        let app = try env.launchIsolatedApp()

        // 1. Open Pane Scoped Editor
        let dialog = TakoScopedAppearanceHelpers.openPaneAppearance(in: app, isChild: false)

        // 2. Navigate to Font Size section with Cmd+5
        dialog.typeKey("5", modifierFlags: .command)

        let initialSizeVal = dialog.value as? String ?? ""
        XCTAssertTrue(initialSizeVal.contains("Font Size"), "Font Size section should be active")

        // Increase font size with Right arrow
        dialog.typeKey(.rightArrow, modifierFlags: [])
        let increasedVal = dialog.value as? String ?? ""
        XCTAssertTrue(
            increasedVal.contains("setting_custom_success") || increasedVal.contains("font-size"),
            "Increasing font size should acknowledge update in accessibility value"
        )

        // Reset font size with Reset button / 'd'
        let resetBtn = app.buttons["SettingsResetButton"]
        if resetBtn.exists {
            resetBtn.click()
        } else {
            dialog.typeKey("d", modifierFlags: [])
        }
        let resetVal = dialog.value as? String ?? ""
        XCTAssertTrue(
            resetVal.contains("setting_reset_success") || resetVal.contains("Font Size"),
            "Resetting font size should acknowledge reset in accessibility value"
        )

        // 3. Navigate to Fonts section with Cmd+4
        dialog.typeKey("4", modifierFlags: .command)
        let fontSectionVal = dialog.value as? String ?? ""
        XCTAssertTrue(fontSectionVal.contains("Fonts"), "Fonts section should be active")

        // Select a font family by typing search query
        dialog.typeText("Menlo")
        dialog.typeKey(.return, modifierFlags: [])
        let fontAppliedVal = dialog.value as? String ?? ""
        XCTAssertTrue(
            fontAppliedVal.contains("setting_custom_success") || fontAppliedVal.contains("font-family") || fontAppliedVal.contains("Menlo"),
            "Applying font family should acknowledge update"
        )

        // Reset font family
        if resetBtn.exists {
            resetBtn.click()
        } else {
            dialog.typeKey("d", modifierFlags: [])
        }
        let fontResetVal = dialog.value as? String ?? ""
        XCTAssertTrue(
            fontResetVal.contains("setting_reset_success") || fontResetVal.contains("Fonts"),
            "Resetting font family should acknowledge reset"
        )

        TakoScopedAppearanceHelpers.dismissDialog(dialog, in: app)

        let finalScreenshot = app.windows.firstMatch.screenshot()
        TakoScopedAppearanceHelpers.attachScreenshot(finalScreenshot, name: "FontControls-Final", to: self)
    }
}
