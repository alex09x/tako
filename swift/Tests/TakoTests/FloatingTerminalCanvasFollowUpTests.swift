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
import SwiftUI
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct FloatingTerminalCanvasFollowUpTests {
    private func findAppKitView(identifier targetId: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == targetId {
            return root
        }
        for subview in root.subviews {
            if let match = findAppKitView(identifier: targetId, in: subview) {
                return match
            }
        }
        return nil
    }

    private struct AXSnapshotNode {
        let identifier: String
        let role: String
        let value: String?
        let label: String?
        let frameInScreen: CGRect
        let children: [AXSnapshotNode]
    }

    private func snapshotAppKitAX(_ root: AnyObject, depth: Int = 0) -> AXSnapshotNode? {
        guard depth <= 28 else { return nil }
        let proto = root as? NSAccessibilityProtocol
        let id = proto?.accessibilityIdentifier() ?? ""
        let role = proto?.accessibilityRole()?.rawValue ?? ""
        let val = proto?.accessibilityValue() as? String
        let lbl = proto?.accessibilityLabel()
        let frame = proto?.accessibilityFrame() ?? .zero

        var rawChildren: [Any] = proto?.accessibilityChildren() ?? []
        if rawChildren.isEmpty, let view = root as? NSView {
            rawChildren = NSAccessibility.unignoredChildren(from: view.subviews)
        }
        let kids = rawChildren.compactMap { snapshotAppKitAX($0 as AnyObject, depth: depth + 1) }
        return AXSnapshotNode(identifier: id, role: role, value: val, label: lbl, frameInScreen: frame, children: kids)
    }

    private func flattenAX(_ node: AXSnapshotNode, into out: inout [AXSnapshotNode]) {
        out.append(node)
        for child in node.children {
            flattenAX(child, into: &out)
        }
    }

    private func collectWindowHIServicesAX(matching window: NSWindow) -> [AXSnapshotNode] {
        guard let contentView = window.contentView,
              let root = snapshotAppKitAX(contentView) else {
            return []
        }
        var all: [AXSnapshotNode] = []
        flattenAX(root, into: &all)
        return all
    }

    @Test func preferredNormalRectSurvivesShelfRestoreAndSnapshotRoundTrip() throws {
        let canvas = CGSize(width: 1000, height: 700)
        let app = Tako.App()
        let pA = Tako.SurfaceView(app)
        let pB = Tako.SurfaceView(app)
        var tree = SplitTree<Tako.SurfaceView>(view: pA)
        tree = try tree.inserting(view: pB, at: pA, direction: .right)

        let store = FloatingCanvasStore()
        store.sync(with: tree, fallbackSize: canvas)

        let preferredA = CGRect(x: 8, y: 8, width: 480, height: 684)
        store.setInteractiveRect(preferredA, for: pA.id, in: canvas)
        store.commitInteractiveRect(for: pA.id, in: canvas)
        #expect(store.state(for: pA.id)?.rect == preferredA)

        // Maximize A -> minimize A & B -> snapshot roundtrip while shelf is active ->
        // restore A while B is still minimized (workArea height = 656) -> restore B -> toggle A to .normal
        store.toggleMaximize(pA.id, in: canvas)
        store.minimize(pA.id)
        store.minimize(pB.id)

        let encoded = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(FloatingCanvasSnapshot.self, from: encoded)
        let reloaded = FloatingCanvasStore()
        reloaded.loadRestoredSnapshot(decoded, for: tree, fallbackSize: canvas)
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)

        #expect(reloaded.restore(pA.id, in: canvas) == .maximized)
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)

        // While B is still minimized, toggling A to .normal clamps only its presentedFrame (height 656),
        // keeping its preferred rect (y: 8, height: 684) intact for when B is restored.
        reloaded.toggleMaximize(pA.id, in: canvas)
        let clampedPresented = FloatingPaneGeometry.presentedFrame(
            for: try #require(reloaded.state(for: pA.id)),
            in: canvas,
            hasMinimizedPanes: reloaded.hasMinimizedPanes
        )
        #expect(clampedPresented.maxY <= 656)
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)

        #expect(reloaded.restore(pB.id, in: canvas) == .normal)
        let fullPresented = FloatingPaneGeometry.presentedFrame(
            for: try #require(reloaded.state(for: pA.id)),
            in: canvas,
            hasMinimizedPanes: reloaded.hasMinimizedPanes
        )
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)
        #expect(fullPresented == preferredA)
    }

    @Test func cyclicPreviousNextIsRaiseInvariantAndStrictlyTransitive() throws {
        let canvas = CGSize(width: 1000, height: 700)
        let app = Tako.App()
        let pA = Tako.SurfaceView(app)
        let pB = Tako.SurfaceView(app)
        let pC = Tako.SurfaceView(app)
        var tree = SplitTree<Tako.SurfaceView>(view: pA)
        tree = try tree.inserting(view: pB, at: pA, direction: .right)
        tree = try tree.inserting(view: pC, at: pB, direction: .right)

        let store = FloatingCanvasStore()
        store.sync(with: tree, fallbackSize: canvas)
        store.toggleMaximize(pA.id, in: canvas)
        store.toggleMaximize(pB.id, in: canvas)
        store.toggleMaximize(pC.id, in: canvas)

        // All three panes share identical maximized frames; raising on focus must never trap previous/next in a 2-pane loop.
        let step1 = try #require(store.spatialFocusTarget(direction: .previous, from: pC.id, in: canvas))
        store.bringToFront(step1)
        let step2 = try #require(store.spatialFocusTarget(direction: .previous, from: step1, in: canvas))
        store.bringToFront(step2)
        let step3 = try #require(store.spatialFocusTarget(direction: .previous, from: step2, in: canvas))
        #expect(Set([step1, step2, step3]) == Set([pA.id, pB.id, pC.id]))
        #expect(step3 == pC.id)

        // Near-collinear y offsets (0, 5, 10) must still form a strict deterministic cycle with zero zOrder perturbation.
        store.toggleMaximize(pA.id, in: canvas)
        store.toggleMaximize(pB.id, in: canvas)
        store.toggleMaximize(pC.id, in: canvas)
        store.setInteractiveRect(CGRect(x: 500, y: 0, width: 300, height: 250), for: pA.id, in: canvas)
        store.setInteractiveRect(CGRect(x: 300, y: 5, width: 300, height: 250), for: pB.id, in: canvas)
        store.setInteractiveRect(CGRect(x: 100, y: 10, width: 300, height: 250), for: pC.id, in: canvas)
        let n1 = try #require(store.spatialFocusTarget(direction: .next, from: pA.id, in: canvas))
        store.bringToFront(n1)
        let n2 = try #require(store.spatialFocusTarget(direction: .next, from: n1, in: canvas))
        store.bringToFront(n2)
        let n3 = try #require(store.spatialFocusTarget(direction: .next, from: n2, in: canvas))
        #expect(Set([n1, n2, n3]) == Set([pA.id, pB.id, pC.id]))
    }

    @Test func shelfCardsAlignToBottomRightInHostedCanvas() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let sidebarWidth = SessionSidebarWidth.current()
        window.setContentSize(NSSize(width: 1000 + sidebarWidth, height: 700))
        controller.showWindow(nil)

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p3 = try #require(controller.newSplit(at: p2, direction: .right))
        controller.minimizeFloatingPane(p1)
        controller.minimizeFloatingPane(p2)

        let contentView = try #require(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let c1 = try #require(findAppKitView(identifier: "FloatingMinimizedCard-\(p1.id.uuidString.lowercased())", in: contentView))
        let c2 = try #require(findAppKitView(identifier: "FloatingMinimizedCard-\(p2.id.uuidString.lowercased())", in: contentView))
        let r1 = c1.convert(c1.bounds, to: contentView)
        let r2 = c2.convert(c2.bounds, to: contentView)
        let rightmostMaxX = max(r1.maxX, r2.maxX)
        let expectedMaxX = contentView.bounds.maxX - 12

        #expect(abs(rightmostMaxX - expectedMaxX) <= 6,
                "Expected rightmost shelf card maxX ≈ \(expectedMaxX), got \(rightmostMaxX) (r1=\(r1), r2=\(r2), bounds=\(contentView.bounds))")
        #expect(min(r1.minY, r2.minY) <= 16,
                "Expected shelf cards in bottom 44pt band of AppKit contentView, got r1=\(r1), r2=\(r2)")
        _ = p3
    }

    @Test func forgedExtremeZOrderNormalizesWithoutOverflow() throws {
        let canvas = CGSize(width: 960, height: 640)
        let app = Tako.App()
        let p1 = Tako.SurfaceView(app)
        let p2 = Tako.SurfaceView(app)
        var tree = SplitTree<Tako.SurfaceView>(view: p1)
        tree = try tree.inserting(view: p2, at: p1, direction: .right)

        let forged = FloatingCanvasSnapshot(
            version: 1,
            panes: [
                FloatingPaneState(surfaceId: p1.id, mode: .normal, restoreMode: .normal,
                                  rect: CGRect(x: 20, y: 20, width: 400, height: 300), zOrder: Int.max)
            ]
        )
        let store = FloatingCanvasStore()
        store.loadRestoredSnapshot(forged, for: tree, fallbackSize: canvas)
        store.bringToFront(p1.id)
        store.bringToFront(p2.id)

        let z1 = try #require(store.state(for: p1.id)?.zOrder)
        let z2 = try #require(store.state(for: p2.id)?.zOrder)
        #expect(z2 > z1)
        #expect(z2 < 100)
    }

    @Test func statusColorsUseCanonicalDotKeysAndHeaderMenuDetachesPane() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }

        let p1 = try #require(controller.focusedSurface)
        let workingColor = FloatingPaneGeometry.statusNSColor(for: .working, surface: p1)
        let approvalColor = FloatingPaneGeometry.statusNSColor(for: .needsApproval, surface: p1)
        let doneColor = FloatingPaneGeometry.statusNSColor(for: .done, surface: p1)
        let errorColor = FloatingPaneGeometry.statusNSColor(for: .error, surface: p1)
        let idleColor = FloatingPaneGeometry.statusNSColor(for: .idle, surface: p1)

        #expect(workingColor == Tako.tabStatusColor(for: "ember", surface: p1))
        #expect(approvalColor == Tako.tabStatusColor(for: "claw", surface: p1))
        #expect(doneColor == Tako.tabStatusColor(for: "ok", surface: p1))
        #expect(errorColor == Tako.tabStatusColor(for: "error", surface: p1))
        #expect(idleColor == Tako.tabStatusColor(for: "dim", surface: p1))
        #expect(workingColor != doneColor)
        #expect(errorColor != doneColor)
        #expect(idleColor != doneColor)

        let contentView = try #require(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()

        let h1 = try #require(
            findAppKitView(identifier: "FloatingPaneHeader-\(p1.id.uuidString.lowercased())", in: contentView)
                as? FloatingPaneHeaderDragNSView
        )
        let fakeEvent = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let singleMenu = try #require(h1.menu(for: fakeEvent))
        #expect(singleMenu.item(withTitle: "Move Pane to New Window")?.isEnabled == false)

        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()

        let h2 = try #require(
            findAppKitView(identifier: "FloatingPaneHeader-\(p2.id.uuidString.lowercased())", in: contentView)
                as? FloatingPaneHeaderDragNSView
        )
        let splitMenu = try #require(h2.menu(for: fakeEvent))
        let moveItem = try #require(splitMenu.item(withTitle: "Move Pane to New Window"))
        #expect(moveItem.isEnabled == true)
    }

    @Test func floatingPaneRootExposesRealAXGroupWithHeaderIncludedFrameLiveValueAndReachableChildren() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let sidebarWidth = SessionSidebarWidth.current()
        window.setContentSize(NSSize(width: 1000 + sidebarWidth, height: 700))
        controller.showWindow(nil)

        let p1 = try #require(controller.focusedSurface)
        let initialP1PTY = p1.pty
        let p1Key = p1.id.uuidString.lowercased()
        let contentView = try #require(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let nodes = collectWindowHIServicesAX(matching: window)
        let summary = nodes
            .filter { !$0.identifier.isEmpty || $0.role == "AXTextArea" }
            .map { "\($0.role)#\"\($0.identifier)\" val=\($0.value ?? "nil") frame=\($0.frameInScreen)" }
            .joined(separator: " | ")

        let paneMatches = nodes.filter { $0.identifier == "FloatingPane-\(p1Key)" && $0.role == "AXGroup" }
        #expect(paneMatches.count == 1, "FloatingPane-\(p1Key) AXGroup must appear exactly once; saw: \(summary)")
        let paneGroup = try #require(
            paneMatches.first,
            "Expected FloatingPane-\(p1Key) AXGroup in live AX tree; saw: \(summary)"
        )
        #expect(paneGroup.value == "Idle")
        #expect(nodes.filter { $0.role == "AXTextArea" }.count == 1, "Terminal AXTextArea must not be duplicated")

        // NSView.accessibilityFrame() is in AppKit screen coords (bottom-left origin); convert back to window coords:
        let maxFrameInWindow = window.convertFromScreen(paneGroup.frameInScreen)
        #expect(abs(maxFrameInWindow.minX - sidebarWidth) <= 2)
        #expect(abs(maxFrameInWindow.minY - 0) <= 2)
        #expect(abs(maxFrameInWindow.width - 1000) <= 2)
        #expect(abs(maxFrameInWindow.height - 700) <= 2)

        // All interactive descendants inside the pane must remain individually reachable under paneGroup.
        var paneDescendants: [AXSnapshotNode] = []
        flattenAX(paneGroup, into: &paneDescendants)
        #expect(paneDescendants.contains { $0.identifier == "FloatingPaneHeader-\(p1Key)" && $0.role == "AXGroup" })
        #expect(paneDescendants.contains { $0.identifier == "FloatingPaneMinimize-\(p1Key)" && $0.role == "AXButton" })
        #expect(paneDescendants.contains { $0.identifier == "FloatingPaneMaximize-\(p1Key)" && $0.role == "AXButton" })
        #expect(paneDescendants.contains { $0.identifier == "FloatingPaneClose-\(p1Key)" && $0.role == "AXButton" })
        let maxTextArea = try #require(paneDescendants.first { $0.role == "AXTextArea" })
        #expect(abs(maxTextArea.frameInScreen.height - 674) <= 2)

        // Verify live AXValue update + .normal floating frame (including 26pt header) + resize handles + Z-order hit-testing.
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let targetNormal = CGRect(x: 40, y: 50, width: 420, height: 320)
        let overlapNormal = CGRect(x: 100, y: 80, width: 420, height: 320)
        controller.floatingCanvas.setInteractiveRect(targetNormal, for: p1.id, in: CGSize(width: 1000, height: 700))
        controller.floatingCanvas.commitInteractiveRect(for: p1.id, in: CGSize(width: 1000, height: 700))
        controller.floatingCanvas.setInteractiveRect(overlapNormal, for: p2.id, in: CGSize(width: 1000, height: 700))
        controller.floatingCanvas.commitInteractiveRect(for: p2.id, in: CGSize(width: 1000, height: 700))
        p1.crab.setStatus(.working, text: "compile")

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let updatedNodes = collectWindowHIServicesAX(matching: window)
        let updatedPane = try #require(updatedNodes.first { $0.identifier == "FloatingPane-\(p1Key)" && $0.role == "AXGroup" })
        #expect(updatedPane.value == "Working")
        let normalInWindow = window.convertFromScreen(updatedPane.frameInScreen)
        #expect(abs(normalInWindow.minX - (sidebarWidth + 40)) <= 2)
        #expect(abs(normalInWindow.maxY - (700 - 50)) <= 2)
        #expect(abs(normalInWindow.width - 420) <= 2)
        #expect(abs(normalInWindow.height - 320) <= 2)

        var updatedPaneDescendants: [AXSnapshotNode] = []
        flattenAX(updatedPane, into: &updatedPaneDescendants)
        #expect(updatedPaneDescendants.contains { $0.identifier == "FloatingPaneResize-bottomTrailing-\(p1Key)" })
        let normalTextArea = try #require(updatedPaneDescendants.first { $0.role == "AXTextArea" })
        #expect(abs(normalTextArea.frameInScreen.height - 294) <= 2)

        // Overlapping hit-test respects Z-order when bringing p1 vs p2 to front.
        let overlapPointInWindow = NSPoint(x: sidebarWidth + 220, y: 700 - 200)
        controller.activateFloatingPane(p2)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()
        let hitWhenP2Top = contentView.hitTest(overlapPointInWindow)
        #expect(hitWhenP2Top === p2 || hitWhenP2Top?.isDescendant(of: p2) == true)

        controller.activateFloatingPane(p1)
        p1.title = "AlphaPaneTitle"; p1.publishCurrentTitle()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()
        let hitWhenP1Top = contentView.hitTest(overlapPointInWindow)
        #expect(hitWhenP1Top === p1 || hitWhenP1Top?.isDescendant(of: p1) == true)
        #expect(window.title.contains("AlphaPaneTitle") && p1.pty === initialP1PTY)
        controller.activateFloatingPane(p2); p2.title = "BetaPaneTitle"; p2.publishCurrentTitle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(window.title.contains("BetaPaneTitle"))
    }

    @Test func sidebarWorkspaceHeaderExposesActiveInactiveAXValue() throws {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.addTab(scene.surface("s1", .idle), to: scene.main)
        scene.addTab(scene.surface("s2", .idle), to: scene.legal, ownWindow: true)
        scene.mountSidebar()
        scene.settle()
        let nodes = collectWindowHIServicesAX(matching: scene.sidebarWindow)
        let wsSummary = nodes.filter { !$0.identifier.isEmpty }
            .map { "\($0.role)#\"\($0.identifier)\" val=\($0.value ?? "nil")" }.joined(separator: " | ")
        let defaultHeader = try #require(nodes.first { $0.identifier == "SessionSidebarWorkspace-Default" && $0.role == "AXGroup" }, "\(wsSummary)")
        let legalHeader = try #require(nodes.first { $0.identifier == "SessionSidebarWorkspace-Legal" && $0.role == "AXGroup" }, "\(wsSummary)")
        #expect(nodes.filter { $0.identifier == "SessionSidebarWorkspace-Default" }.count == 1)
        #expect(defaultHeader.value == "active" && legalHeader.value == "inactive")
        #expect(defaultHeader.frameInScreen.width > 100 && defaultHeader.frameInScreen.height >= 24)
        scene.switchTo(scene.legal)
        let switched = collectWindowHIServicesAX(matching: scene.sidebarWindow)
        #expect(switched.first { $0.identifier == "SessionSidebarWorkspace-Default" }?.value == "inactive")
        #expect(switched.first { $0.identifier == "SessionSidebarWorkspace-Legal" }?.value == "active")
    }
}
