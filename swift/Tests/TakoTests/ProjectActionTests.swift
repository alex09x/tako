/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import Foundation
import AppKit
@testable import Tako
import TakoKit

@Suite @MainActor struct ProjectActionTests {

    @Test func testProjectActionCodableRoundTrip() throws {
        let json = """
        {
          "version": 1,
          "name": "MyProject",
          "actions": [
            {
              "id": "build",
              "title": "Build Project",
              "description": "Compile sources",
              "command": ["cargo", "build"],
              "cwd": "crates/core",
              "env": {"RUST_LOG": "debug"},
              "target": "split",
              "direction": "vertical"
            },
            {
              "id": "test",
              "title": "Run Unit Tests",
              "argv": ["cargo", "test"],
              "target": "new-tab"
            },
            {
              "id": "clean",
              "title": "Clean",
              "command": ["cargo", "clean"],
              "shell": true,
              "target": "pane"
            }
          ]
        }
        """

        let file = try JSONDecoder().decode(ProjectActionFile.self, from: Data(json.utf8))
        #expect(file.version == 1)
        #expect(file.name == "MyProject")
        #expect(file.actions.count == 3)

        let build = file.actions[0]
        #expect(build.id == "build")
        #expect(build.title == "Build Project")
        #expect(build.description == "Compile sources")
        #expect(build.effectiveCommand == ["cargo", "build"])
        #expect(build.cwd == "crates/core")
        #expect(build.env?["RUST_LOG"] == "debug")
        #expect(build.effectiveTarget == .split)
        #expect(build.effectiveDirection == .vertical)

        let test = file.actions[1]
        #expect(test.id == "test")
        #expect(test.effectiveCommand == ["cargo", "test"])
        #expect(test.effectiveTarget == .newTab)

        let clean = file.actions[2]
        #expect(clean.id == "clean")
        #expect(clean.effectiveTarget == .pane)
        #expect(clean.shell == true)

        let reencoded = try JSONEncoder().encode(file)
        let redecoded = try JSONDecoder().decode(ProjectActionFile.self, from: reencoded)
        #expect(redecoded.actions == file.actions)
    }

    @Test func testProjectActionTrustStoreLifecycleAndChangeDetection() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_trusted_actions_\(UUID().uuidString).json")
        let store = ProjectActionTrustStore(fileURL: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let path = "/tmp/test_project/.tako/actions.json"
        let initialContent = """
        {"version":1,"actions":[{"id":"b","title":"Build","command":["make"]}]}
        """
        let modifiedContent = """
        {"version":1,"actions":[{"id":"b","title":"Build","command":["make","all"]}]}
        """

        // 1. Initially untrusted
        #expect(store.status(path: path, content: initialContent) == .untrusted)
        #expect(!store.isTrusted(path: path, content: initialContent))

        // 2. Trust initial content
        store.trust(path: path, content: initialContent)
        #expect(store.status(path: path, content: initialContent) == .trusted)
        #expect(store.isTrusted(path: path, content: initialContent))

        // 3. Changed content detected via SHA-256 hash mismatch
        let initialHash = ProjectActionTrustStore.sha256(for: initialContent)
        let modifiedHash = ProjectActionTrustStore.sha256(for: modifiedContent)
        let statusAfterChange = store.status(path: path, content: modifiedContent)
        #expect(statusAfterChange == .changed(recordedSHA256: initialHash, currentSHA256: modifiedHash))
        #expect(!store.isTrusted(path: path, content: modifiedContent))

        // 4. Re-approve modified content
        store.trust(path: path, content: modifiedContent)
        #expect(store.status(path: path, content: modifiedContent) == .trusted)
        #expect(store.isTrusted(path: path, content: modifiedContent))

        // 5. Revocation
        store.revoke(path: path)
        #expect(store.status(path: path, content: modifiedContent) == .untrusted)
    }

    @Test func testProjectActionDiscovery() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako_discovery_\(UUID().uuidString)")
        let takoDir = tempDir.appendingPathComponent(".tako")
        let subDir = tempDir.appendingPathComponent("src/sub/deep")
        let outsideDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako_outside_\(UUID().uuidString)")

        let fm = FileManager.default
        try fm.createDirectory(at: takoDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDir)
            try? fm.removeItem(at: outsideDir)
        }

        let actionsJson = """
        {
          "version": 1,
          "name": "DiscoveredApp",
          "actions": [
            { "id": "run-app", "title": "Run App", "command": ["./bin/run"] }
          ]
        }
        """
        let actionsFileURL = takoDir.appendingPathComponent("actions.json")
        try actionsJson.write(to: actionsFileURL, atomically: true, encoding: .utf8)

        // Discovery from nested subdirectory walks up to project root
        let discovered = ProjectActionDiscovery.find(at: subDir.path)
        #expect(discovered != nil)
        #expect(discovered?.projectRoot == tempDir.path)
        #expect(discovered?.file.name == "DiscoveredApp")
        #expect(discovered?.file.actions.count == 1)
        #expect(discovered?.file.actions[0].id == "run-app")

        // Discovery outside project returns nil
        let outside = ProjectActionDiscovery.find(at: outsideDir.path)
        #expect(outside == nil)
    }

    @Test func testUnapprovedProjectActionNeverRunsWithoutApproval() throws {
        let app = Tako.App()
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tree = SplitTree<Tako.SurfaceView>(view: surface)
        let controller = BaseTerminalController(app, surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win
        win.contentView = surface

        let action = ProjectAction(
            id: "server",
            title: "Start Server",
            command: ["python3", "-m", "http.server", "8000"],
            target: .split
        )

        // When isTrusted = false (unapproved), action NEVER executes
        let unapprovedResult = try ProjectActionManager.shared.execute(
            action: action,
            projectRoot: "/tmp",
            from: surface,
            isTrusted: false,
            app: app
        )
        #expect(!unapprovedResult.executed)
        #expect(!unapprovedResult.isTrusted)

        // When isTrusted = true (approved), action executes
        let approvedResult = try ProjectActionManager.shared.execute(
            action: action,
            projectRoot: "/tmp",
            from: surface,
            isTrusted: true,
            app: app
        )
        #expect(approvedResult.executed)
        #expect(approvedResult.isTrusted)
    }

    @Test func testControlActionCommands() throws {
        ProjectActionTrustStore.shared.resetForTesting()

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako_ctrl_act_\(UUID().uuidString)")
        let takoDir = tempDir.appendingPathComponent(".tako")
        let fm = FileManager.default
        try fm.createDirectory(at: takoDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let actionsJson = """
        {
          "version": 1,
          "name": "CtrlApp",
          "actions": [
            { "id": "test-act", "title": "Run Test Action", "command": ["echo", "test"] }
          ]
        }
        """
        let actionsFileURL = takoDir.appendingPathComponent("actions.json")
        try actionsJson.write(to: actionsFileURL, atomically: true, encoding: .utf8)

        let app = Tako.App()
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        surface.pwd = tempDir.path
        let tree = SplitTree<Tako.SurfaceView>(view: surface)
        let controller = BaseTerminalController(app, surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win
        win.contentView = surface

        let pane = ControlCommands.Pane(
            surface: surface,
            windowID: "win-1",
            tabID: "tab-1",
            stableTabID: win.stableTabIdentifier,
            controller: controller
        )

        // 1. Action List
        let listReq = ControlRequest(
            cmd: "action",
            args: ["action": .string("list"), "path": .string(tempDir.path)],
            from: nil
        )
        let listResp = try ControlCommands.actionCommand(listReq, all: [pane])
        #expect(listResp["trusted"]?.bool == false)
        #expect(listResp["name"]?.string == "CtrlApp")
        guard let actions = listResp["actions"]?.array else {
            Issue.record("Expected actions array")
            return
        }
        #expect(actions.count == 1)

        // 2. Action Run without approval fails (unapproved)
        let runReq = ControlRequest(
            cmd: "action",
            args: [
                "action": .string("run"),
                "id": .string("test-act"),
                "path": .string(tempDir.path)
            ],
            from: nil
        )
        #expect(throws: ControlError.self) {
            _ = try ControlCommands.actionCommand(runReq, all: [pane])
        }

        // 3. Action Status
        let statusReq = ControlRequest(
            cmd: "action",
            args: ["action": .string("status"), "path": .string(tempDir.path)],
            from: nil
        )
        let statusResp = try ControlCommands.actionCommand(statusReq, all: [pane])
        #expect(statusResp["status"]?.string == "untrusted")
        #expect(statusResp["trusted"]?.bool == false)

        // 4. Action Approve
        let approveReq = ControlRequest(
            cmd: "action",
            args: ["action": .string("approve"), "path": .string(tempDir.path)],
            from: nil
        )
        let approveResp = try ControlCommands.actionCommand(approveReq, all: [pane])
        #expect(approveResp["approved"]?.bool == true)

        // 5. Action Run now succeeds after approval
        let runApprovedResp = try ControlCommands.actionCommand(runReq, all: [pane])
        #expect(runApprovedResp["ran"]?.bool == true)
        #expect(runApprovedResp["trusted"]?.bool == true)
        #expect(runApprovedResp["id"]?.string == "test-act")
    }
}
