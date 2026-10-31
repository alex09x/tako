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
import Testing
@testable import Tako

@MainActor
@Suite(.serialized)
struct SessionRecoverySafetyTests {
    @Test func normalQuitKeepsWorkspaceTabAssociation() {
        let wasSuppressed = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        let wasDetaching = SurfaceSession.appIsDetaching
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = true
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            SurfaceSession.appIsDetaching = wasDetaching
            window.close(); store.resetForTesting()
            Tako.CustomTabGroup.suppressWindowOrderingForTesting = wasSuppressed
        }
        _ = Tako.CustomTabGroup.group(for: window)
        let id = window.stableTabIdentifier
        store.assignTab(tabIdentifier: id, to: WorkspaceStore.defaultWorkspaceId)
        SurfaceSession.appIsDetaching = true
        Tako.CustomTabGroup.close(window)
        #expect(store.workspace(forTab: id)?.id == WorkspaceStore.defaultWorkspaceId)
    }

    @Test func layoutIncludesTabsHiddenInOtherWorkspaces() {
        let wasSuppressed = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = true
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let firstSurface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let secondSurface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let (first, firstWindow) = TerminalTestSupport.makeController(surfaceTree: .init(view: firstSurface))
        let (second, secondWindow) = TerminalTestSupport.makeController(surfaceTree: .init(view: secondSurface))
        defer {
            Tako.CustomTabGroup.close(firstWindow); Tako.CustomTabGroup.close(secondWindow)
            firstWindow.close(); secondWindow.close(); firstSurface.close(); secondSurface.close()
            store.resetForTesting()
            Tako.CustomTabGroup.suppressWindowOrderingForTesting = wasSuppressed
        }
        let hidden = store.createWorkspace(name: "Hidden")
        Tako.CustomTabGroup.join(secondWindow, to: firstWindow, select: false)
        store.assignTab(tabIdentifier: firstWindow.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        store.assignTab(tabIdentifier: secondWindow.stableTabIdentifier, to: hidden.id)
        let group = Tako.CustomTabGroup.group(for: firstWindow)
        #expect(group.visibleWindows.count == 1)
        let journal = LayoutRecorder.capture(controllers: [first, second])
        #expect(journal.windows.count == 1)
        #expect(journal.windows.first?.tabs.count == 2)
    }
}
