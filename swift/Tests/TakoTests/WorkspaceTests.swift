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
}
