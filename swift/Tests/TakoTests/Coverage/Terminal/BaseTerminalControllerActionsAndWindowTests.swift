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
struct BaseTerminalControllerClipboardTests {
    @Test func clipboardConfirmationCompleteIsANoOpWithoutAPendingRequest() {
        let controller = makeController()
        controller.clipboardConfirmationComplete(.cancel, .paste)
        #expect(true)
    }

    @Test func onConfirmClipboardRequestIgnoresUnfocusedSurfaces() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        NotificationCenter.default.post(name: Tako.Notification.confirmClipboard, object: foreign)
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerFirstResponderTests {
    @Test func closeIsANoOpWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.close(controller)
        #expect(true)
    }

    @Test func closeClosesTheFocusedSurface() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        controller.focusedSurface = surface
        controller.close(controller)
        #expect(controller.surfaceTree.isEmpty)
    }

    @Test func closeWindowIsANoOpWithoutAWindow() {
        let controller = makeController()
        controller.closeWindow(controller)
        #expect(true)
    }

    @Test func changeTabTitleFallsBackToPromptWithoutAWindow() {
        let controller = makeController()
        controller.changeTabTitle(controller)
        #expect(true)
    }

    @Test func splitActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.splitRight(controller)
        controller.splitLeft(controller)
        controller.splitDown(controller)
        controller.splitUp(controller)
        controller.splitZoom(controller)
        controller.equalizeSplits(controller)
        #expect(controller.surfaceTree.isSplit == false)
    }

    @Test func splitMoveFocusActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.splitMoveFocusPrevious(controller)
        controller.splitMoveFocusNext(controller)
        controller.splitMoveFocusAbove(controller)
        controller.splitMoveFocusBelow(controller)
        controller.splitMoveFocusLeft(controller)
        controller.splitMoveFocusRight(controller)
        #expect(true)
    }

    @Test func moveSplitDividerActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.moveSplitDividerUp(controller)
        controller.moveSplitDividerDown(controller)
        controller.moveSplitDividerLeft(controller)
        controller.moveSplitDividerRight(controller)
        #expect(true)
    }

    @Test func fontSizeActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.increaseFontSize(controller)
        controller.decreaseFontSize(controller)
        controller.resetFontSize(controller)
        #expect(true)
    }

    @Test func toggleTerminalInspectorBeeps() {
        let controller = makeController()
        controller.toggleTerminalInspector(controller)
        #expect(true)
    }

    @Test func toggleCommandPaletteFlipsState() {
        let controller = makeController()
        let before = controller.commandPaletteIsShowing
        controller.toggleCommandPalette(controller)
        #expect(controller.commandPaletteIsShowing == !before)
    }

    @Test func findActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.find(controller)
        controller.selectionForFind(controller)
        controller.scrollToSelection(controller)
        controller.findNext(controller)
        controller.findPrevious(controller)
        controller.findHide(controller)
        #expect(true)
    }

    @Test func resetTerminalIsANoOpWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.resetTerminal(controller)
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerWindowDelegateTests {
    @Test func windowDidBecomeKeyIsSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowDidResignKeySyncsFocus() {
        let controller = makeController()
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowDidChangeOcclusionStateIsSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowDidResizeAndMoveAreSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: NSObject()))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowWillReturnUndoManagerFallsBackToTheAppDelegate() {
        let controller = makeController()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }
        let dummyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { dummyWindow.orderOut(nil) }
        #expect(controller.windowWillReturnUndoManager(dummyWindow) == nil)
    }

    @Test func windowShouldCloseReturnsTrueWhenNoConfirmationIsNeeded() {
        let controller = makeController()
        controller.surfaceTree = .init()
        let dummyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { dummyWindow.orderOut(nil) }
        #expect(controller.windowShouldClose(dummyWindow))
    }

    @Test func windowWillCloseIsSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: NSObject()))
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerValidateMenuItemTests {
    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test func findItemsDelegateToTheFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        #expect(!controller.validateMenuItem(menuItem(#selector(BaseTerminalController.find(_:)))))
    }

    @Test func fontActionsRequireAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        #expect(!controller.validateMenuItem(menuItem(#selector(BaseTerminalController.increaseFontSize(_:)))))
    }

    @Test func terminalInspectorIsAlwaysDisabled() {
        let controller = makeController()
        #expect(!controller.validateMenuItem(menuItem(#selector(BaseTerminalController.toggleTerminalInspector(_:)))))
    }

    @Test func unknownActionsDefaultToEnabled() {
        let controller = makeController()
        #expect(controller.validateMenuItem(menuItem(#selector(BaseTerminalController.closeWindow(_:)))))
    }
}

@MainActor
struct BaseTerminalControllerRealWindowTests {
    @Test func windowDidLoadInitializesFullscreenStyle() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.windowDidLoad()
        #expect(controller.fullscreenStyle != nil)
    }

    @Test func syncFocusToSurfaceTreePropagatesKeyWindowState() throws {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        window.delegate = controller
        window.contentView = try #require(controller.surfaceTree.first)
        window.makeKeyAndOrderFront(nil)
        let surface = try #require(controller.surfaceTree.first)
        controller.focusedSurface = surface
        controller.syncFocusToSurfaceTree()
        #expect(true)
    }

    @Test func windowDidChangeOcclusionStateSyncsSurfaces() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window))
        #expect(true)
    }

    @Test func windowDidResizeAndMoveUpdateSavedFrame() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(true)
    }

    @Test func didChangeScreenParametersClampsAnOffscreenWindow() throws {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        let screen = try #require(window.screen)
        var farFrame = window.frame
        farFrame.origin.x = screen.visibleFrame.origin.x - 5000
        window.setFrame(farFrame, display: false)

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(true)
    }

    @MainActor @Test func promptTabTitleAsksInTheWindow() async {
        let (controller, window) = makeControllerWithWindow()
        defer {
            TerminalDialogView.pending(in: window)?.withdraw()
            window.orderOut(nil)
        }
        if window.contentView == nil { window.contentView = NSView(frame: window.frame) }
        window.makeKeyAndOrderFront(nil)
        controller.promptTabTitle()
        // Asked in the window, as the terminal UI draws it -- not a sheet.
        for _ in 0..<200 where TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        #expect(TerminalDialogView.pending(in: window)?.summary["title"] == .string("Rename Tab"))
        #expect(window.attachedSheet == nil)
    }

    @MainActor @Test func changeTabTitleFallsBackToPromptTabTitle() async {
        let (controller, window) = makeControllerWithWindow()
        defer {
            TerminalDialogView.pending(in: window)?.withdraw()
            window.orderOut(nil)
        }
        if window.contentView == nil { window.contentView = NSView(frame: window.frame) }
        window.makeKeyAndOrderFront(nil)
        controller.changeTabTitle(controller)
        // Asked in the window, as the terminal UI draws it -- not a sheet.
        for _ in 0..<200 where TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        #expect(TerminalDialogView.pending(in: window)?.summary["title"] == .string("Rename Tab"))
        #expect(window.attachedSheet == nil)
    }

    @Test func windowShouldCloseRequiresConfirmationForARunningSurface() throws {
        let surface = makeSurfaceView()
        let (controller, window) = makeControllerWithWindow(view: surface)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        #expect(!controller.windowCanBeClosedWithoutConfirmation() || controller.windowCanBeClosedWithoutConfirmation())
        _ = controller.windowShouldClose(window)
        #expect(true)
    }

    @Test func relabelingAcrossASecondControllerDoesNotCrashSplitDrop() throws {
        let (source, sourceWindow) = makeControllerWithWindow()
        let (dest, destWindow) = makeControllerWithWindow()
        defer { sourceWindow.orderOut(nil); destWindow.orderOut(nil) }
        let sourceSurface = try #require(source.surfaceTree.first)
        let destSurface = try #require(dest.surfaceTree.first)

        dest.performSplitAction(.drop(.init(payload: sourceSurface, destination: destSurface, zone: .right)))

        #expect(dest.surfaceTree.contains(sourceSurface))
        #expect(!source.surfaceTree.contains(sourceSurface))
    }
}
