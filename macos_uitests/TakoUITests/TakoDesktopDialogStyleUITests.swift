/*
 * tako — Desktop dialog colors and text editing in a light shell
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

final class TakoDesktopDialogStyleUITests: TakoDesktopDesignCase {
    func testLightShellTextQuestionIsReadableAndEscapeReturnsToTheSameTerminal() throws {
        let app = try launchDesktop(appearance: "light")
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(id, phase: "LIGHT_QUESTION_BEFORE", in: app)
        header(id, in: app).rightClick()
        let rename = app.menuItems["FloatingPaneMenuRename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()

        // AppKit exposes the dialog's children directly in the window's AX tree.
        let dialog = app.staticTexts["terminal-dialog-body"].firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let field = app.textFields["tako_dialog_text_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: field.screenshot().pngRepresentation))
        let background = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 4,
                                                       y: bitmap.pixelsHigh - 4)?.usingColorSpace(.sRGB))
        let brightness = (background.redComponent + background.greenComponent + background.blueComponent) / 3
        XCTAssertGreaterThan(brightness, 0.65, "The input must use the light app palette, independently of the dark terminal")

        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("temporary review name")
        XCTAssertEqual(field.value as? String, "temporary review name")
        let shot = XCTAttachment(screenshot: activeWindow(in: app).screenshot())
        shot.name = "Light desktop question with editable text and a dark terminal behind it"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
        XCTAssertFalse(header(id, in: app).label.contains("temporary review name"))
        XCTAssertEqual(try shellPID(id, phase: "LIGHT_QUESTION_AFTER", in: app), process)
    }
}
