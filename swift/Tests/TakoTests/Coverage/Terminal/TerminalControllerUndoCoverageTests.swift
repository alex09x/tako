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
@testable import Tako
@testable import TakoKit

@MainActor
struct TerminalControllerCloseTabUndoTests {
    @Test func closeTabImmediatelyRegistersUndoAndRedoWithMultipleTabs() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer { TerminalTestSupport.tearDown(a, aWindow) }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.makeKeyAndOrderFront(nil)
                bWindow.makeKeyAndOrderFront(nil)

                b.closeTabImmediately()
                #expect(!bWindow.isVisible)

                let undoManager = try #require(b.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
            }
        }
    }

    @Test func closeOtherTabsImmediatelyRegistersUndoAndRedo() async throws {
        try await withRealAppDelegate { _ in
            try await withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer { TerminalTestSupport.tearDown(a, aWindow) }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.makeKeyAndOrderFront(nil)

                a.closeOtherTabs(nil)
                #expect(!bWindow.isVisible)

                let undoManager = try #require(a.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                try await Task.sleep(nanoseconds: 100_000_000)
                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    @Test func closeTabsOnTheRightImmediatelyRegistersUndoAndRedo() async throws {
        try await withRealAppDelegate { _ in
            try await withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer { TerminalTestSupport.tearDown(a, aWindow) }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.makeKeyAndOrderFront(nil)

                a.closeTabsOnTheRight(nil)
                #expect(!bWindow.isVisible)

                let undoManager = try #require(a.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                try await Task.sleep(nanoseconds: 100_000_000)
                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

@MainActor
struct TerminalControllerCloseWindowUndoTests {
    @Test func closeWindowImmediatelyRegistersUndoForASingleWindow() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (controller, window) = TerminalTestSupport.loaded()
                window.orderFrontRegardless()

                controller.closeWindowImmediately()

                let undoManager = try #require(controller.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
            }
        }
    }

    @Test func closeWindowImmediatelyRegistersUndoForATabGroup() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.orderFrontRegardless()
                bWindow.makeKeyAndOrderFront(nil)

                a.closeWindowImmediately()
                #expect(!aWindow.isVisible)
                #expect(!bWindow.isVisible)

                let undoManager = try #require(a.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
            }
        }
    }

    @Test func redCloseButtonClosesTheEntireTabGroup() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer {
                    TerminalTestSupport.tearDown(a, aWindow)
                    TerminalTestSupport.tearDown(b, bWindow)
                }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.orderFrontRegardless()
                bWindow.makeKeyAndOrderFront(nil)
                #expect(aWindow.isVisible)
                #expect(bWindow.isVisible)

                let shouldClose = b.windowShouldClose(bWindow)

                #expect(!shouldClose)
                #expect(!aWindow.isVisible)
                #expect(!bWindow.isVisible)
            }
        }
    }

    @Test func closeTabActionClosesOnlyTheSelectedTab() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer {
                    TerminalTestSupport.tearDown(a, aWindow)
                    TerminalTestSupport.tearDown(b, bWindow)
                }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.orderFrontRegardless()
                bWindow.makeKeyAndOrderFront(nil)
                #expect(aWindow.isVisible)
                #expect(bWindow.isVisible)

                b.closeTab(nil)

                #expect(aWindow.isVisible)
                #expect(!bWindow.isVisible)
            }
        }
    }

    @Test func clickingTheTabBarCloseButtonClosesOnlyTheSelectedTab() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                aWindow.windowController = a
                aWindow.delegate = a
                bWindow.windowController = b
                bWindow.delegate = b
                defer {
                    TerminalTestSupport.tearDown(a, aWindow)
                    TerminalTestSupport.tearDown(b, bWindow)
                }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: false)
                aWindow.makeKeyAndOrderFront(nil)
                bWindow.orderFrontRegardless()
                #expect(aWindow.isVisible)
                #expect(bWindow.isVisible)

                let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 38))
                aWindow.contentView?.addSubview(bar)
                let image = NSImage(size: bar.bounds.size)
                image.lockFocus()
                bar.draw(bar.bounds)
                image.unlockFocus()

                // Tab 0 (aWindow) is active and sits at x: 90...195.
                // Its close glyph is centered near x: 195.
                let clickEvent = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: NSPoint(x: 195, y: 14),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: aWindow.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1)!
                bar.mouseDown(with: clickEvent)

                #expect(!aWindow.isVisible)
                #expect(bWindow.isVisible)
            }
        }
    }

    @Test func clickingTheTabBarCloseButtonOnBackgroundTabClosesBackgroundTab() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                aWindow.windowController = a
                aWindow.delegate = a
                bWindow.windowController = b
                bWindow.delegate = b
                defer {
                    TerminalTestSupport.tearDown(a, aWindow)
                    TerminalTestSupport.tearDown(b, bWindow)
                }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: false)
                aWindow.makeKeyAndOrderFront(nil)
                bWindow.orderFrontRegardless()
                #expect(aWindow.isVisible)
                #expect(bWindow.isVisible)

                let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
                aWindow.contentView?.addSubview(bar)
                let image = NSImage(size: bar.bounds.size)
                image.lockFocus()
                bar.draw(bar.bounds)
                image.unlockFocus()

                // Tab 1 (bWindow) is in the background and sits at x: 210...330.
                // Its close glyph is centered near x: 314.
                let clickEvent = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: NSPoint(x: 314, y: 14),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: aWindow.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1)!
                bar.mouseDown(with: clickEvent)

                #expect(aWindow.isVisible)
                #expect(!bWindow.isVisible)
            }
        }
    }
}
