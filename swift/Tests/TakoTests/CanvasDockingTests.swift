/*
 * tako — Canvas docking targets and persistent terminal identity
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@MainActor @Suite(.serialized)
struct CanvasDockingTests {
    @Test func edgeAndCellTargetsRespectMinimumSizeAndIgnoreCenter() throws {
        let id = UUID(), area = CGRect(x: 8, y: 8, width: 1000, height: 700)
        let frames = [id: area]
        let top = try #require(CanvasDropTarget.pick(at: CGPoint(x: 500, y: 10), frames: frames, area: area))
        #expect(top.anchor == nil && top.side == .top)
        #expect(top.frame.height == 346)
        let right = try #require(CanvasDropTarget.pick(at: CGPoint(x: 850, y: 350), frames: frames, area: area))
        #expect(right.anchor == id && right.side == .right)
        #expect(CanvasDropTarget.pick(at: CGPoint(x: 500, y: 350), frames: frames, area: area) == nil)
        #expect(CanvasDropTarget.pick(at: CGPoint(x: -1, y: 10), frames: frames, area: area) == nil)
        let small = CGRect(x: 0, y: 0, width: 400, height: 200)
        #expect(CanvasDropTarget.pick(at: CGPoint(x: 2, y: 100), frames: [id: small], area: small) == nil)
    }

    @Test func dockingReordersTheLiveTreeWithoutReplacingSurfaceOrPTY() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)
        let first = try #require(controller.focusedSurface)
        let second = try #require(controller.newSplit(at: first, direction: .right))
        let firstPTY = first.pty, secondPTY = second.pty
        controller.togglePaneFloating(second)
        let target = CanvasDropTarget(anchor: first.id, side: .left, frame: .zero)
        #expect(controller.dockCanvasPane(second, at: target))
        #expect(controller.surfaceTree.first === second)
        #expect(controller.floatingCanvas.isTiled(second.id))
        #expect(first.pty === firstPTY && second.pty === secondPTY)
        #expect(Set(controller.surfaceTree.map(\.id)) == Set([first.id, second.id]))
        #expect(controller.focusedSurface === second)
        #expect(controller.floatingCanvas.dropTarget == nil)
    }
}
