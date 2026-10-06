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
struct BaseTerminalControllerNotificationTests {
    @Test func didChangeScreenParametersIsANoOpWithoutAWindow() {
        let controller = makeController()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(true)
    }

    @Test func takoConfigDidChangeUpdatesDerivedConfig() {
        let controller = makeController()
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: nil,
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])
        #expect(true)
    }

    @Test func takoConfigDidChangeIgnoresSurfaceScoped() {
        let controller = makeController()
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: NSObject(),
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])
        #expect(true)
    }

    @Test func takoCommandPaletteDidToggleIgnoresUnknownSurfaces() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        NotificationCenter.default.post(name: .takoCommandPaletteDidToggle, object: foreign)
        #expect(!controller.commandPaletteIsShowing)
    }

    @Test func takoCommandPaletteDidToggleTogglesForAKnownSurface() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: .takoCommandPaletteDidToggle, object: surface)
        #expect(controller.commandPaletteIsShowing)
    }

    @Test func takoMaximizeDidToggleIsANoOpWithoutAWindow() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: .takoMaximizeDidToggle, object: surface)
        #expect(true)
    }

    @Test func takoDidCloseSurfaceRemovesTheTargetNode() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(
            name: Tako.Notification.takoCloseSurface,
            object: created,
            userInfo: ["process_alive": false])
        #expect(!controller.surfaceTree.contains(created))
    }

    @Test func takoDidNewSplitCreatesASplitForEveryDirection() throws {
        for direction: tako_action_split_direction_e in [
            TAKO_SPLIT_DIRECTION_RIGHT, TAKO_SPLIT_DIRECTION_LEFT,
            TAKO_SPLIT_DIRECTION_DOWN, TAKO_SPLIT_DIRECTION_UP,
        ] {
            let controller = makeController()
            let original = try #require(controller.surfaceTree.first)
            NotificationCenter.default.post(
                name: Tako.Notification.takoNewSplit,
                object: original,
                userInfo: ["direction": direction])
            #expect(controller.surfaceTree.isSplit)
        }
    }

    @Test func takoDidEqualizeSplitsIgnoresSurfacesOutsideTheTree() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        NotificationCenter.default.post(name: Tako.Notification.didEqualizeSplits, object: foreign)
        #expect(true)
    }

    @Test func takoDidFocusSplitMovesFocus() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(
            name: Tako.Notification.takoFocusSplit,
            object: original,
            userInfo: [Tako.Notification.SplitDirectionKey: Tako.SplitFocusDirection.next])
        _ = created
        #expect(true)
    }

    @Test func takoDidToggleSplitZoomTogglesZoom() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(name: Tako.Notification.didToggleSplitZoom, object: created)
        #expect(controller.surfaceTree.zoomed != nil)
        NotificationCenter.default.post(name: Tako.Notification.didToggleSplitZoom, object: created)
        #expect(controller.surfaceTree.zoomed == nil)
    }

    @Test func takoDidToggleSplitZoomSelectsTheWindowWhenPresent() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        controller.window = window
        defer { window.orderOut(nil) }
        NotificationCenter.default.post(name: Tako.Notification.didToggleSplitZoom, object: created)
        #expect(controller.surfaceTree.zoomed != nil)
    }

    @Test func takoDidFocusSplitPreservesOrClearsZoomState() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let zoomedNode = try #require(controller.surfaceTree.root?.node(view: created))
        controller.surfaceTree = SplitTree(root: controller.surfaceTree.root, zoomed: zoomedNode)
        #expect(controller.surfaceTree.zoomed != nil)
        NotificationCenter.default.post(
            name: Tako.Notification.takoFocusSplit,
            object: created,
            userInfo: [Tako.Notification.SplitDirectionKey: Tako.SplitFocusDirection.previous])
        #expect(true)
    }

    @Test func takoDidResizeSplitResizesAKnownNode() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(
            name: Tako.Notification.didResizeSplit,
            object: created,
            userInfo: [
                Tako.Notification.ResizeSplitDirectionKey: Tako.SplitResizeDirection.left,
                Tako.Notification.ResizeSplitAmountKey: UInt16(10),
            ])
        #expect(true)
    }

    @Test func takoDidPresentTerminalHighlightsTheTarget() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: surface)
        #expect(true)
    }

    @Test func takoDidPresentTerminalSelectsTheWindowWhenPresent() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        controller.window = window
        defer { window.orderOut(nil) }
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: surface)
        #expect(true)
    }

    @Test func takoSurfaceDragEndedNoTargetIsANoOpWithoutASplit() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: .takoSurfaceDragEndedNoTarget, object: surface)
        #expect(controller.surfaceTree.contains(surface))
    }

    @Test func takoSurfaceDragEndedNoTargetMovesASplitToANewWindow() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(name: .takoSurfaceDragEndedNoTarget, object: created)
        #expect(!controller.surfaceTree.contains(created))
    }
}

@MainActor
