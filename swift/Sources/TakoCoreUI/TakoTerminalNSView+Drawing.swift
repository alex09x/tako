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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import QuartzCore
import simd

extension TakoTerminalNSView {
    // MARK: - Theme colors

    static func metalPalette(
        for theme: TerminalTheme,
        encoding: TerminalMetalColorEncoding = .displayEncoded
    ) -> TerminalMetalPalette {
        TerminalMetalPalette(
            background: metalColor(theme.background, alpha: Float(theme.backgroundOpacity), encoding: encoding),
            foreground: metalColor(theme.foreground, encoding: encoding),
            selection: metalColor(theme.selectionBackground, encoding: encoding),
            cursor: metalColor(theme.cursorColor, alpha: Float(theme.cursorOpacity), encoding: encoding),
            selectionForeground: theme.selectionForeground.map { metalColor($0, encoding: encoding) },
            selectionInvertsColors: theme.selectionInvertFgBg
        )
    }

    static func marginFill(_ color: TerminalTheme.WindowPaddingColor) -> TerminalMetalMargins.Fill {
        switch color {
        case .background: return .background
        case .extend: return .extend
        case .extendAlways: return .extendAlways
        }
    }

    static func metalColor(
        _ color: CGColor,
        alpha: Float? = nil,
        encoding: TerminalMetalColorEncoding = .displayEncoded
    ) -> SIMD4<Float> {
        let converted = color.converted(to: srgbSpace, intent: .defaultIntent, options: nil) ?? color
        let parts = converted.components ?? []
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
        }
        switch parts.count {
        case 0:
            return TerminalMetalColor.rgba(r: 0, g: 0, b: 0, alpha: alpha ?? 1, encoding: encoding)
        case 1, 2:
            let gray = byte(parts[0])
            let opacity = alpha ?? Float(parts.count == 2 ? parts[1] : 1)
            return TerminalMetalColor.rgba(r: gray, g: gray, b: gray, alpha: opacity, encoding: encoding)
        default:
            return TerminalMetalColor.rgba(
                r: byte(parts[0]),
                g: byte(parts[1]),
                b: byte(parts[2]),
                alpha: alpha ?? Float(parts.count >= 4 ? parts[3] : 1),
                encoding: encoding
            )
        }
    }

    // MARK: - Layout & Drawing

    override open var isFlipped: Bool { false }

    override open func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        isLeavingWindow = newWindow == nil
    }

    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isLeavingWindow = false
        observeWindowKeyState()
        updateInputContextActivation()
        if window == nil {
            displayLink?.isPaused = true
            cancelPresentationThrottle()
        } else {
            startDisplayLink()
            if metalRenderer != nil, effectiveContentScale != metalContentScale {
                rebuildMetalRenderer()
            } else {
                applyMetalLayerGeometry()
            }
            let availableSize = bounds.size.width > 0 && bounds.size.height > 0
                ? bounds.size
                : (window?.contentView?.bounds.size ?? .zero)
            if availableSize.width > 0 && availableSize.height > 0 {
                let fitted = TerminalGridLayout(
                    viewSize: availableSize,
                    cellSize: CGSize(width: cellWidth, height: cellHeight),
                    theme: theme
                )
                if fitted.cols > 0 && fitted.rows > 0 && (fitted.cols != cols || fitted.rows != rows) {
                    scheduleGridResize(cols: fitted.cols, rows: fitted.rows)
                }
            }
            scheduleRedraw()
        }
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        } else {
            applyMetalLayerGeometry()
        }
    }

    override open func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        } else {
            applyMetalLayerGeometry()
        }

        let fitted = TerminalGridLayout(
            viewSize: newSize,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            theme: theme
        )
        scheduleGridResize(cols: fitted.cols, rows: fitted.rows)
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
        updateScroller()
        delegate?.terminalView(self, didResizeCols: appliedCols, rows: appliedRows)
        scheduleRedraw()
    }

    public func flushPendingResizeForTesting() {
        pendingResizeWorkItem?.cancel()
        applyPendingGridResize()
    }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override open func draw(_ dirtyRect: NSRect) {
        guard !isPresentationPaused else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if metalLayer != nil, metalRenderer != nil {
            guard redrawPending || presentationRetryPending else { return }
            redrawNow()
            if let marked = markedText, !marked.isEmpty {
                let cursorRow = Int(core.cursorRow()), cursorCol = Int(core.cursorCol())
                let y = cellOrigin(row: cursorRow, col: cursorCol).y
                context.saveGState()
                context.translateBy(x: gridLayout.left, y: 0)
                renderer.drawMarkedText(
                    marked,
                    cursorCol: cursorCol,
                    cols: Int(core.cols()),
                    availableRows: max(0, Int(core.rows()) - cursorRow),
                    y: y,
                    in: context
                )
                context.restoreGState()
            }
            return
        }

        // CPU Fallback Path
        guard redrawPending || presentationRetryPending else { return }
        guard claimPresentationPermit() else { return }
        cancelPresentationThrottle()
        redrawPending = false
        clearPresentationRetry()
        let bg = theme.backgroundOpacity < 1
            ? theme.background.copy(alpha: CGFloat(theme.backgroundOpacity))!
            : theme.background
        context.setFillColor(bg)
        context.fill(bounds)

        context.saveGState()

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

        let layout = gridLayout
        renderer.drawWindow(
            in: context,
            windowSize: bounds.size,
            layout: layout,
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

        if let marked = markedText, !marked.isEmpty {
            let y = CGFloat(Int(snapshot.rows) - 1 - Int(snapshot.cursorRow)) * cellHeight
            renderer.drawMarkedText(
                marked,
                cursorCol: Int(snapshot.cursorCol),
                cols: Int(snapshot.cols),
                availableRows: max(0, Int(snapshot.rows) - Int(snapshot.cursorRow)),
                y: y,
                in: context
            )
        }

        if !snapshot.graphicsPlacements.isEmpty {
            renderer.drawImages(
                snapshot.graphicsPlacements,
                rows: Int(snapshot.rows),
                imageProvider: { [core] in core.graphicsImage(imageId: $0) },
                in: context
            )
        }
        context.restoreGState()
        refreshHoveredLink()
    }

    // MARK: - Cursor Blink

    func startBlinkTimer() {
        updateBlinkTimer()
    }

    func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkStateVisible = true
        guard theme.cursorBlink, !isPresentationPaused else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.theme.cursorBlink, !self.isPresentationPaused else { return }
                guard !self.core.isSynchronizedOutputActive() else { return }
                self.blinkStateVisible.toggle()
                self.scheduleRedraw()
            }
        }
    }
}
#endif
