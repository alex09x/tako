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
import QuartzCore
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct FloatingCanvasMotionTests {
    private func findView(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for sub in root.subviews {
            if let found = findView(identifier: identifier, in: sub) { return found }
        }
        return nil
    }

    private func collectViews<T: NSView>(of type: T.Type, in root: NSView, into out: inout [T]) {
        if let match = root as? T { out.append(match) }
        for sub in root.subviews {
            collectViews(of: type, in: sub, into: &out)
        }
    }

    private func makeLoadedDesktopWindow(
        canvasWidth: CGFloat = 1000,
        height: CGFloat = 700
    ) -> (TerminalController, TerminalWindow) {
        TerminalTestSupport.preventQuitting()
        let app = Tako.App()
        let sidebarWidth = SessionSidebarWidth.current()
        let controller = TerminalController(app)
        let window = TerminalWindow(
            contentRect: NSRect(x: 80, y: 80, width: canvasWidth + sidebarWidth, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        controller.window = window
        window.awakeFromNib()
        controller.windowDidLoad()
        window.setFrame(NSRect(x: 80, y: 80, width: canvasWidth + sidebarWidth, height: height), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    private func transformEndpoints(from groupAnim: CAAnimation?) -> (from: CATransform3D, to: CATransform3D)? {
        guard let group = groupAnim as? CAAnimationGroup,
              let transformAnim = group.animations?.compactMap({ $0 as? CABasicAnimation })
                .first(where: { $0.keyPath == "transform" }),
              let fromValue = transformAnim.fromValue as? NSValue,
              let toValue = transformAnim.toValue as? NSValue
        else { return nil }
        return (fromValue.caTransform3DValue, toValue.caTransform3DValue)
    }

    /// Evaluates the actual QuartzCore bounding rect of `view.layer` inside `contentView` (top-down canvas coordinates)
    /// when `view.layer.transform` is temporarily set to `transform`.
    private func liveCanvasRect(
        of view: NSView,
        withTransform transform: CATransform3D,
        in contentView: NSView,
        sidebarWidth: CGFloat
    ) throws -> CGRect {
        let layer = try #require(view.layer)
        let contentLayer = try #require(contentView.layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let prev = layer.transform
        layer.transform = transform
        let c00 = layer.convert(CGPoint(x: 0, y: 0), to: contentLayer)
        let c10 = layer.convert(CGPoint(x: layer.bounds.width, y: 0), to: contentLayer)
        let c01 = layer.convert(CGPoint(x: 0, y: layer.bounds.height), to: contentLayer)
        let c11 = layer.convert(CGPoint(x: layer.bounds.width, y: layer.bounds.height), to: contentLayer)
        layer.transform = prev
        CATransaction.commit()

        let xs = [c00.x, c10.x, c01.x, c11.x]
        let ys = [c00.y, c10.y, c01.y, c11.y]
        let minX = (xs.min() ?? 0) - sidebarWidth
        let maxX = (xs.max() ?? 0) - sidebarWidth
        let minYLayer = ys.min() ?? 0
        let maxYLayer = ys.max() ?? 0
        let topDownMinY = contentLayer.isGeometryFlipped
            ? minYLayer
            : (contentView.bounds.height - maxYLayer)
        return CGRect(x: minX, y: topDownMinY, width: maxX - minX, height: maxYLayer - minYLayer)
    }

    @Test func initialLayerTransformMapsAllFourCornersWithoutRatioClamping() {
        let cases: [(name: String, from: CGRect, to: CGRect)] = [
            // Maximized 1000x700 -> saved minSize normal 260x150 (sx = 3.84615, sy = 4.66667 > 2.5)
            ("maxToMinNormal", CGRect(x: 0, y: 0, width: 1000, height: 700), CGRect(x: 48, y: 52, width: 260, height: 150)),
            // Shelf pill 168x30 -> fullscreen 1600x940 (sy = 0.031915 < 0.05)
            ("shelfToFullscreen", CGRect(x: 1420, y: 903, width: 168, height: 30), CGRect(x: 0, y: 0, width: 1600, height: 940)),
            // Wide -> tall
            ("wideToTall", CGRect(x: 30, y: 210, width: 1200, height: 240), CGRect(x: 410, y: 40, width: 300, height: 640)),
            // Tall -> wide
            ("tallToWide", CGRect(x: 610, y: 20, width: 280, height: 860), CGRect(x: 80, y: 380, width: 920, height: 220))
        ]
        let anchors = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5)]

        for scenario in cases {
            for flipped in [false, true] {
                for anchor in anchors {
                    let t = FloatingCanvasMotion.initialLayerTransform(
                        from: scenario.from,
                        to: scenario.to,
                        anchorPoint: anchor,
                        superviewIsFlipped: flipped
                    )
                    // In flipped superlayer: (u=0,v=0) is top-left, (u=1,v=1) is bottom-right.
                    // In unflipped superlayer: (u=0,v=1) is top-left, (u=1,v=0) is bottom-right.
                    let topLeft = FloatingCanvasMotion.transformedCanvasCorner(
                        u: 0, v: flipped ? 0 : 1,
                        settledCanvasRect: scenario.to, transform: t,
                        anchorPoint: anchor, superviewIsFlipped: flipped, canvasHeight: 1200
                    )
                    let topRight = FloatingCanvasMotion.transformedCanvasCorner(
                        u: 1, v: flipped ? 0 : 1,
                        settledCanvasRect: scenario.to, transform: t,
                        anchorPoint: anchor, superviewIsFlipped: flipped, canvasHeight: 1200
                    )
                    let bottomLeft = FloatingCanvasMotion.transformedCanvasCorner(
                        u: 0, v: flipped ? 1 : 0,
                        settledCanvasRect: scenario.to, transform: t,
                        anchorPoint: anchor, superviewIsFlipped: flipped, canvasHeight: 1200
                    )
                    let bottomRight = FloatingCanvasMotion.transformedCanvasCorner(
                        u: 1, v: flipped ? 1 : 0,
                        settledCanvasRect: scenario.to, transform: t,
                        anchorPoint: anchor, superviewIsFlipped: flipped, canvasHeight: 1200
                    )

                    #expect(abs(topLeft.x - scenario.from.minX) < 1e-5 && abs(topLeft.y - scenario.from.minY) < 1e-5,
                            "\(scenario.name) flipped=\(flipped) anchor=\(anchor) topLeft=\(topLeft) != \(scenario.from.origin)")
                    #expect(abs(topRight.x - scenario.from.maxX) < 1e-5 && abs(topRight.y - scenario.from.minY) < 1e-5)
                    #expect(abs(bottomLeft.x - scenario.from.minX) < 1e-5 && abs(bottomLeft.y - scenario.from.maxY) < 1e-5)
                    #expect(abs(bottomRight.x - scenario.from.maxX) < 1e-5 && abs(bottomRight.y - scenario.from.maxY) < 1e-5)
                }
            }
        }

        // Degenerate zero/negative/NaN rects safely return identity
        let invalid = FloatingCanvasMotion.initialLayerTransform(
            from: CGRect(x: 0, y: 0, width: 0, height: 300),
            to: CGRect(x: 0, y: 0, width: 400, height: 300),
            anchorPoint: .zero,
            superviewIsFlipped: true
        )
        #expect(CATransform3DIsIdentity(invalid))
    }

    @Test func sequentialMinimizeReplacesGhostIdentityFromSecondPaneRectAndFreshRestoreStartsAtShelf() throws {
        let sidebarWidth = SessionSidebarWidth.current()
        let (controller, window) = makeLoadedDesktopWindow(canvasWidth: 1000, height: 700)
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.makeKeyAndOrderFront(nil)

        let store = controller.floatingCanvas
        store.reduceMotionProvider = { false }
        let contentView = try #require(window.contentView)
        contentView.wantsLayer = true
        let canvas = CGSize(width: 1000, height: contentView.bounds.height)
        store.lastValidCanvasSize = canvas

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p3 = try #require(controller.newSplit(at: p2, direction: .down))

        let rect2 = CGRect(x: 40, y: 52, width: 420, height: 300)
        let rect3 = CGRect(x: 510, y: 130, width: 390, height: 270)
        store.setInteractiveRect(rect2, for: p2.id, in: canvas)
        store.commitInteractiveRect(for: p2.id, in: canvas)
        store.setInteractiveRect(rect3, for: p3.id, in: canvas)
        store.commitInteractiveRect(for: p3.id, in: canvas)

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        contentView.layoutSubtreeIfNeeded()

        // 1. Minimize p2 (genA): mounts GhostView A at unstretched rect2 (Identity -> shelfA)
        controller.minimizeFloatingPane(p2)
        let genA = try #require(store.activeTransition?.generation)
        let expectedShelfA = FloatingCanvasMotion.shelfAnchorRect(in: canvas, minimizedCount: 1)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()

        var ghostsAfterA: [FloatingPaneGhostNSView] = []
        collectViews(of: FloatingPaneGhostNSView.self, in: contentView, into: &ghostsAfterA)
        #expect(ghostsAfterA.count == 1)
        let ghostA = try #require(ghostsAfterA.first)
        #expect(ghostA.generation == genA && ghostA.surfaceId == p2.id)
        #expect(ghostA.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(ghostA.bounds.size == rect2.size)
        #expect(ghostA.cardCornerRadius == FloatingPaneGeometry.cornerRadius)
        #expect(ghostA.headerHeightUsed == FloatingPaneGeometry.headerHeight)
        // The dot is centred in the 28 pt reference header (was 32 before the canvas port).
        let dotY = (FloatingPaneGeometry.headerHeight - 7) / 2
        #expect(ghostA.dotFrame == CGRect(x: 14, y: dotY, width: 7, height: 7))
        #expect(ghostA.titleFontSize == 11)

        let ghostAAnim = try #require(transformEndpoints(from: ghostA.layer?.animation(forKey: FloatingCanvasMotion.ghostAnimationKey)))
        #expect(CATransform3DIsIdentity(ghostAAnim.from), "Outgoing ghost must start at CATransform3DIdentity so glyphs/dot are never stretched")
        let ghostALiveStartRect = try liveCanvasRect(
            of: ghostA, withTransform: ghostAAnim.from, in: contentView, sidebarWidth: sidebarWidth
        )
        #expect(abs(ghostALiveStartRect.minX - rect2.minX) <= 2 && abs(ghostALiveStartRect.minY - rect2.minY) <= 2)
        #expect(abs(ghostALiveStartRect.width - rect2.width) <= 2 && abs(ghostALiveStartRect.height - rect2.height) <= 2)
        let ghostALiveEndRect = try liveCanvasRect(
            of: ghostA, withTransform: ghostAAnim.to, in: contentView, sidebarWidth: sidebarWidth
        )
        #expect(abs(ghostALiveEndRect.minX - expectedShelfA.minX) <= 2 && abs(ghostALiveEndRect.minY - expectedShelfA.minY) <= 2)
        #expect(abs(ghostALiveEndRect.width - expectedShelfA.width) <= 2 && abs(ghostALiveEndRect.height - expectedShelfA.height) <= 2)

        // 2. Immediately minimize p3 (genB > genA) while ghostA is still active:
        //    ghostA must tear down immediately and a brand-new ghostB must mount at unstretched rect3 (Identity -> shelfB)
        controller.minimizeFloatingPane(p3)
        let genB = try #require(store.activeTransition?.generation)
        let expectedShelfB = FloatingCanvasMotion.shelfAnchorRect(in: canvas, minimizedCount: 2)
        #expect(genB > genA)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()

        #expect(ghostA.window == nil, "Previous generation's ghost view must unmount immediately when a newer minimize starts")
        var ghostsAfterB: [FloatingPaneGhostNSView] = []
        collectViews(of: FloatingPaneGhostNSView.self, in: contentView, into: &ghostsAfterB)
        #expect(ghostsAfterB.count == 1)
        let ghostB = try #require(ghostsAfterB.first)
        #expect(ghostB !== ghostA)
        #expect(ghostB.generation == genB && ghostB.surfaceId == p3.id)
        #expect(ghostB.bounds.size == rect3.size)
        #expect(ghostB.cardCornerRadius == FloatingPaneGeometry.cornerRadius)
        #expect(ghostB.dotFrame == CGRect(x: 14, y: dotY, width: 7, height: 7))
        #expect(ghostB.titleFontSize == 11)

        let ghostBAnim = try #require(transformEndpoints(from: ghostB.layer?.animation(forKey: FloatingCanvasMotion.ghostAnimationKey)))
        #expect(CATransform3DIsIdentity(ghostBAnim.from))
        let ghostBLiveStartRect = try liveCanvasRect(
            of: ghostB, withTransform: ghostBAnim.from, in: contentView, sidebarWidth: sidebarWidth
        )
        #expect(abs(ghostBLiveStartRect.minX - rect3.minX) <= 2 && abs(ghostBLiveStartRect.minY - rect3.minY) <= 2,
                "Second sequential minimize ghost must start at p3's rect3 (\(rect3)), got \(ghostBLiveStartRect)")
        #expect(abs(ghostBLiveStartRect.width - rect3.width) <= 2 && abs(ghostBLiveStartRect.height - rect3.height) <= 2)
        let ghostBLiveEndRect = try liveCanvasRect(
            of: ghostB, withTransform: ghostBAnim.to, in: contentView, sidebarWidth: sidebarWidth
        )
        #expect(abs(ghostBLiveEndRect.minX - expectedShelfB.minX) <= 2 && abs(ghostBLiveEndRect.minY - expectedShelfB.minY) <= 2)
        #expect(abs(ghostBLiveEndRect.width - expectedShelfB.width) <= 2 && abs(ghostBLiveEndRect.height - expectedShelfB.height) <= 2)

        // 3. Fresh NSView restore of p3 from minimized shelf:
        //    verifies post-attach morph starts at the bottom-right shelf anchor (right orientation & timing)
        controller.revealAndFocusFloatingPane(p3, in: canvas)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()

        var ghostsAfterRestore: [FloatingPaneGhostNSView] = []
        collectViews(of: FloatingPaneGhostNSView.self, in: contentView, into: &ghostsAfterRestore)
        #expect(ghostsAfterRestore.isEmpty)

        let p3Key = p3.id.uuidString.lowercased()
        let p3Container = try #require(findView(identifier: "FloatingPane-\(p3Key)", in: contentView))
        #expect(p3Container.window === window && p3Container.bounds.size == rect3.size)
        let restoreAnim = try #require(transformEndpoints(from: p3Container.layer?.animation(forKey: FloatingCanvasMotion.layerAnimationKey)))
        #expect(CATransform3DIsIdentity(restoreAnim.to))
        let restoreLiveStartRect = try liveCanvasRect(
            of: p3Container, withTransform: restoreAnim.from, in: contentView, sidebarWidth: sidebarWidth
        )
        #expect(abs(restoreLiveStartRect.minX - expectedShelfB.minX) <= 2 && abs(restoreLiveStartRect.minY - expectedShelfB.minY) <= 2,
                "Freshly restored NSView must start morphing from bottom-right shelf anchor (\(expectedShelfB)), got \(restoreLiveStartRect)")
        #expect(abs(restoreLiveStartRect.width - expectedShelfB.width) <= 2 && abs(restoreLiveStartRect.height - expectedShelfB.height) <= 2)
    }
}
