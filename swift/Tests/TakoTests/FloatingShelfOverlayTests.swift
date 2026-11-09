/*
 * tako — A minimize shelf overlays the field without reserving terminal height
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
struct FloatingShelfOverlayTests {
    @Test func shelfDoesNotReduceTerminalHeightAndGridStillReflowsWhenATileIsMinimized() async throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1280, height: 700))
        controller.showWindow(nil)
        let a = try #require(controller.focusedSurface)
        let b = try #require(controller.newSplit(at: a, direction: .right))
        controller.floatingCanvas.reduceMotionProvider = { true }
        let content = try #require(window.contentView)
        func settle() async {
            content.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(80))
            content.layoutSubtreeIfNeeded()
        }
        await settle()
        let canvas = controller.floatingCanvas.effectiveCanvasSize()
        let tile = controller.floatingCanvas.presentedFrame(of: a.id, in: canvas)
        let bounds = a.bounds.size, rows = a.rows, cols = a.cols
        let ptyA = a.pty, ptyB = b.pty
        controller.minimizeFloatingPane(b)
        await settle()
        let expanded = controller.floatingCanvas.presentedFrame(of: a.id, in: canvas)
        #expect(expanded.height == tile.height && expanded.width > tile.width)
        #expect(a.bounds.height == bounds.height && a.rows == rows && a.cols > cols)
        #expect(a.pty === ptyA && b.pty === ptyB && b.superview == nil)
        controller.revealAndFocusFloatingPane(b)
        await settle()
        #expect(a.bounds.size == bounds && a.rows == rows && a.cols == cols)
        controller.toggleMaximizeFloatingPane(a, in: canvas)
        await settle()
        let maxBounds = a.bounds.size, maxRows = a.rows, maxCols = a.cols
        controller.minimizeFloatingPane(b)
        await settle()
        #expect(a.bounds.size == maxBounds && a.rows == maxRows && a.cols == maxCols)
        #expect(controller.floatingCanvas.presentedFrame(of: a.id, in: canvas).height == canvas.height)
        controller.revealAndFocusFloatingPane(b)
        await settle()
        #expect(a.bounds.size == maxBounds && a.rows == maxRows && a.cols == maxCols)
        #expect(a.pty === ptyA && b.pty === ptyB)
    }

    @Test func shelfAnchorMatchesFourteenPointOverlayInsets() {
        let canvas = CGSize(width: 1000, height: 700)
        #expect(FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: true)
                == FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: false))
        let anchor = FloatingCanvasMotion.shelfAnchorRect(in: canvas)
        #expect(anchor.maxX == 986 && anchor.maxY == 686)
        #expect(anchor.height == 30)
    }
}
