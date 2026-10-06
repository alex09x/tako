/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import OSLog

#if canImport(UIKit)
import CoreGraphics
import Metal
import QuartzCore
import UIKit
import simd

extension TakoTerminalView {
    // MARK: - Layout & Sizing

    override public func layoutSubviews() {
        super.layoutSubviews()
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        } else {
            applyMetalLayerGeometry()
        }

        let cellW = renderer.metrics.cellWidth
        let cellH = renderer.metrics.cellHeight
        guard cellW > 0, cellH > 0 else { return }

        let newCols = max(Int(bounds.width / cellW), 1)
        let newRows = max(Int(bounds.height / cellH), 1)
        scheduleGridResize(cols: newCols, rows: newRows)
    }

    func scheduleGridResize(cols newCols: Int, rows newRows: Int) {
        if newCols == cols, newRows == rows {
            pendingResizeWorkItem?.cancel()
            pendingResizeWorkItem = nil
            pendingGridSize = nil
            return
        }
        if let pendingGridSize,
           pendingGridSize.cols == newCols,
           pendingGridSize.rows == newRows {
            return
        }

        pendingResizeWorkItem?.cancel()
        pendingGridSize = (newCols, newRows)
        let work = DispatchWorkItem { [weak self] in
            self?.applyPendingGridResize()
        }
        pendingResizeWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.resizeSettleDelay,
            execute: work
        )
    }

    func applyPendingGridResize() {
        cancelKineticScroll()
        pendingResizeWorkItem = nil
        guard let target = pendingGridSize else { return }
        pendingGridSize = nil
        guard target.cols != cols || target.rows != rows else { return }

        TakoLog.resize.info("resize \(cols)×\(rows) → \(target.cols)×\(target.rows)")
        cols = target.cols
        rows = target.rows
        parserCoordinator.resize(cols: cols, rows: rows)
    }

    func applyOrderedResize(cols appliedCols: Int, rows appliedRows: Int) {
        delegate?.terminalView(self, didResizeCols: appliedCols, rows: appliedRows)
        setNeedsDisplay()
    }

    func flushPendingResizeForTesting() {
        pendingResizeWorkItem?.cancel()
        applyPendingGridResize()
    }

    override public func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            displayLink?.isPaused = true
            cancelKineticScroll()
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        }
        if autoFocusKeyboardOnTap {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                _ = self.becomeFirstResponder()
            }
        }
        setNeedsDisplay()
    }

    override public func draw(_ rect: CGRect) {
        guard metalLayer == nil else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let renderFrame = currentRenderFrame()
        let snapshot = renderFrame.snapshot
        let cells = TerminalFrame(
            packed: renderFrame.packedCells,
            cols: Int(snapshot.cols),
            rows: Int(snapshot.rows)
        )

        let cursorVisible = snapshot.cursorVisible
            && snapshot.viewportOffset == 0
            && (blinkStateVisible || !theme.cursorBlink)
        renderer.drawWindow(
            in: context,
            windowSize: bounds.size,
            layout: TerminalGridLayout(
                viewSize: bounds.size,
                cellSize: CGSize(width: renderer.metrics.cellWidth, height: renderer.metrics.cellHeight),
                padding: TerminalPadding(uniform: 0),
                balance: false
            ),
            paddingColor: theme.windowPaddingColor,
            alternateScreen: snapshot.modes.alternateScreen,
            cols: Int(snapshot.cols),
            rows: Int(snapshot.rows),
            rowProvider: { cells.row($0) },
            graphemes: renderFrame.graphemes,
            cursorRow: Int(snapshot.cursorRow),
            cursorCol: Int(snapshot.cursorCol),
            cursorVisible: cursorVisible,
            cursorStyle: snapshot.cursorStyle,
            selection: snapshot.selection
        )
        context.restoreGState()
    }

    // MARK: - Cursor Blink

    func startBlinkTimer() {
        updateBlinkTimer()
    }

    func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkStateVisible = true
        guard theme.cursorBlink else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.theme.cursorBlink else { return }
                guard !self.core.isSynchronizedOutputActive() else { return }
                self.blinkStateVisible.toggle()
                self.setNeedsDisplay()
            }
        }
    }
}
#endif
