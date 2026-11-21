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
struct FloatingPaneAndSidebarAXTests {
    private struct AXSnapshotNode {
        let identifier: String
        let role: String
        let value: String?
        let label: String?
        let help: String?
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
        let hlp = proto?.accessibilityHelp()
        let frame = proto?.accessibilityFrame() ?? .zero

        var rawChildren: [Any] = proto?.accessibilityChildren() ?? []
        if rawChildren.isEmpty, let view = root as? NSView {
            rawChildren = NSAccessibility.unignoredChildren(from: view.subviews)
        }
        let kids = rawChildren.compactMap { snapshotAppKitAX($0 as AnyObject, depth: depth + 1) }
        return AXSnapshotNode(
            identifier: id, role: role, value: val, label: lbl, help: hlp, frameInScreen: frame, children: kids
        )
    }

    private func flattenAX(_ node: AXSnapshotNode, into out: inout [AXSnapshotNode]) {
        out.append(node)
        for child in node.children {
            flattenAX(child, into: &out)
        }
    }

    private func collectWindowAX(matching window: NSWindow) -> [AXSnapshotNode] {
        guard let contentView = window.contentView,
              let root = snapshotAppKitAX(contentView) else {
            return []
        }
        var all: [AXSnapshotNode] = []
        flattenAX(root, into: &all)
        return all
    }

    /// Creates a real `.fullSizeContentView` `TerminalWindow` matching `TerminalWindow.awakeFromNib()`
    /// so macOS imposes the real 28pt titlebar safe-area inset on any unguarded `NSHostingView`.
    /// The canvas of a window every test display holds unclamped (DesktopCanvasFixture).
    private var canvasWidth: CGFloat { DesktopCanvasFixture.windowWidth - SessionSidebarWidth.current() }

    private func makeFullSizeLoadedWindow(canvasWidth: CGFloat = 1000, height: CGFloat = 700) -> (TerminalController, TerminalWindow) {
        TerminalTestSupport.preventQuitting()
        let sidebarWidth = SessionSidebarWidth.current()
        let app = Tako.App()
        let controller = TerminalController(app)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: canvasWidth + sidebarWidth, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        controller.window = window
        window.windowController = controller
        controller.windowDidLoad()
        controller.showWindow(nil)
        window.setFrame(NSRect(x: 0, y: 80, width: canvasWidth + sidebarWidth, height: height), display: true)
        return (controller, window)
    }

    @Test func floatingPaneRootAXGroupHasZeroTitlebarSafeAreaGapInFullSizeWindow() throws {
        let sidebarWidth = SessionSidebarWidth.current()
        let (controller, window) = makeFullSizeLoadedWindow(canvasWidth: canvasWidth, height: 700)
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        DesktopCanvasFixture.expectUnclamped(window, width: DesktopCanvasFixture.windowWidth)

        let p1 = try #require(controller.focusedSurface)
        let initialP1PTY = p1.pty
        let p1Key = p1.id.uuidString.lowercased()
        let contentView = try #require(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        contentView.layoutSubtreeIfNeeded()

        let winHeight = contentView.bounds.height
        let nodes = collectWindowAX(matching: window)
        let summary = nodes
            .filter { !$0.identifier.isEmpty || $0.role == "AXTextArea" }
            .map { "\($0.role)#\"\($0.identifier)\" val=\($0.value ?? "nil") frame=\(window.convertFromScreen($0.frameInScreen))" }
            .joined(separator: " | ")

        let paneMatches = nodes.filter { $0.identifier == "FloatingPane-\(p1Key)" && $0.role == "AXGroup" }
        #expect(paneMatches.count == 1, "FloatingPane-\(p1Key) must appear once; saw: \(summary)")
        let paneGroup = try #require(paneMatches.first)
        #expect(paneGroup.value == "Idle")
        #expect(nodes.filter { $0.role == "AXTextArea" }.count == 1)

        // The maximized card sits 8 pt in from every edge, as tiles do -- not 28 pt down,
        // which a titlebar safe area would add.
        let gap = DesktopCanvasMetrics.paneGap
        let maxPaneInWindow = window.convertFromScreen(paneGroup.frameInScreen)
        #expect(abs(maxPaneInWindow.minX - (sidebarWidth + gap)) <= 2)
        #expect(abs(maxPaneInWindow.minY - gap) <= 2)
        #expect(abs(maxPaneInWindow.width - (canvasWidth - 2 * gap)) <= 2)
        #expect(abs(maxPaneInWindow.height - (winHeight - 2 * gap)) <= 2)

        var paneDescendants: [AXSnapshotNode] = []
        flattenAX(paneGroup, into: &paneDescendants)
        let headerNode = try #require(paneDescendants.first { $0.identifier == "FloatingPaneHeader-\(p1Key)" && $0.role == "AXGroup" })
        let headerInWindow = window.convertFromScreen(headerNode.frameInScreen)
        // Header must sit flush at the top edge of FloatingPane (zero 28pt nested NSHostingView safe-area gap!):
        let h = FloatingPaneGeometry.headerHeight
        #expect(abs(headerInWindow.maxY - maxPaneInWindow.maxY) <= 2,
                "Header top maxY (\(headerInWindow.maxY)) must match pane top maxY (\(maxPaneInWindow.maxY)) without 28pt safe-area gap; saw: \(summary)")
        #expect(abs(headerInWindow.height - h) <= 2)

        #expect(paneDescendants.contains { $0.identifier == "FloatingPaneMinimize-\(p1Key)" && $0.role == "AXButton" })
        #expect(paneDescendants.contains { $0.identifier == "FloatingPaneMaximize-\(p1Key)" && $0.role == "AXButton" })
        #expect(paneDescendants.contains { $0.identifier == "FloatingPaneClose-\(p1Key)" && $0.role == "AXButton" })
        let maxTextArea = try #require(paneDescendants.first { $0.role == "AXTextArea" })
        let maxTextInWindow = window.convertFromScreen(maxTextArea.frameInScreen)
        // The terminal sits in the card's margin: 2 pt under the header, 6 pt off the sides and bottom.
        let inset = FloatingPaneGeometry.bodyInsets
        #expect(abs(headerInWindow.minY - maxTextInWindow.maxY - inset.top) <= 2)
        #expect(abs((maxPaneInWindow.maxY - maxTextInWindow.maxY) - h - inset.top) <= 2)
        #expect(abs(maxTextInWindow.minY - maxPaneInWindow.minY - inset.bottom) <= 2)
        #expect(abs(maxTextInWindow.minX - maxPaneInWindow.minX - inset.left) <= 2)
        #expect(abs(maxTextInWindow.height - (winHeight - 2 * gap - h - inset.top - inset.bottom)) <= 2,
                "Maximized terminal height (\(maxTextInWindow.height)) must be the card less its header and margin, without losing 28pt to safe area")

        // Verify .normal mode near the top of the .fullSizeContentView window (y = 8 inside titlebar zone!) ALSO has zero safe-area gap:
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p2Key = p2.id.uuidString.lowercased()
        let canvasSize = CGSize(width: canvasWidth, height: winHeight)
        controller.floatingCanvas.setInteractiveRect(CGRect(x: 40, y: 8, width: 420, height: 320), for: p1.id, in: canvasSize)
        controller.floatingCanvas.commitInteractiveRect(for: p1.id, in: canvasSize)
        controller.floatingCanvas.setInteractiveRect(CGRect(x: 100, y: 80, width: 420, height: 320), for: p2.id, in: canvasSize)
        controller.floatingCanvas.commitInteractiveRect(for: p2.id, in: canvasSize)
        p1.crab.setStatus(.working, text: "compile")

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let updatedNodes = collectWindowAX(matching: window)
        let updatedPane = try #require(updatedNodes.first { $0.identifier == "FloatingPane-\(p1Key)" && $0.role == "AXGroup" })
        #expect(updatedPane.value == "Working")
        let normalPaneInWindow = window.convertFromScreen(updatedPane.frameInScreen)
        #expect(abs(normalPaneInWindow.height - 320) <= 2)

        var updatedDescendants: [AXSnapshotNode] = []
        flattenAX(updatedPane, into: &updatedDescendants)
        let normalHeader = try #require(updatedDescendants.first { $0.identifier == "FloatingPaneHeader-\(p1Key)" })
        let normalHeaderInWindow = window.convertFromScreen(normalHeader.frameInScreen)
        #expect(abs(normalHeaderInWindow.maxY - normalPaneInWindow.maxY) <= 2,
                "Normal pane near window top must not incur titlebar safe-area gap")
        let normalText = try #require(updatedDescendants.first { $0.role == "AXTextArea" })
        let normalTextInWindow = window.convertFromScreen(normalText.frameInScreen)
        #expect(abs((normalPaneInWindow.maxY - normalTextInWindow.maxY) - h - inset.top) <= 2)
        #expect(abs(normalTextInWindow.minY - normalPaneInWindow.minY - inset.bottom) <= 2)
        #expect(abs(normalText.frameInScreen.height - (320 - h - inset.top - inset.bottom)) <= 2)
        #expect(updatedDescendants.contains { $0.identifier == "FloatingPaneResize-bottomTrailing-\(p1Key)" })

        // Verify multi-pane sidebar exposes non-duplicated session-pane-<uuid> AXGroups with selected/unselected values:
        #expect(updatedNodes.filter { $0.identifier == "session-pane-\(p1Key)" }.count == 1)
        #expect(updatedNodes.filter { $0.identifier == "session-pane-\(p2Key)" }.count == 1)
        #expect(updatedNodes.first { $0.identifier == "session-pane-\(p2Key)" }?.value == "selected")
        #expect(updatedNodes.first { $0.identifier == "session-pane-\(p1Key)" }?.value == "unselected")

        // Title & PTY preservation + overlapping Z-order hitTest:
        let overlapPointInWindow = NSPoint(x: sidebarWidth + 220, y: winHeight - 200)
        controller.activateFloatingPane(p1)
        p1.title = "AlphaPaneTitle"; p1.publishCurrentTitle()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let hitP1 = contentView.hitTest(overlapPointInWindow)
        #expect(hitP1 === p1 || hitP1?.isDescendant(of: p1) == true)
        #expect(window.title.contains("AlphaPaneTitle") && p1.pty === initialP1PTY)
        let refocusedNodes = collectWindowAX(matching: window)
        #expect(refocusedNodes.first { $0.identifier == "session-pane-\(p1Key)" }?.value == "selected")
        #expect(refocusedNodes.first { $0.identifier == "session-pane-\(p2Key)" }?.value == "unselected")
    }

    @Test func sidebarWorkspaceAndSessionRowsExposeNativeSelectedUnselectedAXValuesWithoutDuplicateIDs() throws {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        let s1 = scene.surface("s1", .working)
        let s2 = scene.surface("s2", .idle)
        let s3 = scene.surface("s3", .done)
        let tab1 = scene.addTab(s1, to: scene.main)
        let tab2 = scene.addTab(s2, to: scene.main)
        let tab3 = scene.addTab(s3, to: scene.legal, ownWindow: true)
        Tako.CustomTabGroup.group(for: tab1.window).select(tab1.window)
        scene.mountSidebar()
        scene.settle()

        let row1Id = "session-tab-\(s1.id.uuidString.lowercased())"
        let row2Id = "session-tab-\(s2.id.uuidString.lowercased())"
        let row3Id = "session-tab-\(s3.id.uuidString.lowercased())"

        let nodes = collectWindowAX(matching: scene.sidebarWindow)
        let axSummary = nodes.filter { !$0.identifier.isEmpty }
            .map { "\($0.role)#\"\($0.identifier)\" val=\($0.value ?? "nil") help=\($0.help ?? "nil")" }
            .joined(separator: " | ")

        // Workspace headers: single IDs, native active/inactive values
        #expect(nodes.filter { $0.identifier == "SessionSidebarWorkspace-Default" }.count == 1)
        #expect(nodes.first { $0.identifier == "SessionSidebarWorkspace-Default" }?.value == "active")
        #expect(nodes.first { $0.identifier == "SessionSidebarWorkspace-Legal" }?.value == "inactive")

        // Session rows: single IDs (no duplicates!), native selected/unselected values, status dot hint, hittable subview ancestry
        let r1Matches = nodes.filter { $0.identifier == row1Id }
        let r2Matches = nodes.filter { $0.identifier == row2Id }
        let r3Matches = nodes.filter { $0.identifier == row3Id }
        #expect(r1Matches.count == 1, "Expected exactly 1 \(row1Id); saw: \(axSummary)")
        #expect(r2Matches.count == 1, "Expected exactly 1 \(row2Id); saw: \(axSummary)")
        #expect(r3Matches.count == 1, "Expected exactly 1 \(row3Id); saw: \(axSummary)")

        let r1 = try #require(r1Matches.first)
        let r2 = try #require(r2Matches.first)
        let r3 = try #require(r3Matches.first)
        #expect(r1.role == "AXGroup" && r1.value == "selected")
        #expect(r2.role == "AXGroup" && r2.value == "unselected")
        #expect(r3.role == "AXGroup" && r3.value == "unselected")
        #expect(r1.help?.hasPrefix("dot:#") == true)
        #expect(r1.frameInScreen.width > 120 && r1.frameInScreen.height >= 24)

        // Verify hitTest at row1 center lands inside the NSView owning session-tab-<id> (backing XCUIElement.isHittable):
        let r1InWin = scene.sidebarWindow.convertFromScreen(r1.frameInScreen)
        let hitView = try #require(scene.sidebarWindow.contentView?.hitTest(NSPoint(x: r1InWin.midX, y: r1InWin.midY)))
        var cursor: NSView? = hitView
        var foundRowContainer = false
        while let v = cursor {
            if v.accessibilityIdentifier() == row1Id { foundRowContainer = true; break }
            cursor = v.superview
        }
        #expect(foundRowContainer, "hitTest at \(row1Id) center must descend from the \(row1Id) AX container NSView")

        // Switching selected tab inside Default workspace updates native AXValue immediately:
        Tako.CustomTabGroup.group(for: tab1.window).select(tab2.window)
        scene.store.objectWillChange.send()
        scene.settle()
        let afterTabSwitch = collectWindowAX(matching: scene.sidebarWindow)
        #expect(afterTabSwitch.first { $0.identifier == row1Id }?.value == "unselected")
        #expect(afterTabSwitch.first { $0.identifier == row2Id }?.value == "selected")

        // Switching workspace to Legal updates both workspace headers and session row selected values:
        scene.switchTo(scene.legal)
        let afterWsSwitch = collectWindowAX(matching: scene.sidebarWindow)
        #expect(afterWsSwitch.first { $0.identifier == "SessionSidebarWorkspace-Default" }?.value == "inactive")
        #expect(afterWsSwitch.first { $0.identifier == "SessionSidebarWorkspace-Legal" }?.value == "active")
        _ = tab3
    }

    @Test func normalFloatingPaneAXHitTestingReachesHeaderControlsTerminalAndAllEightResizeHandles() throws {
        let (_, controller, window) = {
            let pair = makeFullSizeLoadedWindow(canvasWidth: canvasWidth, height: 700)
            return (SessionSidebarWidth.current(), pair.0, pair.1)
        }()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        DesktopCanvasFixture.expectUnclamped(window, width: DesktopCanvasFixture.windowWidth)

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p1Key = p1.id.uuidString.lowercased()
        let p2Key = p2.id.uuidString.lowercased()
        let contentView = try #require(window.contentView)
        let canvasSize = CGSize(width: canvasWidth, height: contentView.bounds.height)

        // Place p1 (focused) and p2 (background) non-overlapping so both Close buttons & handles are
        // visible: side by side with 24 pt around each, sized from the canvas. A fixed 490 pt offset
        // was clamped back over p1 on a narrower canvas, which then took p2's left handles' hits.
        let paneWidth = (canvasWidth - 3 * 24) / 2
        #expect(paneWidth >= FloatingPaneGeometry.minSize.width)
        controller.floatingCanvas.setInteractiveRect(CGRect(x: 24, y: 24, width: paneWidth, height: 320), for: p1.id, in: canvasSize)
        controller.floatingCanvas.commitInteractiveRect(for: p1.id, in: canvasSize)
        controller.floatingCanvas.setInteractiveRect(CGRect(x: 48 + paneWidth, y: 80, width: paneWidth, height: 320), for: p2.id, in: canvasSize)
        controller.floatingCanvas.commitInteractiveRect(for: p2.id, in: canvasSize)
        controller.activateFloatingPane(p1)

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let nodes = collectWindowAX(matching: window)
        // Full-pane generic FloatingPaneResize-<uuid> AXGroup must NOT exist or intercept AX hit-testing:
        #expect(!nodes.contains { $0.identifier == "FloatingPaneResize-\(p1Key)" })
        #expect(!nodes.contains { $0.identifier == "FloatingPaneResize-\(p2Key)" })

        func axHit(at node: AXSnapshotNode) -> (id: String, role: String) {
            let pt = NSPoint(x: node.frameInScreen.midX, y: node.frameInScreen.midY)
            let hit = window.accessibilityHitTest(pt) as? NSAccessibilityProtocol
            return (hit?.accessibilityIdentifier() ?? "", hit?.accessibilityRole()?.rawValue ?? "")
        }

        for key in [p1Key, p2Key] {
            for controlPrefix in ["FloatingPaneClose-", "FloatingPaneMaximize-", "FloatingPaneMinimize-"] {
                let btnId = "\(controlPrefix)\(key)"
                let btnNode = try #require(nodes.first { $0.identifier == btnId })
                let hit = axHit(at: btnNode)
                #expect(hit.id == btnId && hit.role == "AXButton",
                        "AX hit at \(btnId) center returned \(hit.role)#\"\(hit.id)\" instead of \(btnId)")
            }
            for edge in FloatingPaneResizeEdge.allCases {
                let handleId = "FloatingPaneResize-\(edge.rawValue)-\(key)"
                let handleNode = try #require(nodes.first { $0.identifier == handleId })
                let hit = axHit(at: handleNode)
                #expect(hit.id == handleId && hit.role == "AXHandle",
                        "AX hit at \(handleId) center returned \(hit.role)#\"\(hit.id)\" instead of \(handleId)")
            }
        }

        // Terminal center AX hit-testing on both focused and background panes must reach AXTextArea:
        for key in [p1Key, p2Key] {
            let paneNode = try #require(nodes.first { $0.identifier == "FloatingPane-\(key)" && $0.role == "AXGroup" })
            var kids: [AXSnapshotNode] = []
            flattenAX(paneNode, into: &kids)
            let textNode = try #require(kids.first { $0.role == "AXTextArea" })
            #expect(axHit(at: textNode).role == "AXTextArea")
        }

        // Verify corner handle screen coordinates match physical pane corners (topLeading vs bottomTrailing):
        let p1PaneInWin = window.convertFromScreen(
            try #require(nodes.first { $0.identifier == "FloatingPane-\(p1Key)" && $0.role == "AXGroup" }).frameInScreen
        )
        let tlInWin = window.convertFromScreen(
            try #require(nodes.first { $0.identifier == "FloatingPaneResize-topLeading-\(p1Key)" }).frameInScreen
        )
        let brInWin = window.convertFromScreen(
            try #require(nodes.first { $0.identifier == "FloatingPaneResize-bottomTrailing-\(p1Key)" }).frameInScreen
        )
        #expect(abs(tlInWin.minX - p1PaneInWin.minX) <= 2 && abs(tlInWin.maxY - p1PaneInWin.maxY) <= 2)
        #expect(abs(brInWin.maxX - p1PaneInWin.maxX) <= 2 && abs(brInWin.minY - p1PaneInWin.minY) <= 2)

        // Direct perimeter view check: both pointer hitTest and accessibilityHitTest return nil outside the 8 handle strips:
        func collectPerimeters(_ v: NSView, into out: inout [FloatingPaneResizePerimeterNSView]) {
            if let p = v as? FloatingPaneResizePerimeterNSView { out.append(p) }
            for sub in v.subviews { collectPerimeters(sub, into: &out) }
        }
        var perimeters: [FloatingPaneResizePerimeterNSView] = []
        collectPerimeters(contentView, into: &perimeters)
        #expect(perimeters.count == 2)
        for perimeter in perimeters {
            #expect(!perimeter.isAccessibilityElement())
            for btnId in ["FloatingPaneClose-\(p1Key)", "FloatingPaneClose-\(p2Key)"] {
                let btn = try #require(nodes.first { $0.identifier == btnId })
                let screenCenter = NSPoint(x: btn.frameInScreen.midX, y: btn.frameInScreen.midY)
                #expect(perimeter.accessibilityHitTest(screenCenter) == nil)
            }
        }
    }
}
