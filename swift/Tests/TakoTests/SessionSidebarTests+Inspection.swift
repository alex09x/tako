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
extension SessionSidebarTests {
    @Test func descendantProcessesAreInspectedForListeningPorts() {
        LocalPortInspection.descendantPidsOverride = { rootPid in
            if rootPid == 500 {
                return [500, 501, 502]
            }
            return [rootPid]
        }
        LocalPortInspection.lsofOutputOverride = { pids in
            #expect(pids.contains(500))
            #expect(pids.contains(501))
            #expect(pids.contains(502))
            return "p501\nf4\nn*:8080\np502\nf5\nn127.0.0.1:3000\n"
        }
        defer {
            LocalPortInspection.descendantPidsOverride = nil
            LocalPortInspection.lsofOutputOverride = nil
        }

        let ports = LocalPortInspection.inspectListeningPorts(pid: 500)
        #expect(ports == [3000, 8080])
    }

    @Test func listeningPortsAggregateAcrossSplitPanesInTab() async throws {
        let pty1 = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory(), program: ["/bin/sleep", "30"]))
        defer { pty1.terminate() }
        let pty2 = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory(), program: ["/bin/sleep", "30"]))
        defer { pty2.terminate() }

        let pid1 = pty1.foregroundPID ?? Int(pty1.child)
        let pid2 = pty2.foregroundPID ?? Int(pty2.child)

        LocalPortInspection.descendantPidsOverride = { [$0] }
        LocalPortInspection.lsofOutputOverride = { pids in
            if pids.contains(pid1) {
                return "p\(pid1)\nf3\nn*:8000\n"
            } else if pids.contains(pid2) {
                return "p\(pid2)\nf3\nn*:9000\n"
            }
            return ""
        }
        defer {
            LocalPortInspection.descendantPidsOverride = nil
            LocalPortInspection.lsofOutputOverride = nil
        }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInPorts = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let surf1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let surf2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 400))
        surf1.title = "Pane 1"
        surf2.title = "Pane 2"
        surf1.pty = pty1
        surf2.pty = pty2
        container.addSubview(surf1)
        container.addSubview(surf2)
        win.contentView = container

        // First read kicks off async inspection for both PIDs
        _ = store.items(for: win)
        try await waitForPortsInspection(store: store, pids: [pid1, pid2])

        let finalItems = store.items(for: win)
        #expect(finalItems.first?.listeningPorts == [8000, 9000])
    }

    @Test func tabDescriptionsDoNotLeakToPanesWhenSplitPaneIsDraggedToNewWindow() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let surf1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let surf2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 400))
        container.addSubview(surf1)
        container.addSubview(surf2)
        win.contentView = container

        let tabId = win.stableTabIdentifier
        store.setDescription("Multi-pane tab note", for: tabId)

        let items = store.items(for: win)
        #expect(items.count == 1)
        #expect(items[0].userDescription == "Multi-pane tab note")

        // Descriptions must NOT be keyed under individual pane surface IDs
        #expect(store.description(for: surf1.id.uuidString) == nil)
        #expect(store.description(for: surf2.id.uuidString) == nil)

        // Dragging surf2 into a new window creates a tab that does NOT inherit the old tab's description
        let newWin = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        newWin.contentView = surf2
        let newItems = store.items(for: newWin)
        #expect(newItems.count == 1)
        #expect(newItems[0].userDescription == nil)
    }

    @Test func focusedSplitResolvesSidebarMetadata() throws {
        let app = Tako.App()
        let surf1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let surf2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 400))
        surf1.title = "Pane 1"
        surf1.pwd = "/Users/dev/pane1"
        surf2.title = "Pane 2"
        surf2.pwd = "/Users/dev/pane2"

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        var tree = SplitTree<Tako.SurfaceView>(view: surf1)
        tree = try tree.inserting(view: surf2, at: surf1, direction: .right)
        let controller = BaseTerminalController(app, surfaceTree: tree)
        win.windowController = controller
        controller.window = win
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        container.addSubview(surf1)
        container.addSubview(surf2)
        win.contentView = container

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        // When focused surface is surf1
        controller.focusedSurfaceDidChange(to: surf1)
        let items1 = store.items(for: win)
        #expect(items1.count == 1)
        #expect(items1[0].surfaceId == surf1.id)
        #expect(items1[0].title == "Pane 1")
        #expect(items1[0].workingDirectory == "/Users/dev/pane1")

        // When focus moves to surf2
        controller.focusedSurfaceDidChange(to: surf2)
        let items2 = store.items(for: win)
        #expect(items2.count == 1)
        #expect(items2[0].surfaceId == surf2.id)
        #expect(items2[0].title == "Pane 2")
        #expect(items2[0].workingDirectory == "/Users/dev/pane2")
    }

    @Test func gitMetadataInvalidatesAcrossAllSubdirectoriesInRepository() async throws {
        let repoURL = try createTestGitRepository(branch: "main")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let pkgA = repoURL.appendingPathComponent("pkgA")
        let pkgB = repoURL.appendingPathComponent("pkgB")
        try FileManager.default.createDirectory(at: pkgA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pkgB, withIntermediateDirectories: true)

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.pty?.terminate()
        surf1.pwd = pkgA.path
        win1.contentView = surf1

        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.pty?.terminate()
        surf2.pwd = pkgB.path
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)

        _ = store.items(for: win1)
        try await waitForGitInspection(store: store, directory: pkgA.path)
        try await waitForGitInspection(store: store, directory: pkgB.path)

        let initialItems = store.items(for: win1)
        #expect(initialItems.count == 2)
        #expect(initialItems[0].gitBranch == "main")
        #expect(initialItems[1].gitBranch == "main")

        // Switch branch on disk
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/feature-branch\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Command finishes in pkgA
        surf1.crab.setStatus(.running, text: nil)
        surf1.crab.setStatus(.done, text: nil)

        // Invalidating pkgA must invalidate the whole repo, including pkgB
        _ = store.items(for: win1)
        try await waitForGitInspection(store: store, directory: pkgA.path)
        try await waitForGitInspection(store: store, directory: pkgB.path)

        let updatedItems = store.items(for: win1)
        #expect(updatedItems.count == 2)
        #expect(updatedItems[0].gitBranch == "feature-branch")
        #expect(updatedItems[1].gitBranch == "feature-branch")
    }

    @Test func concurrentSubdirectoryInspectionDiscardedIfInvalidatedBeforeDiscovery() async throws {
        let repoURL = try createTestGitRepository(branch: "main")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let pkgA = repoURL.appendingPathComponent("pkgA")
        let pkgB = repoURL.appendingPathComponent("pkgB")
        try FileManager.default.createDirectory(at: pkgA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pkgB, withIntermediateDirectories: true)

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.pty?.terminate()
        surf1.pwd = pkgA.path
        win1.contentView = surf1

        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.pty?.terminate()
        surf2.pwd = pkgB.path
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)

        // Kick off concurrent inspection for win1 and win2 before repository root is known
        _ = store.items(for: win1)

        // Invalidate repository cache while inspections are in flight
        store.invalidateGitCache(for: pkgA.path)

        // Switch branch on disk to new-branch
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/new-branch\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Query items again to launch post-invalidation inspections
        _ = store.items(for: win1)
        try await waitForGitInspection(store: store, directory: pkgA.path)
        try await waitForGitInspection(store: store, directory: pkgB.path)

        let items = store.items(for: win1)
        #expect(items.count == 2)
        #expect(items[0].gitBranch == "new-branch")
        #expect(items[1].gitBranch == "new-branch")
    }

    @Test func commandInOneRepositoryDoesNotDiscardConcurrentInspectionInUnrelatedRepository() async throws {
        let repo1URL = try createTestGitRepository(branch: "repo1-main")
        defer { try? FileManager.default.removeItem(at: repo1URL) }
        let repo2URL = try createTestGitRepository(branch: "repo2-feature")
        defer { try? FileManager.default.removeItem(at: repo2URL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.pty?.terminate()
        surf1.pwd = repo1URL.path
        win1.contentView = surf1

        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.pty?.terminate()
        surf2.pwd = repo2URL.path
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)

        // Launch concurrent inspections for both repositories
        _ = store.items(for: win1)

        // Invalidate repository 1 while inspections are running
        store.invalidateGitCache(for: repo1URL.path)

        // Wait for repository 2 inspection to complete
        try await waitForGitInspection(store: store, directory: repo2URL.path)

        let items = store.items(for: win1)
        #expect(items.count == 2)
        // Repo 2 must NOT have been discarded by Repo 1's command completion
        #expect(items[1].gitBranch == "repo2-feature")
    }
}
