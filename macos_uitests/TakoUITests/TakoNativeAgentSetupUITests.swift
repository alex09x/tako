/*
 * tako — Native agent setup interaction tests
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

@MainActor
final class TakoNativeAgentSetupUITests: TakoCustomConfigCase {
    func testQwenAndMuseInstallFromTheirCardsAndRemainConnectedAfterReopening() async throws {
        let app = try takoApplication()
        let home = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["TAKO_CONFIG_PATH"]))
            .deletingLastPathComponent().appendingPathComponent("native-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        app.launchEnvironment["TAKO_AGENT_HOOKS_HOME"] = home.path
        for root in [".qwen", ".config/muse"] {
            let directory = home.appendingPathComponent(root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #"{"test-preserved":true}"#.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        }
        app.launch()
        try openAgents(app)
        let connect = app.buttons["SetupConnectAgents"]
        await fulfillment(of: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: connect)], timeout: 10)
        for id in ["qwen", "muse"] {
            let card = app.buttons["SetupAgent-\(id)"]
            XCTAssertTrue(card.isHittable, "The \(id) card must be physically reachable")
            XCTAssertEqual(card.value as? String, "Selected")
        }
        let wizard = app.descendants(matching: .any)["SetupWizard"].firstMatch
        let viewport = wizard.scrollViews.firstMatch
        for _ in 0..<4 {
            if viewport.frame.contains(CGPoint(x: connect.frame.midX, y: connect.frame.midY)) { break }
            viewport.scroll(byDeltaX: 0, deltaY: -250)
        }
        XCTAssertTrue(connect.isHittable)
        XCTAssertTrue(viewport.frame.contains(CGPoint(x: connect.frame.midX, y: connect.frame.midY)),
                      "Connect must be inside the visible scroll viewport before a physical click")
        let before = XCTAttachment(screenshot: wizard.screenshot())
        before.name = "Native agent connect visible target"
        before.lifetime = .keepAlways
        add(before)
        connect.click()
        await assertConnected(app)
        for root in [".qwen", ".config/muse"] {
            let directory = home.appendingPathComponent(root)
            let settings = try object(directory.appendingPathComponent("settings.json"))
            XCTAssertEqual(settings["test-preserved"] as? Bool, true)
            let skill = try String(contentsOf: directory.appendingPathComponent("skills/tako/SKILL.md"), encoding: .utf8)
            XCTAssertTrue(skill.contains("Tako Terminal Integration") || skill.contains("name: tako"))
        }
        let qwen = try object(home.appendingPathComponent(".qwen/settings.json"))
        XCTAssertNotNil((qwen["hooks"] as? [String: Any])?["UserPromptSubmit"])
        let museDirectory = home.appendingPathComponent(".config/muse")
        let muse = try object(museDirectory.appendingPathComponent("settings.json"))
        XCTAssertEqual(Set(try XCTUnwrap(muse["managed_hooks_env_vars"] as? [String])), Set(["TAKO_SURFACE_ID", "TAKO_SOCKET"]))
        let managed = try XCTUnwrap(muse["managed_hooks_path"] as? String)
        let hooks = try object(museDirectory.appendingPathComponent(managed))
        XCTAssertNotNil((hooks["hooks"] as? [String: Any])?["Stop"])
        for other in [".claude/settings.json", ".codex/hooks.json", ".gemini/settings.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(other).path))
        }
        let image = XCTAttachment(screenshot: app.descendants(matching: .any)["SetupWizard"].firstMatch.screenshot())
        image.name = "Qwen and Muse connected"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["SetupLater"].click()
        try openAgents(app)
        await fulfillment(of: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["SetupRefreshAgents"])], timeout: 10)
        await assertConnected(app)
        app.buttons["SetupLater"].click()
    }

    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func assertConnected(_ app: XCUIApplication) async {
        for id in ["qwen", "muse"] {
            let card = app.buttons["SetupAgent-\(id)"]
            let deadline = Date().addingTimeInterval(15)
            while card.value as? String != "Connected" && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            XCTAssertEqual(card.value as? String, "Connected", id)
        }
    }

    private func openAgents(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.activate()
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        let item = app.menuItems["Set Up Tako…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 5))
        app.buttons["SetupStep-agents"].click()
    }
}
