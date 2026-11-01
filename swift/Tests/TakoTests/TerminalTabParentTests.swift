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

@Suite(.serialized) @MainActor
struct TerminalTabParentTests {
    @Test func implicitNewTabDoesNotUseLastMainFromAnotherWorkspace() {
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let (active, activeWindow) = TerminalTestSupport.loaded()
        let (other, otherWindow) = TerminalTestSupport.loaded()
        defer {
            TerminalController.lastMain = nil
            Tako.CustomTabGroup.leave(activeWindow)
            Tako.CustomTabGroup.leave(otherWindow)
            activeWindow.close()
            otherWindow.close()
            store.resetForTesting()
            withExtendedLifetime([active, other]) {}
        }
        let otherWorkspace = store.createWorkspace(name: "Other")
        store.assignTab(tabIdentifier: activeWindow.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        store.assignTab(tabIdentifier: otherWindow.stableTabIdentifier, to: otherWorkspace.id)
        _ = store.switchWorkspace(to: WorkspaceStore.defaultWorkspaceId)
        TerminalController.lastMain = other
        #expect(TerminalController.preferredTabParent === active)
        TerminalController.lastMain = nil
        #expect(TerminalController.preferredTabParent === active)
        store.assignTab(tabIdentifier: activeWindow.stableTabIdentifier, to: otherWorkspace.id)
        #expect(TerminalController.preferredTabParent == nil)
    }
}
