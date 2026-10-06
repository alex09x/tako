/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
import AppKit
@testable import Tako

@Suite
@MainActor
struct LayoutTests {

    @Test func testLayoutDocumentCodableRoundTrip() throws {
        let leftPane = LayoutPane(
            title: "Editor",
            cwd: "/Users/test/project",
            env: ["EDITOR": "nvim"],
            command: ["nvim", "main.rs"],
            argv: nil,
            shell: false
        )
        let rightTopPane = LayoutPane(
            title: "Server",
            cwd: "/Users/test/project",
            env: ["PORT": "8080"],
            command: ["cargo", "run"],
            argv: nil,
            shell: false
        )
        let rightBottomPane = LayoutPane(
            title: "Tests",
            cwd: "/Users/test/project",
            command: ["cargo", "test"]
        )

        let verticalSplit = LayoutSplit(
            direction: .vertical,
            ratio: 0.4,
            left: .leaf(rightTopPane),
            right: .leaf(rightBottomPane)
        )

        let rootSplit = LayoutSplit(
            direction: .horizontal,
            ratio: 0.65,
            left: .leaf(leftPane),
            right: .split(verticalSplit)
        )

        let tab1 = LayoutTab(title: "Dev", color: "blue", root: .split(rootSplit))
        let tab2 = LayoutTab(title: "Logs", color: nil, root: .leaf(LayoutPane(cwd: "/var/log", command: ["tail", "-f", "syslog"])))

        let window = LayoutWindow(
            title: "Workspace Window",
            frame: LayoutFrame(x: 100, y: 150, width: 1400, height: 900),
            selectedTab: 0,
            tabs: [tab1, tab2]
        )

        let doc = LayoutDocument(version: 1, name: "Project", windows: [window])

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)

        // Decode back
        let decoded = try JSONDecoder().decode(LayoutDocument.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.name == "Project")
        #expect(decoded.effectiveWindows.count == 1)

        let decWin = decoded.effectiveWindows[0]
        #expect(decWin.title == "Workspace Window")
        #expect(decWin.frame?.x == 100)
        #expect(decWin.frame?.width == 1400)
        #expect(decWin.tabs.count == 2)

        let decTab1 = decWin.tabs[0]
        #expect(decTab1.title == "Dev")
        #expect(decTab1.color == "blue")
        guard case .split(let decSplit) = decTab1.root else {
            Issue.record("Expected split root in tab 1")
            return
        }
        #expect(decSplit.direction == .horizontal)
        #expect(abs(decSplit.ratio - 0.65) < 0.001)

        guard case .leaf(let decLeft) = decSplit.left else {
            Issue.record("Expected leaf left child")
            return
        }
        #expect(decLeft.title == "Editor")
        #expect(decLeft.cwd == "/Users/test/project")
        #expect(decLeft.effectiveCommand == ["nvim", "main.rs"])
        #expect(decLeft.env?["EDITOR"] == "nvim")

        guard case .split(let decRight) = decSplit.right else {
            Issue.record("Expected split right child")
            return
        }
        #expect(decRight.direction == .vertical)
        #expect(abs(decRight.ratio - 0.4) < 0.001)

        #expect(decoded.hasPrograms)
        #expect(decoded.programsSummary.count == 4)
    }

    @Test func testLayoutTrustStoreLifecycleAndChangeDetection() {
        let store = LayoutTrustStore.shared
        store.resetForTesting()

        let path = "/tmp/tako_test_project/layout.json"
        let initialContent = """
        {
          "version": 1,
          "windows": [{"tabs": [{"root": {"cwd": "/tmp", "command": ["make"]}}]}]
        }
        """

        // 1. Initially untrusted
        #expect(store.status(path: path, content: initialContent) == .untrusted)
        #expect(!store.isTrusted(path: path, content: initialContent))

        // 2. Approve trust
        store.trust(path: path, content: initialContent)
        #expect(store.status(path: path, content: initialContent) == .trusted)
        #expect(store.isTrusted(path: path, content: initialContent))

        // 3. File content changes -> asks again (changed status)
        let modifiedContent = """
        {
          "version": 1,
          "windows": [{"tabs": [{"root": {"cwd": "/tmp", "command": ["curl", "evil.com"]}}]}]
        }
        """
        let status = store.status(path: path, content: modifiedContent)
        guard case .changed = status else {
            Issue.record("Expected changed status for modified content, got \(status)")
            return
        }
        #expect(!store.isTrusted(path: path, content: modifiedContent))

        // 4. Re-approving new content restores trust
        store.trust(path: path, content: modifiedContent)
        #expect(store.status(path: path, content: modifiedContent) == .trusted)
        #expect(store.isTrusted(path: path, content: modifiedContent))

        // 5. Revoking removes trust
        store.revoke(path: path)
        #expect(store.status(path: path, content: modifiedContent) == .untrusted)
        #expect(!store.isTrusted(path: path, content: modifiedContent))
    }

    @Test func testUnapprovedLayoutNeverStartsProgram() throws {
        let app = Tako.App()
        let paneWithCommand = LayoutPane(
            title: "Build",
            cwd: "/tmp",
            command: ["echo", "running-untrusted-program"]
        )
        let doc = LayoutDocument(tabs: [LayoutTab(title: "Tab", root: .leaf(paneWithCommand))])

        // When isTrusted = false (unapproved)
        let unapprovedResult = try LayoutManager.apply(document: doc, isTrusted: false, app: app)
        #expect(unapprovedResult.programsStarted == 0)
        #expect(unapprovedResult.programsSuppressed == 1)
        #expect(!unapprovedResult.isTrusted)

        // When isTrusted = true (approved)
        let approvedResult = try LayoutManager.apply(document: doc, isTrusted: true, app: app)
        #expect(approvedResult.programsStarted == 1)
        #expect(approvedResult.programsSuppressed == 0)
        #expect(approvedResult.isTrusted)
    }

    @Test func testUntrustedLayoutEnvironmentVariablesAreSuppressed() throws {
        let app = Tako.App()
        let paneWithEnvOnly = LayoutPane(
            title: "EnvOnly",
            cwd: "/tmp",
            env: ["ZDOTDIR": "/tmp/malicious", "BASH_ENV": "/tmp/pwn.sh"]
        )
        let doc = LayoutDocument(tabs: [LayoutTab(title: "Tab", root: .leaf(paneWithEnvOnly))])
        #expect(doc.hasPrograms)

        // Untrusted: env must be suppressed and counted as programsSuppressed
        let unapprovedResult = try LayoutManager.apply(document: doc, isTrusted: false, app: app)
        #expect(unapprovedResult.programsStarted == 0)
        #expect(unapprovedResult.programsSuppressed == 1)
        #expect(!unapprovedResult.isTrusted)

        // Approved: env is accepted
        let approvedResult = try LayoutManager.apply(document: doc, isTrusted: true, app: app)
        #expect(approvedResult.programsStarted == 1)
        #expect(approvedResult.programsSuppressed == 0)
        #expect(approvedResult.isTrusted)
    }

    @Test func testControlLayoutSaveAndApplyCommands() throws {
        LayoutTrustStore.shared.resetForTesting()

        // Create mock pane in controller
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tree = SplitTree<Tako.SurfaceView>(view: surface)
        let controller = BaseTerminalController(Tako.App(), surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win
        win.contentView = surface
        _ = Tako.CustomTabGroup.group(for: win)

        let pane = ControlCommands.Pane(
            surface: surface,
            windowID: "win-1",
            tabID: "tab-1",
            stableTabID: win.stableTabIdentifier,
            controller: controller
        )

        // 1. Layout Save
        let saveReq = ControlRequest(
            cmd: "layout",
            args: [
                "action": .string("save"),
                "target": .string(surface.id.uuidString.lowercased())
            ],
            from: nil
        )
        let saveResp = try ControlCommands.layoutCommand(saveReq, all: [pane])
        #expect(saveResp["saved"]?.bool == true)
        #expect((saveResp["tabs"]?.number ?? 0) >= 1)
        guard let contentStr = saveResp["content"]?.string else {
            Issue.record("Expected content string in layout save response")
            return
        }

        // Verify saved content decodes cleanly as LayoutDocument
        let decodedDoc = try JSONDecoder().decode(LayoutDocument.self, from: Data(contentStr.utf8))
        #expect(!decodedDoc.effectiveWindows.isEmpty)

        // 2. Layout Status of layout without programs
        let testPath = "/tmp/tako_test_declarative_layout.json"
        let statusReq = ControlRequest(
            cmd: "layout",
            args: [
                "action": .string("status"),
                "path": .string(testPath),
                "content": .string(contentStr)
            ],
            from: nil
        )
        let statusResp = try ControlCommands.layoutCommand(statusReq, all: [pane])
        #expect(statusResp["status"]?.string == "untrusted")
        #expect(statusResp["has_programs"]?.bool == false)

        // 3. Layout Apply of safe layout (no programs) is trusted by default
        let applySafeReq = ControlRequest(
            cmd: "layout",
            args: [
                "action": .string("apply"),
                "path": .string(testPath),
                "content": .string(contentStr)
            ],
            from: nil
        )
        let applySafeResp = try ControlCommands.layoutCommand(applySafeReq, all: [pane])
        #expect(applySafeResp["applied"]?.bool == true)
        #expect(applySafeResp["trusted"]?.bool == true)
        #expect(applySafeResp["programs_started"]?.number == 0)

        // 4. Layout Apply with programs: refuses without approval
        let untrustedProgramJson = """
        {
          "version": 1,
          "windows": [{
            "tabs": [{
              "root": {
                "cwd": "/tmp",
                "command": ["cargo", "test"]
              }
            }]
          }]
        }
        """
        let applyUntrustedReq = ControlRequest(
            cmd: "layout",
            args: [
                "action": .string("apply"),
                "path": .string(testPath),
                "content": .string(untrustedProgramJson)
            ],
            from: nil
        )
        #expect(throws: ControlError.self) {
            _ = try ControlCommands.layoutCommand(applyUntrustedReq, all: [pane])
        }

        // 5. Layout Approve records trust
        let approveReq = ControlRequest(
            cmd: "layout",
            args: [
                "action": .string("approve"),
                "path": .string(testPath),
                "content": .string(untrustedProgramJson)
            ],
            from: nil
        )
        let approveResp = try ControlCommands.layoutCommand(approveReq, all: [pane])
        #expect(approveResp["approved"]?.bool == true)
        #expect(approveResp["sha256"]?.string != nil)

        // 6. Layout Apply after approval now succeeds and starts programs
        let applyApprovedResp = try ControlCommands.layoutCommand(applyUntrustedReq, all: [pane])
        #expect(applyApprovedResp["applied"]?.bool == true)
        #expect(applyApprovedResp["trusted"]?.bool == true)
        #expect(applyApprovedResp["programs_started"]?.number == 1)
        #expect(applyApprovedResp["programs_suppressed"]?.number == 0)
    }

    @Test func testProjectLayoutDiscovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tako_test_project_\(UUID().uuidString)")
        let takoDir = tempDir.appendingPathComponent(".tako")
        try FileManager.default.createDirectory(at: takoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layoutFile = takoDir.appendingPathComponent("layout.json")
        try "{}".write(to: layoutFile, atomically: true, encoding: .utf8)

        let found = LayoutManager.findProjectLayout(in: tempDir.path)
        #expect(found?.path == layoutFile.path)
    }
}
