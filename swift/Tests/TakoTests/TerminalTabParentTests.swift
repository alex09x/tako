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
        let (unrelated, unrelatedWindow) = TerminalTestSupport.loaded()
        defer {
            TerminalController.lastMain = nil
            Tako.CustomTabGroup.leave(activeWindow)
            Tako.CustomTabGroup.leave(otherWindow)
            Tako.CustomTabGroup.leave(unrelatedWindow)
            activeWindow.close()
            otherWindow.close()
            unrelatedWindow.close()
            store.resetForTesting()
            withExtendedLifetime([active, other, unrelated]) {}
        }
        // Other suites may retain default-workspace controllers. Only these
        // fixtures belong to the unique active workspace this case asks about.
        let activeWorkspace = store.createWorkspace(name: "Active fixture")
        let otherWorkspace = store.createWorkspace(name: "Other")
        store.assignTab(tabIdentifier: activeWindow.stableTabIdentifier, to: activeWorkspace.id)
        store.assignTab(tabIdentifier: otherWindow.stableTabIdentifier, to: otherWorkspace.id)
        // Model a controller left in the process by a preceding test suite.
        store.assignTab(tabIdentifier: unrelatedWindow.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        _ = store.switchWorkspace(to: activeWorkspace.id)
        TerminalController.lastMain = other
        #expect(TerminalController.preferredTabParent === active)
        TerminalController.lastMain = nil
        #expect(TerminalController.preferredTabParent === active)
        store.assignTab(tabIdentifier: activeWindow.stableTabIdentifier, to: otherWorkspace.id)
        #expect(TerminalController.preferredTabParent == nil)
    }
}
