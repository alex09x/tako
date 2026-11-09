/*
 * tako — Optional native setup and return-to-terminal acceptance
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopSetupUITests: TakoDesktopDesignCase {
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
