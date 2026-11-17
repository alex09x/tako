/*
 * tako — Optional native setup and return-to-terminal acceptance
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

final class TakoDesktopSetupUITests: TakoDesktopDesignCase {
    /// Setup chooses terminal colours, independently of the application's
    /// palette. Observe the covered terminal through its own renderer.
    func testAppearanceAppliesAndEscapeResumesAtTheSameStep() throws {
        let app = try launchDesktop(appearance: "light", configuration: """
        theme = TakoCore
        font-family = Monaco
        font-size = 17
        font-weight = 550
        remote-control = on
        working-directory = \(designDirectory.path)
        """)
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(id, phase: "SETUP_COLOR_BEFORE", in: app)
        let receipt = designDirectory.appendingPathComponent("setup-source")
        app.typeText("printf '%s\\n%s' \"$TAKO_SURFACE_ID\" \"$TAKO_SOCKET\" > setup-source\n")
        try requireSetup { FileManager.default.fileExists(atPath: receipt.path) }
        let fields = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first?.lowercased(), id.lowercased())
        let socket = try XCTUnwrap(fields.last)
        func terminalBackground() throws -> [Double] {
            let image = try TakoScopedAppearanceHelpers.rendererImage(of: id, socket: socket)
            let bitmap = NSBitmapImageRep(cgImage: image)
            return try rgb(bitmap, x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh - 10)
        }
        try openSetupForAppearance(app)
        let wizard = app.descendants(matching: .any)["SetupWizard"].firstMatch
        let shellColor = try setupBackground(wizard)
        XCTAssertGreaterThan(shellColor.reduce(0, +), 2.4, "The application was explicitly launched with a light interface")
        let before = try terminalBackground()
        func choose(_ name: String, light: Bool) throws {
            let card = app.buttons["SetupTheme-\(name)"]
            try revealInWizard(card, wizard)
            XCTAssertTrue(card.isHittable)
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
            try requireSetup { card.value as? String == "Selected" }
            try requireSetup { guard let c = try? terminalBackground() else { return false }
                return light ? c.reduce(0, +) > 2.4 : c.reduce(0, +) < 1.0 }
            XCTAssertEqual(try configText().components(separatedBy: "\n").filter { $0.hasPrefix("theme = ") }, ["theme = \(name)"])
            for line in ["font-family = Monaco", "font-size = 17", "font-weight = 550", "app-appearance = light"] {
                XCTAssertTrue(try configText().contains(line), line)
            }
            for (actual, expected) in zip(try setupBackground(wizard), shellColor) {
                XCTAssertEqual(actual, expected, accuracy: 0.03, "A terminal theme must not recolor app chrome")
            }
        }
        try choose("Tako Forest", light: false)
        let forest = try terminalBackground()
        XCTAssertGreaterThan(zip(before, forest).reduce(0) { $0 + abs($1.0 - $1.1) }, 0.03)
        XCTAssertFalse(app.popUpButtons["SetupFont"].exists)
        XCTAssertFalse(app.steppers["SetupFontSize"].exists)
        try choose("Tako Dawn", light: true)
        try choose("Tako Forest", light: false)
        attachCanvas(app, named: "Setup changes terminal colours and preserves app appearance")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 5))
        let terminal = pane(id, in: app).textViews.firstMatch
        XCTAssertTrue(terminal.exists)
        XCTAssertEqual(terminal.frame.maxY, pane(id, in: app).frame.maxY - Self.paneBodyBottomInset, accuracy: 2)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: terminal.screenshot().pngRepresentation))
        for (actual, expected) in zip(try rgb(bitmap, x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh - 10), forest) {
            XCTAssertEqual(actual, expected, accuracy: 0.035, "The uncovered terminal shows the chosen background")
        }
        try openSetupForAppearance(app)
        let title = app.staticTexts["SetupStepTitle"].firstMatch
        XCTAssertEqual((title.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title.label, "Theme")
        XCTAssertEqual(app.buttons["SetupTheme-Tako Forest"].value as? String, "Selected")
        app.buttons["SetupLater"].click()
        XCTAssertEqual(try shellPID(id, phase: "SETUP_COLOR_AFTER", in: app, focus: false), process)
    }

    private func requireSetup(_ predicate: @escaping () -> Bool) throws {
        guard TakoScopedAppearanceHelpers.wait(predicate) else {
            throw TakoScopedAppearanceHelpers.ObservationError.unavailable("Setup did not reach the expected UI or rendered state")
        }
    }

    /// Scrolls the wizard's own ScrollView (bounded) until `element` lies
    /// inside its visible frame, so a card below the fold (or under the Dock
    /// on a short hosted screen) is clicked where the person would see it.
    private func revealInWizard(_ element: XCUIElement, _ wizard: XCUIElement) throws {
        let scroll = wizard.scrollViews.firstMatch
        guard element.waitForExistence(timeout: 5), scroll.exists else {
            throw TakoScopedAppearanceHelpers.ObservationError.unavailable("no \(element) in the wizard's ScrollView")
        }
        for _ in 0..<12 {
            let visible = scroll.frame, frame = element.frame
            if visible.contains(frame), element.isHittable { return }
            scroll.scroll(byDeltaX: 0, deltaY: frame.maxY > visible.maxY ? -60 : 60)
        }
        throw TakoScopedAppearanceHelpers.ObservationError.unavailable(
            "\(element) stayed outside the wizard's visible frame \(scroll.frame): \(element.frame)")
    }

    private func openSetupForAppearance(_ app: XCUIApplication) throws {
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        let item = app.menuItems["Set Up Tako…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 5))
        if !app.buttons["SetupStep-appearance"].exists { app.buttons["SetupNext"].click() }
        app.buttons["SetupStep-appearance"].click()
    }

    private func setupBackground(_ wizard: XCUIElement) throws -> [Double] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: wizard.screenshot().pngRepresentation))
        // The footer's empty bottom padding, six logical points above its edge.
        let scale = Double(bitmap.pixelsHigh) / wizard.frame.height
        return try rgb(bitmap, x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - Int((6 * scale).rounded()))
    }

    private func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Double] {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    func testFiveStageSetupCanFinishWithoutInstallingSkillsOrGrantingPermissions() throws {
        let app = try launchDesktop(setup: true)
        let wizard = app.descendants(matching: .any)["SetupWizard"].firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 10))
        let initialPanes = paneIDs(in: app)
        XCTAssertEqual(initialPanes.count, 1)
        attachCanvas(app, named: "Native first-run welcome over existing terminal")
        for stage in ["appearance", "agents", "notifications", "ready"] {
            let next = wizard.buttons["SetupNext"].firstMatch
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            XCTAssertTrue(next.isHittable)
            next.click()
            let current = wizard.buttons["SetupStep-\(stage)"].firstMatch
            XCTAssertTrue(current.waitForExistence(timeout: 5))
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: current)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
            XCTAssertFalse(wizard.buttons["SetupStep-commandLine"].exists)
            XCTAssertFalse(wizard.buttons["SetupStep-permissions"].exists)
            for label in wizard.staticTexts.allElementsBoundByIndex.map(\.label) + wizard.buttons.allElementsBoundByIndex.map(\.label) {
                XCTAssertFalse(label.unicodeScalars.contains { (0x0400...0x052f).contains($0.value) },
                               "Unexpected Cyrillic setup label: \(label)")
            }
            XCTAssertEqual(paneIDs(in: app), initialPanes)
            if stage == "notifications" {
                attachCanvas(app, named: "Native permission observations before any explicit request")
            }
        }
        attachCanvas(app, named: "Simple native setup completion")
        wizard.buttons["SetupFinish"].firstMatch.click()
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 5))
        XCTAssertEqual(paneIDs(in: app), initialPanes)
        _ = try shellPID(try XCTUnwrap(initialPanes.first), phase: "DESIGN_SETUP_DONE", in: app, focus: false)
    }
}
