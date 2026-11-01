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

@Suite(.serialized) @MainActor
struct WindowPresentationRaceTests {
    @Test func hidingAnInactiveWorkspaceCancelsItsPendingPresentation() {
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let (controller, window) = TerminalTestSupport.loaded()
        defer { Tako.CustomTabGroup.leave(window); window.close(); store.resetForTesting(); withExtendedLifetime(controller) {} }
        let hidden = store.createWorkspace(name: "Hidden")
        _ = Tako.CustomTabGroup.group(for: window)
        store.assignTab(tabIdentifier: window.stableTabIdentifier, to: hidden.id)
        var presented = false
        controller.scheduleInitialPresentation { presented = true }
        Tako.CustomTabGroup.group(for: window).hideInactiveWindows()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(!presented)
    }

    @Test func selectingAnotherTabCancelsTheOldTabsPendingPresentation() {
        let (first, firstWindow) = TerminalTestSupport.loaded()
        let (second, secondWindow) = TerminalTestSupport.loaded()
        defer {
            Tako.CustomTabGroup.leave(firstWindow); Tako.CustomTabGroup.leave(secondWindow)
            firstWindow.close(); secondWindow.close(); withExtendedLifetime([first, second]) {}
        }
        Tako.CustomTabGroup.join(secondWindow, to: firstWindow, select: false)
        var presented = false
        first.scheduleInitialPresentation { presented = true }
        Tako.CustomTabGroup.group(for: firstWindow).select(secondWindow)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(!presented)
    }

    @Test func transferringAnotherTabDoesNotLeaveThePreviousTabVisible() {
        let controllers = (0..<4).map { _ in TerminalTestSupport.loaded() }
        let windows = controllers.map { $0.window }
        defer {
            for window in windows { Tako.CustomTabGroup.leave(window); window.close() }
            withExtendedLifetime(controllers) {}
        }
        Tako.CustomTabGroup.join(windows[1], to: windows[0], select: false)
        Tako.CustomTabGroup.join(windows[2], to: windows[0], select: false)
        windows[0].orderFrontRegardless()
        let group = Tako.CustomTabGroup.group(for: windows[0])
        group.select(windows[1])
        #expect(group.pendingOrderOutWindow === windows[0])
        Tako.CustomTabGroup.join(windows[2], to: windows[3], select: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(!windows[0].isVisible)
        #expect(group.selectedWindow === windows[1])
        #expect(!group.windows.contains(windows[2]))
    }
}
