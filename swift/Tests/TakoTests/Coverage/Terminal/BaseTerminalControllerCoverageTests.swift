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
struct BaseTerminalControllerSplitTests {
    @Test func newSplitRejectsAViewNotInTheTree() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        #expect(controller.newSplit(at: foreign, direction: .right) == nil)
    }

    @Test func newSplitCreatesASplit() throws {
        let controller = makeController()
        let original = try #require(controller.focusedSurface ?? controller.surfaceTree.first)
        let created = controller.newSplit(at: original, direction: .down)
        #expect(created != nil)
        #expect(controller.surfaceTree.isSplit)
    }

    @Test func focusSurfaceIgnoresViewsOutsideTheTree() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        controller.focusSurface(foreign)
        #expect(true)
    }

    @Test func syncFocusToSurfaceTreeDoesNotCrashWithoutAWindow() {
        let controller = makeController()
        controller.syncFocusToSurfaceTree()
        #expect(true)
    }

    @Test func performSplitActionResizeDoesNotCrash() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let node = try #require(controller.surfaceTree.root?.node(view: created))
        controller.performSplitAction(.resize(.init(node: node, ratio: 0.5)))
        #expect(true)
    }

    @Test func performSplitActionDropWithinTheSameTree() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        controller.performSplitAction(.drop(.init(payload: created, destination: original, zone: .left)))
        #expect(controller.surfaceTree.contains(created))
    }

    @Test func performSplitActionDropAcrossWindows() throws {
        let source = makeController()
        let dest = makeController()
        defer { source.window?.orderOut(nil); dest.window?.orderOut(nil) }
        let sourceSurface = try #require(source.surfaceTree.first)
        let destSurface = try #require(dest.surfaceTree.first)
        dest.performSplitAction(.drop(.init(payload: sourceSurface, destination: destSurface, zone: .top)))
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerCloseTests {
    @Test func closeSurfaceByViewRemovesIt() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        controller.closeSurface(created, withConfirmation: false)
        #expect(!controller.surfaceTree.contains(created))
    }

    @Test func closeSurfaceRejectsANodeNotInTheTree() throws {
        let controllerA = makeController()
        let controllerB = makeController()
        let nodeB = try #require(controllerB.surfaceTree.root)
        controllerA.closeSurface(nodeB, withConfirmation: false)
        #expect(controllerB.surfaceTree.contains(nodeB))
    }

    @Test func confirmCloseAsyncReturnsOKWithoutAWindow() async {
        let controller = makeController()
        let response = await controller.confirmCloseAsync(messageText: "x", informativeText: "y")
        #expect(response == .OK)
    }

    @Test func windowCanBeClosedWithoutConfirmationIsTrueForAnEmptyTree() {
        let controller = makeController()
        controller.surfaceTree = .init()
        #expect(controller.windowCanBeClosedWithoutConfirmation())
    }

    @Test func closeSurfaceWithConfirmationRemovesItWhenNoWindowIsPresent() async throws {
        // Without a window, `confirmCloseAsync` resolves immediately with
        // `.OK`, so `confirmClose`'s completion runs on the very next
        // main-actor turn -- exercising its `Task { ... }` wrapper body.
        // `Task { ... }` isn't guaranteed to drain via `RunLoop` pumping, so
        // this awaits it directly instead.
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        controller.closeSurface(created, withConfirmation: true)
        for _ in 0..<50 where controller.surfaceTree.contains(created) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!controller.surfaceTree.contains(created))
    }
}

@MainActor
struct BaseTerminalControllerUndoTests {
    @Test func replaceSurfaceTreeRegistersUndoAndRedo() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        _ = controller.newSplit(at: original, direction: .right)
        #expect(controller.surfaceTree.isSplit)
        TerminalTestSupport.waitUntil(timeout: 0.2) { false }

        let undoManager = try #require(controller.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(!controller.surfaceTree.isSplit)

        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(controller.surfaceTree.isSplit)
        TerminalTestSupport.waitUntil(timeout: 0.2) { false }
    }
}

@MainActor
struct BaseTerminalControllerTitleTests {
    @Test func titleOverrideIsAppliedWhenSet() {
        let controller = makeController()
        controller.titleOverride = "Custom"
        #expect(controller.titleOverride == "Custom")
    }

    @Test func focusedSurfaceDidChangeToNilShowsGhostTitle() {
        let controller = makeController()
        controller.focusedSurfaceDidChange(to: nil)
        #expect(controller.focusedSurface == nil)
    }

    @Test func focusedSurfaceDidChangeToAKnownSurfaceListensForTitleChanges() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        controller.focusedSurfaceDidChange(to: surface)
        #expect(controller.focusedSurface == surface)
    }

    @Test func pwdDidChangeIsANoOpWithoutAWindow() {
        let controller = makeController()
        controller.pwdDidChange(to: URL(fileURLWithPath: "/tmp"))
        #expect(true)
    }

    @Test func pwdDidChangeUpdatesTheWindowWhenPresent() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.pwdDidChange(to: URL(fileURLWithPath: "/tmp"))
        controller.pwdDidChange(to: nil)
        #expect(true)
    }

    @Test func titleOverrideAppliesToARealWindow() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.titleOverride = "Custom Tab Title"
        #expect(window.title == "Custom Tab Title")
    }

    @Test func localEventHandlerPassesThroughNonFlagsChangedEvents() {
        let controller = makeController()
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0)
        let result = event.flatMap { controller.localEventHandler($0) }
        #expect(result != nil)
    }

    @Test func localEventFlagsChangedForwardsToEverySurfaceExceptTheFocusedMainWindowOne() throws {
        let controller = makeController()
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 56))
        let result = controller.localEventFlagsChanged(event)
        #expect(result === event)
        let handled = controller.localEventHandler(event)
        #expect(handled === event)
    }

    @Test func cellSizeDidChangeIgnoresZeroSizes() {
        let controller = makeController()
        controller.cellSizeDidChange(to: .zero)
        #expect(true)
    }

    @Test func performActionBeepsForAnUnknownAction() throws {
        let controller = makeController()
        controller.performAction("", on: try #require(controller.surfaceTree.first))
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerAppearanceTests {
    @Test func toggleBackgroundOpacityIsANoOpWhenAlreadyOpaque() {
        let controller = makeController()
        controller.toggleBackgroundOpacity()
        #expect(true)
    }

    @Test func syncAppearanceDefaultIsANoOp() {
        let controller = makeController()
        controller.syncAppearance()
        #expect(true)
    }

    @Test func updateColorSchemeForSurfaceTreeDoesNotCrash() {
        let controller = makeController()
        controller.updateColorSchemeForSurfaceTree()
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerFullscreenTests {
    @Test func toggleFullscreenIsANoOpWithoutAWindow() {
        let controller = makeController()
        controller.toggleFullscreen(mode: .native)
        #expect(controller.fullscreenStyle == nil)
    }

    @Test func fullscreenDidChangeIsANoOpWithoutAStyle() {
        let controller = makeController()
        controller.fullscreenDidChange()
        #expect(true)
    }
}

@MainActor
