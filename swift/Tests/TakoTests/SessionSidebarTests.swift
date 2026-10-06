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
import AppKit
import Foundation
@testable import Tako

@MainActor
struct SessionSidebarTests {

    func createTestDefaults() -> UserDefaults {
        let suiteName = "test.tako.sidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func sidebarStoreInitialStateAndOptInsOffByDefault() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        // B5 requirement: "Off by default for people who prefer the tab bar"
        #expect(!store.isShowing)
        // B5 requirement: "each opt-in field is off until enabled"
        #expect(!store.optInGit)
        #expect(!store.optInPorts)
        #expect(!store.filterNeedsAttention)
        #expect(store.filterText.isEmpty)
        #expect(store.descriptions.isEmpty)
    }

    @Test func userEditableDescriptionsSetUpdateAndClear() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        let tabId = UUID().uuidString

        #expect(store.description(for: tabId) == nil)

        store.setDescription("Backend API Service", for: tabId)
        #expect(store.description(for: tabId) == "Backend API Service")

        // Persists to UserDefaults
        let reloadedStore = SessionSidebarStore(defaults: defaults)
        #expect(reloadedStore.description(for: tabId) == "Backend API Service")

        // Update description
        store.setDescription("Backend API Service (v2)", for: tabId)
        #expect(store.description(for: tabId) == "Backend API Service (v2)")

        // Clear description
        store.clearDescription(for: tabId)
        #expect(store.description(for: tabId) == nil)
    }

    @Test func tabDescriptionPersistsWhenFirstSplitPaneIsClosed() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let surf1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        surf1.title = "Split Pane 1"
        let surf2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 400))
        surf2.title = "Split Pane 2"
        container.addSubview(surf1)
        container.addSubview(surf2)
        win.contentView = container

        let initialItems = store.items(for: win)
        #expect(initialItems.count == 1)
        let tabId = initialItems[0].id
        #expect(!tabId.isEmpty)

        // Set description for the tab
        store.setDescription("Build and Logs Tab", for: tabId)
        let updatedItems = store.items(for: win)
        #expect(updatedItems[0].userDescription == "Build and Logs Tab")

        // Close the first split pane
        surf1.removeFromSuperview()

        // Tab still exists with surf2; row ID and description must remain intact
        let itemsAfterClosingFirstSplit = store.items(for: win)
        #expect(itemsAfterClosingFirstSplit.count == 1)
        #expect(itemsAfterClosingFirstSplit[0].id == tabId)
        #expect(itemsAfterClosingFirstSplit[0].userDescription == "Build and Logs Tab")
    }

    func createTestGitRepository(branch: String = "feature/sidebar-test") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-\(UUID().uuidString)")
        let gitDir = tempDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
        let headFile = gitDir.appendingPathComponent("HEAD")
        try "ref: refs/heads/\(branch)\n".write(to: headFile, atomically: true, encoding: .utf8)
        return tempDir
    }

    func waitForGitInspection(store: SessionSidebarStore, directory: String) async throws {
        for _ in 0..<150 {
            if store.hasGitCache(for: directory) && !store.isGitInspectionPending(for: directory) {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func waitForPortsInspection(store: SessionSidebarStore, pids: [Int]) async throws {
        for _ in 0..<50 {
            if pids.allSatisfy({ store.hasPortsCache(for: $0) && !store.isPortsInspectionPending(for: $0) }) {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    @Test func localGitInspectionReadsBranchAndDirtyStateLocallyWithoutNetwork() throws {
        let repoURL = try createTestGitRepository(branch: "feature/sidebar-test")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let gitInfo = LocalGitInspection.inspect(directory: repoURL.path)
        #expect(gitInfo != nil)
        #expect(gitInfo?.branch == "feature/sidebar-test")
        #expect(gitInfo?.isDirty == false)

        // Untracked file makes repository dirty
        let untrackedFile = repoURL.appendingPathComponent("untracked.txt")
        try "untracked content".write(to: untrackedFile, atomically: true, encoding: .utf8)
        let dirtyInfo = LocalGitInspection.inspect(directory: repoURL.path)
        #expect(dirtyInfo?.isDirty == true)
        try? FileManager.default.removeItem(at: untrackedFile)
        let cleanInfo = LocalGitInspection.inspect(directory: repoURL.path)
        #expect(cleanInfo?.isDirty == false)

        // Detached HEAD inspection
        let detachedDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-\(UUID().uuidString)")
        let detachedGit = detachedDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: detachedGit.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: detachedGit.appendingPathComponent("objects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: detachedDir) }
        try "e8a3b5c4d2e1f0\n".write(to: detachedGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let detachedInfo = LocalGitInspection.inspect(directory: detachedDir.path)
        #expect(detachedInfo?.branch == "e8a3b5c")
        // Non-existent commit object causes git status to fail; failure propagates nil rather than reporting false (clean)
        #expect(detachedInfo?.isDirty == nil)
    }

    @Test func failedGitInspectionDoesNotReportClean() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-corrupt-\(UUID().uuidString)")
        let gitDir = tempDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Corrupt HEAD with invalid SHA that fails git status
        try "invalidsha123\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let info = LocalGitInspection.inspect(directory: tempDir.path)
        #expect(info != nil)
        #expect(info?.branch == "invalid")
        // When git status exits with non-zero status, isDirty must be nil (unavailable), NOT false (clean)
        #expect(info?.isDirty == nil)
    }

    @Test func optInFieldsAreOnlyPopulatedWhenEnabled() async throws {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let repoURL = try createTestGitRepository(branch: "main")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workspace 1"

        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        surface.pty?.terminate()
        surface.title = "Build Server"
        surface.pwd = repoURL.path
        window.contentView = surface

        // When opt-ins are false, git and ports must be nil
        store.optInGit = false
        store.optInPorts = false

        let itemsDisabled = store.items(for: window)
        #expect(itemsDisabled.count == 1)
        let itemDisabled = itemsDisabled[0]
        #expect(itemDisabled.gitBranch == nil)
        #expect(itemDisabled.gitDirty == nil)
        #expect(itemDisabled.listeningPorts == nil)

        // When opt-ins are true, git is populated from local repo
        store.optInGit = true
        _ = store.items(for: window)
        try await waitForGitInspection(store: store, directory: repoURL.path)

        let itemsEnabled = store.items(for: window)
        #expect(itemsEnabled.count == 1)
        let itemEnabled = itemsEnabled[0]
        #expect(itemEnabled.gitBranch == "main")
    }

    @Test func filterNeedsAttentionIsolatesAttentionRequiredPanes() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win3 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)

        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Idle Tab"
        surf1.crab.setStatus(.idle, text: nil)
        win1.contentView = surf1

        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.title = "Failed Tab"
        surf2.crab.setStatus(.error, text: nil)
        win2.contentView = surf2

        let surf3 = Tako.SurfaceView(frame: .zero)
        surf3.title = "Approval Tab"
        surf3.crab.setStatus(.needsApproval, text: nil)
        win3.contentView = surf3

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        Tako.CustomTabGroup.join(win3, to: win1, select: false)
        let group = Tako.CustomTabGroup.group(for: win1)
        group.select(win1) // win1 is selected/active, win2 and win3 are in background

        // Without filter: all 3 tabs are present
        store.filterNeedsAttention = false
        let allItems = store.items(for: win1)
        #expect(allItems.count == 3)

        // With filter: only win2 (error) and win3 (needsApproval) are present
        store.filterNeedsAttention = true
        let filtered = store.items(for: win1)
        #expect(filtered.count == 2)
        #expect(filtered.contains(where: { $0.title == "Failed Tab" }))
        #expect(filtered.contains(where: { $0.title == "Approval Tab" }))
        #expect(!filtered.contains(where: { $0.title == "Idle Tab" }))
    }

    @Test func textSearchFiltersAcrossTitleDirectoryAndDescription() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)

        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Frontend Client"
        surf1.pwd = "/Users/dev/frontend"
        win1.contentView = surf1

        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.title = "Worker Daemon"
        surf2.pwd = "/Users/dev/worker"
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        store.setDescription("React Vite UI", for: win1.stableTabIdentifier)

        store.filterNeedsAttention = false

        // Search by title
        store.filterText = "Frontend"
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1).first?.title == "Frontend Client")

        // Search by directory
        store.filterText = "worker"
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1).first?.title == "Worker Daemon")

        // Search by user description
        store.filterText = "Vite"
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1).first?.title == "Frontend Client")

        // Search no match
        store.filterText = "nonexistent_query"
        #expect(store.items(for: win1).isEmpty)
    }


}
