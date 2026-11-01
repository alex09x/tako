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

@MainActor
@Suite(.serialized)
struct WorkspaceCloseAndDeleteTests {
    @Test func transientlyHiddenLiveWindowDoesNotQuitTheApplication() {
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let delegate = AppDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { Tako.CustomTabGroup.close(window); window.close(); store.resetForTesting() }
        _ = Tako.CustomTabGroup.group(for: window)
        store.assignTab(tabIdentifier: window.stableTabIdentifier, to: store.activeWorkspaceId)
        window.orderOut(nil)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        store.suppressEmptyWorkspaceCreation = true
        defer { store.suppressEmptyWorkspaceCreation = false }
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    @Test func closingLastVisibleWindowFindsAnotherWorkspacesLiveWindow() {
        let store = WorkspaceStore(storeURL: nil, isTesting: true)
        let existing = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
        existing.isReleasedWhenClosed = false
        defer { existing.close() }
        store.assignTab(tabIdentifier: existing.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        let empty = store.createWorkspace(name: "Empty")
        store.switchWorkspace(to: empty.id)
        #expect(AppDelegate.workspaceToResume(store: store, windows: [existing]) == WorkspaceStore.defaultWorkspaceId)
        #expect(AppDelegate.workspaceToResume(store: store, windows: []) == nil)
        let stillOpen = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        stillOpen.isReleasedWhenClosed = false
        defer { stillOpen.close() }
        store.assignTab(tabIdentifier: stillOpen.stableTabIdentifier, to: empty.id)
        #expect(AppDelegate.workspaceToResume(store: store, windows: [existing, stillOpen]) == nil)
    }

    @Test func pickerDeletesCurrentWorkspaceOnlyAfterConfirmation() async throws {
        let store = WorkspaceStore(storeURL: nil, isTesting: true)
        let workspace = store.createWorkspace(name: "Temporary")
        store.assignTab(tabIdentifier: "kept-tab", to: workspace.id)
        store.switchWorkspace(to: workspace.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        bar.workspaceStoreOverride = store
        window.contentView?.addSubview(bar)
        defer { Tako.WorkspacePicker.shown?.dismiss(); window.close() }
        bar.showWorkspaceMenu(at: .zero)
        let picker = try #require(Tako.WorkspacePicker.shown)
        let row = try #require(picker.rowViews.first { $0.accessibilityTitle() == "Delete Current Workspace..." })
        #expect(row.accessibilityPerformPress())
        for _ in 0..<1000 where TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = try #require(TerminalDialogView.pending(in: window))
        #expect(store.workspace(for: workspace.id) != nil)
        #expect(dialog.press("Cancel"))
        for _ in 0..<1000 where TerminalDialogView.pending(in: window) != nil { await Task.yield() }
        #expect(store.workspace(for: workspace.id) != nil)

        bar.showWorkspaceMenu(at: .zero)
        let again = try #require(Tako.WorkspacePicker.shown)
        let deleteRow = try #require(again.rowViews.first { $0.accessibilityTitle() == "Delete Current Workspace..." })
        #expect(deleteRow.accessibilityPerformPress())
        for _ in 0..<1000 where TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let confirmation = try #require(TerminalDialogView.pending(in: window))
        #expect(confirmation.press("Delete"))
        for _ in 0..<1000 where store.workspace(for: workspace.id) != nil { await Task.yield() }
        #expect(store.workspace(for: workspace.id) == nil)
        #expect(store.workspace(forTab: "kept-tab")?.id == WorkspaceStore.defaultWorkspaceId)
    }
}
