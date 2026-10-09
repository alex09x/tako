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

@MainActor
struct QuickTerminalControllerSurfaceTreeTests {
    @Test func newSplitCreatesASecondSurfaceAndSplitsTheTree() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)

        let created = try #require(controller.newSplit(at: original, direction: .right))

        #expect(controller.surfaceTree.contains(created))
        #expect(controller.surfaceTree.isSplit)
    }

    @Test func closeSurfaceOnRootLeafWithALivingProcessAnimatesOutWithoutTouchingTheTree() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let node = try #require(controller.surfaceTree.root)

        controller.closeSurface(node, withConfirmation: false)

        QTTestSupport.waitUntil { !controller.visible }
        #expect(!controller.visible)
        #expect(!controller.surfaceTree.isEmpty)
    }

    @Test func closeSurfaceOnRootLeafWithAnExitedProcessEmptiesTheTreeAndAnimatesOut() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let root = try #require(controller.focusedSurface)
        let node = try #require(controller.surfaceTree.root)
        root.pty?.terminate()

        controller.closeSurface(node, withConfirmation: false)

        #expect(controller.surfaceTree.isEmpty)
        QTTestSupport.waitUntil { !controller.visible }
        #expect(!controller.visible)
    }

    @Test func closeSurfaceOnANonRootLeafDelegatesToSuperRemovingOnlyThatLeaf() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let node = try #require(controller.surfaceTree.root?.node(view: created))

        controller.closeSurface(node, withConfirmation: false)

        #expect(!controller.surfaceTree.contains(created))
        #expect(controller.surfaceTree.contains(original))
        #expect(controller.visible)
    }

    @Test func closeSurfaceOnTheRootSplitDelegatesToSuperRemovingTheWholeSplit() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        _ = try #require(controller.newSplit(at: original, direction: .right))
        let rootNode = try #require(controller.surfaceTree.root)
        try #require(controller.surfaceTree.isSplit)

        controller.closeSurface(rootNode, withConfirmation: false)

        #expect(controller.surfaceTree.isEmpty)
    }

    @Test func surfaceTreeChangeWhileHiddenAnimatesBackIn() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        controller.animateOut()
        QTTestSupport.waitUntil { !controller.visible }
        try #require(!controller.visible)

        _ = controller.newSplit(at: original, direction: .right)

        QTTestSupport.waitUntil { controller.visible }
        #expect(controller.visible)
    }

    @Test func focusSurfaceWhenVisibleDelegatesToSuperWithoutCrashing() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        controller.focusSurface(surface)
        #expect(controller.visible)
    }

    @Test func focusSurfaceWhenHiddenAnimatesBackIn() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        controller.animateOut()
        QTTestSupport.waitUntil { !controller.visible }

        controller.focusSurface(surface)

        QTTestSupport.waitUntil { controller.visible }
        #expect(controller.visible)
    }

    @Test func focusSurfaceIgnoresViewsNotOwnedByThisQuickTerminal() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        let foreign = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { foreign.close() }
        controller.focusSurface(foreign)
        #expect(!controller.visible)
    }
}
