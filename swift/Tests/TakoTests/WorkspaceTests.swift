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
import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct WorkspaceTests {
    private func makeTemporaryStore() -> (WorkspaceStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(storeURL: storeURL, isTesting: false)
        return (store, storeURL)
    }

    @Test func testDefaultWorkspaceCreatedOnFirstLaunch() {
        let (store, _) = makeTemporaryStore()
        #expect(store.workspaces.count == 1)
        #expect(store.activeWorkspaceId == WorkspaceStore.defaultWorkspaceId)
        #expect(store.activeWorkspace.name == "Default")
    }

    @Test func testCreateAndSwitchWorkspace() {
        let (store, _) = makeTemporaryStore()
        let ws = store.createWorkspace(
            name: "Ghostty",
            rootDirectory: "/Users/alex/ghostty",
            color: "orange",
            icon: "terminal"
        )

        #expect(store.workspaces.count == 2)
        #expect(ws.name == "Ghostty")
        #expect(ws.rootDirectory == "/Users/alex/ghostty")
        #expect(ws.color == "orange")
        #expect(ws.icon == "terminal")

        // Switch by ID
        #expect(store.switchWorkspace(to: ws.id))
        #expect(store.activeWorkspaceId == ws.id)
        #expect(store.activeWorkspace.name == "Ghostty")

        // Switch back by name
        #expect(store.switchWorkspace(named: "Default"))
        #expect(store.activeWorkspaceId == WorkspaceStore.defaultWorkspaceId)

        // Switch to unknown name fails
        #expect(!store.switchWorkspace(named: "NonExistent"))
    }

    @Test func testNextAndPreviousWorkspaceCycle() {
        let (store, _) = makeTemporaryStore()
        let w1 = store.createWorkspace(name: "W1")
        let w2 = store.createWorkspace(name: "W2")

        #expect(store.activeWorkspaceId == WorkspaceStore.defaultWorkspaceId)

        store.nextWorkspace()
        #expect(store.activeWorkspaceId == w1.id)

        store.nextWorkspace()
        #expect(store.activeWorkspaceId == w2.id)

        store.nextWorkspace()
        #expect(store.activeWorkspaceId == WorkspaceStore.defaultWorkspaceId)

        store.previousWorkspace()
        #expect(store.activeWorkspaceId == w2.id)

        store.previousWorkspace()
        #expect(store.activeWorkspaceId == w1.id)
    }

    @Test func testTabAssignmentAndRemoval() {
        let (store, _) = makeTemporaryStore()
        let w1 = store.createWorkspace(name: "Project A")
        let w2 = store.createWorkspace(name: "Project B")

        store.assignTab(tabIdentifier: "tab-1", to: w1.id)
        store.assignTab(tabIdentifier: "tab-2", to: w1.id)

        #expect(store.workspace(forTab: "tab-1")?.id == w1.id)
        #expect(store.workspace(forTab: "tab-2")?.id == w1.id)
        #expect(store.workspace(for: w1.id)?.tabIdentifiers == ["tab-1", "tab-2"])
        #expect(store.workspace(for: w1.id)?.activeTabIdentifier == "tab-1")

        // Moving tab-1 to w2 removes it from w1
        store.assignTab(tabIdentifier: "tab-1", to: w2.id)
        #expect(store.workspace(forTab: "tab-1")?.id == w2.id)
        #expect(store.workspace(for: w1.id)?.tabIdentifiers == ["tab-2"])
        #expect(store.workspace(for: w1.id)?.activeTabIdentifier == "tab-2")

        // Removing tab-2 clears it
        store.removeTab(tabIdentifier: "tab-2")
        #expect(store.workspace(forTab: "tab-2") == nil)
        #expect(store.workspace(for: w1.id)?.tabIdentifiers.isEmpty == true)
        #expect(store.workspace(for: w1.id)?.activeTabIdentifier == nil)
    }

    @Test func testTabReordering() {
        let (store, _) = makeTemporaryStore()
        let w1 = store.createWorkspace(name: "Reorder Test")
        store.assignTab(tabIdentifier: "a", to: w1.id)
        store.assignTab(tabIdentifier: "b", to: w1.id)
        store.assignTab(tabIdentifier: "c", to: w1.id)

        store.reorderTabs(in: w1.id, newOrder: ["c", "a", "b"])
        #expect(store.workspace(for: w1.id)?.tabIdentifiers == ["c", "a", "b"])
    }

    @Test func testDeleteWorkspaceReassignsTabsToDefault() {
        let (store, _) = makeTemporaryStore()
        let w1 = store.createWorkspace(name: "To Delete")
        store.assignTab(tabIdentifier: "tab-orphan-1", to: w1.id)
        store.assignTab(tabIdentifier: "tab-orphan-2", to: w1.id)
        store.switchWorkspace(to: w1.id)

        // Deleting default is disallowed
        #expect(!store.deleteWorkspace(id: WorkspaceStore.defaultWorkspaceId))

        // Deleting w1 moves tabs to Default and switches active back to Default
        #expect(store.deleteWorkspace(id: w1.id))
        #expect(store.workspaces.count == 1)
        #expect(store.activeWorkspaceId == WorkspaceStore.defaultWorkspaceId)
        let defWs = store.workspace(for: WorkspaceStore.defaultWorkspaceId)
        #expect(defWs?.tabIdentifiers.contains("tab-orphan-1") == true)
        #expect(defWs?.tabIdentifiers.contains("tab-orphan-2") == true)
    }

    @Test func testPersistenceLoadAndSave() {
        let (store1, url) = makeTemporaryStore()
        let w1 = store1.createWorkspace(
            name: "Persistent Project",
            rootDirectory: "/tmp/project",
            color: "red",
            icon: "folder"
        )
        store1.assignTab(tabIdentifier: "tab-persisted", to: w1.id)
        store1.switchWorkspace(to: w1.id)

        // Load into a new store from the same URL
        let store2 = WorkspaceStore(storeURL: url, isTesting: false)
        #expect(store2.workspaces.count == 2)
        #expect(store2.activeWorkspaceId == w1.id)
        let loaded = store2.workspace(for: w1.id)
        #expect(loaded?.name == "Persistent Project")
        #expect(loaded?.rootDirectory == "/tmp/project")
        #expect(loaded?.color == "red")
        #expect(loaded?.icon == "folder")
        #expect(loaded?.tabIdentifiers == ["tab-persisted"])
        #expect(loaded?.activeTabIdentifier == "tab-persisted")
    }

    @Test func testControlCommandsWorkspaceEndpoints() throws {
        // Reset shared store for testing
        WorkspaceStore.shared.resetForTesting()

        // 1. List
        let listReq = ControlRequest(cmd: "workspace", args: ["action": .string("list")], from: nil)
        let listResp = try ControlCommands.workspaceCommand(listReq, all: [])
        let listArr = try #require(listResp["workspaces"]?.array)
        #expect(listArr.count >= 1)

        // 2. Create
        let createReq = ControlRequest(
            cmd: "workspace",
            args: [
                "action": .string("create"),
                "name": .string("CLI Workspace"),
                "root": .string("/tmp/cli"),
                "color": .string("green"),
                "icon": .string("gear")
            ],
            from: nil
        )
        let createResp = try ControlCommands.workspaceCommand(createReq, all: [])
        #expect(createResp["name"]?.string == "CLI Workspace")
        #expect(createResp["root_directory"]?.string == "/tmp/cli")
        #expect(createResp["color"]?.string == "green")
        #expect(createResp["icon"]?.string == "gear")
        let newId = try #require(createResp["id"]?.string)

        // 3. Switch
        let switchReq = ControlRequest(
            cmd: "workspace",
            args: [
                "action": .string("switch"),
                "name": .string("CLI Workspace")
            ],
            from: nil
        )
        let switchResp = try ControlCommands.workspaceCommand(switchReq, all: [])
        #expect(switchResp["name"]?.string == "CLI Workspace")
        #expect(switchResp["is_active"]?.bool == true)

        // 4. Current
        let currentReq = ControlRequest(cmd: "workspace", args: ["action": .string("current")], from: nil)
        let currentResp = try ControlCommands.workspaceCommand(currentReq, all: [])
        #expect(currentResp["name"]?.string == "CLI Workspace")
        #expect(currentResp["id"]?.string == newId)

        // 5. Assign
        let assignReq = ControlRequest(
            cmd: "workspace",
            args: [
                "action": .string("assign"),
                "workspace": .string("CLI Workspace"),
                "tab": .string("test-tab-id")
            ],
            from: nil
        )
        let assignResp = try ControlCommands.workspaceCommand(assignReq, all: [])
        #expect(assignResp["tab"]?.string == "test-tab-id")
        #expect(assignResp["workspace"]?.string == "CLI Workspace")

        // 6. Delete
        let deleteReq = ControlRequest(
            cmd: "workspace",
            args: [
                "action": .string("delete"),
                "name": .string("CLI Workspace")
            ],
            from: nil
        )
        let deleteResp = try ControlCommands.workspaceCommand(deleteReq, all: [])
        #expect(deleteResp["deleted"]?.string == "CLI Workspace")
        #expect(WorkspaceStore.shared.activeWorkspaceId == WorkspaceStore.defaultWorkspaceId)
    }

    @Test func testSurfaceContextAndAssignResolvesToStableTabId() throws {
        WorkspaceStore.shared.resetForTesting()
        _ = WorkspaceStore.shared.createWorkspace(name: "Alpha")
        _ = WorkspaceStore.shared.createWorkspace(name: "Beta")
        _ = WorkspaceStore.shared.switchWorkspace(named: "Alpha")

        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let tree = SplitTree<Tako.SurfaceView>(view: surface)
        let controller = BaseTerminalController(Tako.App(), surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win

        let stableTabId = win.stableTabIdentifier
        let controlTabId = "tab-mock-control"
        let pane = ControlCommands.Pane(
            surface: surface,
            windowID: "win-1",
            tabID: controlTabId,
            stableTabID: stableTabId,
            controller: controller
        )

        // 1. Assign to Beta using target pane resolution
        let assignReq = ControlRequest(
            cmd: "workspace",
            args: [
                "action": .string("assign"),
                "workspace": .string("Beta")
            ],
            from: nil
        )
        let assignResp = try ControlCommands.workspaceCommand(assignReq, all: [pane])
        #expect(assignResp["tab"]?.string == stableTabId)
        #expect(assignResp["workspace"]?.string == "Beta")
        #expect(WorkspaceStore.shared.workspace(forTab: stableTabId)?.name == "Beta")

        // 2. Assign using controlTabId directly resolves to stableTabId
        let assignByControlTabReq = ControlRequest(
            cmd: "workspace",
            args: [
                "action": .string("assign"),
                "workspace": .string("Alpha"),
                "tab": .string(controlTabId)
            ],
            from: nil
        )
        let assignByControlResp = try ControlCommands.workspaceCommand(assignByControlTabReq, all: [pane])
        #expect(assignByControlResp["tab"]?.string == stableTabId)
        #expect(assignByControlResp["workspace"]?.string == "Alpha")
        #expect(WorkspaceStore.shared.workspace(forTab: stableTabId)?.name == "Alpha")
    }

    @Test func testWorkspaceAndTabTransitions() throws {
        WorkspaceStore.shared.resetForTesting()
        #expect(WorkspaceStore.shared.recentTransitions.isEmpty)
        #expect(WorkspaceStore.shared.recentTabTransitions.isEmpty)

        let ws = WorkspaceStore.shared.createWorkspace(name: "TestWs")
        #expect(WorkspaceStore.shared.switchWorkspace(to: ws.id))

        #expect(WorkspaceStore.shared.recentTransitions.count == 1)
        let wsTrans = WorkspaceStore.shared.recentTransitions[0]
        #expect(wsTrans.sequence == 1)
        #expect(wsTrans.fromId == WorkspaceStore.defaultWorkspaceId)
        #expect(wsTrans.toId == ws.id)
        #expect(wsTrans.timestamp > 0)

        WorkspaceStore.shared.assignTab(tabIdentifier: "tab-0", to: ws.id)
        WorkspaceStore.shared.assignTab(tabIdentifier: "tab-1", to: ws.id)
        WorkspaceStore.shared.setActiveTab(tabIdentifier: "tab-1", in: ws.id)

        #expect(WorkspaceStore.shared.recentTabTransitions.count == 1)
        let tabTrans = WorkspaceStore.shared.recentTabTransitions[0]
        #expect(tabTrans.sequence == 2)
        #expect(tabTrans.workspaceId == ws.id)
        #expect(tabTrans.fromId == "tab-0")
        #expect(tabTrans.toId == "tab-1")
        #expect(tabTrans.timestamp > 0)

        // Switching to another tab appends another transition with incremented sequence
        WorkspaceStore.shared.setActiveTab(tabIdentifier: "tab-0", in: ws.id)
        #expect(WorkspaceStore.shared.recentTabTransitions.count == 2)
        let tabTrans2 = WorkspaceStore.shared.recentTabTransitions[1]
        #expect(tabTrans2.sequence == 3)
        #expect(tabTrans2.fromId == "tab-1")
        #expect(tabTrans2.toId == "tab-0")

        // Setting the same active tab is a no-op
        WorkspaceStore.shared.setActiveTab(tabIdentifier: "tab-0", in: ws.id)
        #expect(WorkspaceStore.shared.recentTabTransitions.count == 2)

        // Control command "history" returns both transitions with sequences
        let histReq = ControlRequest(cmd: "workspace", args: ["action": .string("history")], from: nil)
        let histResp = try ControlCommands.workspaceCommand(histReq, all: [])
        guard case let .array(transitions)? = histResp["transitions"],
              case let .array(tabTransitions)? = histResp["tab_transitions"] else {
            Issue.record("history command missing transitions or tab_transitions")
            return
        }
        #expect(transitions.count == 1)
        #expect(tabTransitions.count == 2)
        #expect(transitions[0].object?["sequence"]?.number == 1.0)
        #expect(tabTransitions[0].object?["sequence"]?.number == 2.0)
        #expect(tabTransitions[1].object?["sequence"]?.number == 3.0)

        // Bounded history test
        for i in 4...65 {
            WorkspaceStore.shared.setActiveTab(tabIdentifier: "tab-\(i % 2)", in: ws.id)
        }
        #expect(WorkspaceStore.shared.recentTabTransitions.count == 50)
        #expect(WorkspaceStore.shared.recentTabTransitions.last?.sequence == 64)
    }
}
