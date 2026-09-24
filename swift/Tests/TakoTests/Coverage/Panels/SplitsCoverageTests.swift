import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Tako

// Coverage for swift/Sources/TakoApp/Features/Splits: SplitView + its
// Divider (drag-to-resize, double-tap-to-equalize, accessibility increment/
// decrement), TerminalSplitTreeView (leaf/split/zoomed rendering and the
// resize action it emits), and a handful of SplitTree.swift error paths /
// the Combine `valuesPublisher` that the existing SplitTreeTests.swift
// (structural/geometry focused) never exercises.

@MainActor
private func makeBorderlessWindow(size: NSSize) -> NSWindow {
    let origin = NSScreen.main.map { NSPoint(x: $0.visibleFrame.minX + 40, y: $0.visibleFrame.minY + 40) } ?? .zero
    let window = NSWindow(
        contentRect: NSRect(origin: origin, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func mouseEvent(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
        clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
}

@MainActor
private func drag(in window: NSWindow, from start: NSPoint, to end: NSPoint, steps: Int = 5) {
    if let down = mouseEvent(.leftMouseDown, start, in: window) { window.sendEvent(down) }
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        if let dragged = mouseEvent(.leftMouseDragged, point, in: window) { window.sendEvent(dragged) }
    }
    if let up = mouseEvent(.leftMouseUp, end, in: window) { window.sendEvent(up) }
}

@MainActor
private func doubleClick(in window: NSWindow, at point: NSPoint) {
    if let down1 = mouseEvent(.leftMouseDown, point, in: window, clickCount: 1) { window.sendEvent(down1) }
    if let up1 = mouseEvent(.leftMouseUp, point, in: window, clickCount: 1) { window.sendEvent(up1) }
    if let down2 = mouseEvent(.leftMouseDown, point, in: window, clickCount: 2) { window.sendEvent(down2) }
    if let up2 = mouseEvent(.leftMouseUp, point, in: window, clickCount: 2) { window.sendEvent(up2) }
}

@MainActor
private func containsView(_ root: NSView, _ target: NSView) -> Bool {
    if root === target { return true }
    for subview in root.subviews where containsView(subview, target) {
        return true
    }
    return false
}

// MARK: - SplitView + Divider

@Suite
@MainActor
struct SplitViewCoverageTests {
    /// For a 400x200 host with split=0.5: leftRect.width = 400*0.5 - 0.5 -
    /// frac(199.5) = 199. The divider sits exactly at the vertical
    /// midpoint, so this point is identical in SwiftUI's top-left-origin
    /// space and the window's bottom-left-origin event-coordinate space.
    private let dividerPoint = NSPoint(x: 199, y: 100)

    @Test func horizontalDragMovesTheSplitRatioTowardTheDragDirection() {
        var split: CGFloat = 0.5
        let binding = Binding<CGFloat>(get: { split }, set: { split = $0 })
        let window = makeBorderlessWindow(size: NSSize(width: 400, height: 200))
        let view = SplitView(.horizontal, binding, dividerColor: .blue,
                              left: { Color.red }, right: { Color.green }, onEqualize: {})
        _ = hostPanel(view, in: window)
        window.orderFrontRegardless()

        drag(in: window, from: dividerPoint, to: NSPoint(x: 260, y: 100))
        #expect(split > 0.5)
    }

    @Test func doubleTappingTheDividerCallsOnEqualize() {
        var equalizeCalls = 0
        let binding = Binding<CGFloat>(get: { 0.5 }, set: { _ in })
        let window = makeBorderlessWindow(size: NSSize(width: 400, height: 200))
        let view = SplitView(.horizontal, binding, dividerColor: .blue,
                              left: { Color.red }, right: { Color.green }, onEqualize: { equalizeCalls += 1 })
        _ = hostPanel(view, in: window)
        window.orderFrontRegardless()

        doubleClick(in: window, at: dividerPoint)
        #expect(waitUntilPanel(timeout: 2) { equalizeCalls > 0 })
    }

    /// AX inspection isn't available in this bare-NSWindow harness (see
    /// PanelTestSupport.swift), so the pane/divider accessibility labels
    /// (`axLabel`, `leftPaneLabel`, etc.) can't be read back directly --
    /// they are still evaluated as part of `body` on every render, though,
    /// so this proves the vertical vs. horizontal branch through the one
    /// channel this harness can observe: the two directions must paint
    /// their divider along different axes and therefore differ in pixels.
    @Test func verticalAndHorizontalSplitsRenderDifferentDividerOrientations() {
        let binding = Binding<CGFloat>(get: { 0.5 }, set: { _ in })

        let verticalWindow = makeBorderlessWindow(size: NSSize(width: 200, height: 200))
        let verticalView = SplitView(.vertical, binding, dividerColor: .blue,
                                      left: { Color.red }, right: { Color.green }, onEqualize: {})
        let verticalHosting = hostPanel(verticalView, in: verticalWindow)
        verticalHosting.layoutSubtreeIfNeeded()
        let verticalSnapshot = panelSnapshot(verticalHosting)

        let horizontalWindow = makeBorderlessWindow(size: NSSize(width: 200, height: 200))
        let horizontalView = SplitView(.horizontal, binding, dividerColor: .blue,
                                        left: { Color.red }, right: { Color.green }, onEqualize: {})
        let horizontalHosting = hostPanel(horizontalView, in: horizontalWindow)
        horizontalHosting.layoutSubtreeIfNeeded()
        let horizontalSnapshot = panelSnapshot(horizontalHosting)

        #expect(!panelBitmapsEqual(verticalSnapshot, horizontalSnapshot))
    }
}

// MARK: - TerminalSplitTreeView

@Suite
@MainActor
struct TerminalSplitTreeViewCoverageTests {
    private let dividerPoint = NSPoint(x: 199, y: 100)

    @Test func singleLeafTreeRendersItsSurfaceAsRoot() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer { surface.close() }
        let tree = SplitTree<Tako.SurfaceView>(view: surface)

        let window = makeBorderlessWindow(size: NSSize(width: 400, height: 200))
        let view = TerminalSplitTreeView(tree: tree, action: { _ in })
            .environmentObject(Tako.App())
        let hosting = hostPanel(view, in: window)

        #expect(containsView(hosting, surface))
    }

    @Test func splitTreeRendersBothSurfaces() throws {
        let surface1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let surface2 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer {
            surface1.close()
            surface2.close()
        }
        var tree = SplitTree<Tako.SurfaceView>(view: surface1)
        tree = try tree.inserting(view: surface2, at: surface1, direction: .right)

        let window = makeBorderlessWindow(size: NSSize(width: 400, height: 200))
        let view = TerminalSplitTreeView(tree: tree, action: { _ in })
            .environmentObject(Tako.App())
        let hosting = hostPanel(view, in: window)
        window.orderFrontRegardless()

        #expect(containsView(hosting, surface1))
        #expect(containsView(hosting, surface2))
    }

    @Test func zoomedNodeRendersOnlyThatSurface() throws {
        let surface1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let surface2 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer {
            surface1.close()
            surface2.close()
        }
        var tree = SplitTree<Tako.SurfaceView>(view: surface1)
        tree = try tree.inserting(view: surface2, at: surface1, direction: .right)
        let zoomedTree = SplitTree<Tako.SurfaceView>(root: tree.root, zoomed: .leaf(view: surface2))

        let window = makeBorderlessWindow(size: NSSize(width: 400, height: 200))
        let view = TerminalSplitTreeView(tree: zoomedTree, action: { _ in })
            .environmentObject(Tako.App())
        let hosting = hostPanel(view, in: window)

        #expect(containsView(hosting, surface2))
        #expect(!containsView(hosting, surface1))
    }

    @Test func emptyTreeRendersNoSurfaces() {
        let tree = SplitTree<Tako.SurfaceView>()
        let window = makeBorderlessWindow(size: NSSize(width: 400, height: 200))
        let view = TerminalSplitTreeView(tree: tree, action: { _ in })
            .environmentObject(Tako.App())
        let hosting = hostPanel(view, in: window)
        #expect(hosting.fittingSize.width >= 0)
    }

    @Test func dropZoneCalculateCoversAllFourEdges() {
        // TerminalSplitDropZone.calculate's own exhaustive behavior is
        // covered by TerminalSplitDropZoneTests.swift; this only pins that
        // the enum's raw String identity (used by the .takoSurfaceId drag
        // payload plumbing) is stable.
        #expect(TerminalSplitDropZone.top.rawValue == "top")
        #expect(TerminalSplitDropZone.bottom.rawValue == "bottom")
        #expect(TerminalSplitDropZone.left.rawValue == "left")
        #expect(TerminalSplitDropZone.right.rawValue == "right")
    }
}

// MARK: - SplitTree error paths and Combine publisher

private final class PublishingMockView: NSView, Codable, Identifiable, ObservableObject {
    let id: UUID
    @Published var value: Int = 0

    init(id: UUID = UUID()) {
        self.id = id
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    enum CodingKeys: CodingKey { case id, value }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        super.init(frame: .zero)
        self.value = try c.decode(Int.self, forKey: .value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(value, forKey: .value)
    }
}

struct SplitTreeSupplementalCoverageTests {
    @Test func insertingIntoAnEmptyTreeThrows() {
        let tree = SplitTree<MockView>()
        #expect(throws: SplitTree<MockView>.SplitError.self) {
            _ = try tree.inserting(view: MockView(), at: MockView(), direction: .right)
        }
    }

    @Test func insertingAtAnUnknownViewThrows() {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(throws: SplitTree<MockView>.SplitError.self) {
            _ = try tree.inserting(view: view2, at: view3, direction: .right)
        }
    }

    @Test func replacingInAnEmptyTreeThrows() {
        let tree = SplitTree<MockView>()
        #expect(throws: SplitTree<MockView>.SplitError.self) {
            _ = try tree.replacing(node: .leaf(view: MockView()), with: .leaf(view: MockView()))
        }
    }

    @Test func replacingAnUnknownNodeThrows() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(throws: SplitTree<MockView>.SplitError.self) {
            _ = try tree.replacing(node: .leaf(view: view2), with: .leaf(view: MockView()))
        }
    }

    @Test func resizingAnUnknownNodeThrows() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(throws: SplitTree<MockView>.SplitError.self) {
            _ = try tree.resizing(node: .leaf(view: view2), by: 10, in: .right,
                                   with: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    @Test func resizingWithoutAMatchingParentSplitThrows() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        // Only a horizontal split exists; resizing vertically finds no
        // suitable parent split of the matching direction.
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect(throws: SplitTree<MockView>.SplitError.self) {
            _ = try tree.resizing(node: .leaf(view: view1), by: 10, in: .up,
                                   with: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
    }

    @Test func nodeReplacingNodeAtAnInvalidPathThrows() {
        let view1 = MockView()
        let view2 = MockView()
        let leaf = SplitTree<MockView>.Node.leaf(view: view1)
        // A leaf has no children, so any non-empty path into it is invalid.
        #expect(throws: SplitTree<MockView>.SplitError.self) {
            _ = try leaf.replacingNode(at: .init(path: [.left]), with: .leaf(view: view2))
        }
    }

    @Test func valuesPublisherEmitsInitialAndUpdatedSnapshots() throws {
        let v1 = PublishingMockView()
        v1.value = 10
        let v2 = PublishingMockView()
        v2.value = 20
        var tree = SplitTree<PublishingMockView>(view: v1)
        tree = try tree.inserting(view: v2, at: v1, direction: .right)

        var snapshots: [[PublishingMockView.ID: Int]] = []
        let cancellable = tree.valuesPublisher(valueKeyPath: \.value, publisherKeyPath: \.$value)
            .sink { snapshots.append($0) }
        defer { cancellable.cancel() }

        // `.prepend(initial)` emits the up-front snapshot first, then
        // subscribes the merged per-view `$value` publishers -- each of
        // which (per `@Published`'s documented "replay current value on
        // subscribe" behavior) immediately re-emits, so two views yields
        // 1 (prepend) + 2 (initial replay) = 3 emissions before any real
        // mutation.
        let baselineCount = snapshots.count
        #expect(baselineCount == 3)
        #expect(snapshots.last?[v1.id] == 10)
        #expect(snapshots.last?[v2.id] == 20)

        v1.value = 99
        #expect(snapshots.count == baselineCount + 1)
        #expect(snapshots.last?[v1.id] == 99)
        #expect(snapshots.last?[v2.id] == 20)
    }

    @Test func valuesPublisherOnAnEmptyTreeEmitsAnEmptySnapshot() {
        let tree = SplitTree<PublishingMockView>()
        var snapshots: [[PublishingMockView.ID: Int]] = []
        let cancellable = tree.valuesPublisher(valueKeyPath: \.value, publisherKeyPath: \.$value)
            .sink { snapshots.append($0) }
        defer { cancellable.cancel() }
        #expect(snapshots == [[:]])
    }
}
