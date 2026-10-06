/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import Foundation
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import TakoCoreUI

@MainActor
extension TakoTerminalViewTests {
    func testDefaultInputViewCompatibilityAndUIKeyInputState() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(view.customInputView, "Default customInputView must be nil")
        XCTAssertNil(view.inputView, "Default inputView override must return nil to preserve system keyboard")
        XCTAssertTrue(view.canBecomeFirstResponder)
        XCTAssertTrue(view.hasText)

        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        view.insertText("k")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "k")
    }

    func testExactHostInputViewIdentityAndDynamicReplacement() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let hostView1 = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 260))
        let hostView2 = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 300))

        view.customInputView = hostView1
        XCTAssertTrue(view.inputView === hostView1, "inputView override must vend exact host-owned UIView instance")
        XCTAssertTrue(view.customInputView === hostView1)

        // Dynamic replacement with second host view
        view.customInputView = hostView2
        XCTAssertTrue(view.inputView === hostView2, "inputView must update dynamically to new host view")

        // Input view setter alias
        let hostView3 = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        view.inputView = hostView3
        XCTAssertTrue(view.customInputView === hostView3)
        XCTAssertTrue(view.inputView === hostView3)

        // Reset to nil preserves standard keyboard
        view.customInputView = nil
        XCTAssertNil(view.inputView, "Setting customInputView to nil must restore nil inputView")

        // Remains the same UIKeyInput responder throughout
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        view.customInputView = hostView1
        view.insertText("hello")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "hello")
        view.deleteBackward()
        XCTAssertEqual(delegate.inputDataReceived.last, 0x7f)
    }

    func testExactCellGeometry53x53LayoutOn369x764View() {
        let exactWidth: CGFloat = 369.0 / 53.0
        let exactHeight: CGFloat = 764.0 / 53.0
        let theme = TerminalTheme(
            cellWidth: exactWidth,
            cellHeight: exactHeight
        )
        let view = TakoTerminalView(
            frame: CGRect(x: 0, y: 0, width: 369, height: 764),
            theme: theme
        )
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertEqual(view.cols, 53, "Exact cellWidth override must produce exactly 53 columns on 369pt width")
        XCTAssertEqual(view.rows, 53, "Exact cellHeight override must produce exactly 53 rows on 764pt height")
        XCTAssertEqual(Int(view.core.cols()), 53)
        XCTAssertEqual(Int(view.core.rows()), 53)
        XCTAssertEqual(delegate.lastResizedCols, 53)
        XCTAssertEqual(delegate.lastResizedRows, 53)
    }

    func testThemeChangeSynchronizesTextAndMetalMetrics() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 369, height: 764))
        let initialTextWidth = view.renderer.metrics.cellWidth
        let initialTextHeight = view.renderer.metrics.cellHeight

        if let metalPlanner = view.metalRenderer?.planner {
            XCTAssertEqual(metalPlanner.metrics.cellWidth, initialTextWidth)
            XCTAssertEqual(metalPlanner.metrics.cellHeight, initialTextHeight)
        }

        // Apply theme with exact cell overrides
        let exactWidth: CGFloat = 369.0 / 53.0
        let exactHeight: CGFloat = 764.0 / 53.0
        view.theme = TerminalTheme(
            fontSize: 12,
            cellWidth: exactWidth,
            cellHeight: exactHeight
        )

        XCTAssertEqual(view.renderer.metrics.cellWidth, exactWidth)
        XCTAssertEqual(view.renderer.metrics.cellHeight, exactHeight)

        if let metalPlanner = view.metalRenderer?.planner {
            XCTAssertEqual(metalPlanner.metrics.cellWidth, exactWidth, "Metal planner metrics must synchronize with text metrics")
            XCTAssertEqual(metalPlanner.metrics.cellHeight, exactHeight, "Metal planner metrics must synchronize with text metrics")
            XCTAssertEqual(metalPlanner.metrics.pixelCellWidth, Float(exactWidth * view.metalContentScale))
            XCTAssertEqual(metalPlanner.metrics.pixelCellHeight, Float(exactHeight * view.metalContentScale))
        }

        view.layoutSubviews()
        view.flushPendingResizeForTesting()
        XCTAssertEqual(view.cols, 53)
        XCTAssertEqual(view.rows, 53)

        // Switch back to derived theme
        view.theme = TerminalTheme(fontSize: 14)
        let derivedMetrics = TerminalRenderer.Metrics(fontSize: 14)
        XCTAssertEqual(view.renderer.metrics.cellWidth, derivedMetrics.cellWidth)
        XCTAssertEqual(view.renderer.metrics.cellHeight, derivedMetrics.cellHeight)

        if let metalPlanner = view.metalRenderer?.planner {
            XCTAssertEqual(metalPlanner.metrics.cellWidth, derivedMetrics.cellWidth)
            XCTAssertEqual(metalPlanner.metrics.cellHeight, derivedMetrics.cellHeight)
        }
    }

    func testClaudeAlternateScreenHistorySwipesAndReverseRestorationLifecycle() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // 1. Enter alternate screen with mouse tracking
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8))
        XCTAssertTrue(view.isAlternateScreen)

        // 2. Initial transcript with numbered rows 1 through 30
        var initialTranscript = "\u{1b}[H\u{1b}[2J"
        for i in 1...30 {
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "line-\(i)"
            }
            initialTranscript += "\(i) \(word)\r\n"
        }
        view.feed(data: Data(initialTranscript.utf8))
        view.redrawNow()

        // 3. Four native history swipes (swipe down -> scroll up)
        pan.setMockLocation(CGPoint(x: cellW * 5.0, y: cellH * 5.0))
        for _ in 0..<4 {
            pan.state = .began
            _ = view.perform(panSel, with: pan)
            pan.state = .changed
            pan.setTranslation(CGPoint(x: 0, y: cellH * 2.0), in: view)
            _ = view.perform(panSel, with: pan)
            pan.state = .ended
            _ = view.perform(panSel, with: pan)
        }
        XCTAssertFalse(delegate.inputDataReceived.isEmpty, "Alternate screen touch scroll under mouse tracking must emit wheel events")

        // 4. History screen updates from application
        var historyTranscript = "\u{1b}[H\u{1b}[2J"
        for i in 1...30 {
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "hist-\(i)"
            }
            historyTranscript += "  \(word)\r\n"
        }
        view.feed(data: Data(historyTranscript.utf8))
        view.redrawNow()

        // 5. Up to eight reverse swipes back to tail (swipe up -> scroll down)
        for _ in 0..<8 {
            pan.state = .began
            _ = view.perform(panSel, with: pan)
            pan.state = .changed
            pan.setTranslation(CGPoint(x: 0, y: -cellH * 2.0), in: view)
            _ = view.perform(panSel, with: pan)
            pan.state = .ended
            _ = view.perform(panSel, with: pan)
        }

        // 6. Restored tail transcript
        var restoredTailTranscript = "\u{1b}[H\u{1b}[2J"
        for i in 1...26 {
            restoredTailTranscript += "\(i) line-\(i)\r\n"
        }
        restoredTailTranscript += "27\r\n28\r\n29\r\n30\r\n"
        view.feed(data: Data(restoredTailTranscript.utf8))
        view.redrawNow()

        // 7. Verify authoritative text and renderer consistency
        let plainText = view.plainText(startRow: 0, maxRows: 53)
        XCTAssertTrue(plainText.contains("27\n28\n29\n30"))
        XCTAssertFalse(plainText.contains("27twenty-seven"))
        XCTAssertFalse(plainText.contains("28twenty-eight"))

        if let planner = view.metalRenderer?.planner {
            let frame = view.core.renderFrame()
            let stats = planner.plan(frame: frame, viewport: TerminalMetalViewport(drawableWidth: Float(view.bounds.width), drawableHeight: Float(view.bounds.height)))
            let freshPlanner = TerminalMetalFramePlanner(
                metrics: planner.metrics,
                palette: planner.palette
            )
            let freshStats = freshPlanner.plan(frame: frame, viewport: TerminalMetalViewport(drawableWidth: Float(view.bounds.width), drawableHeight: Float(view.bounds.height)))
            XCTAssertEqual(stats.glyphInstances, freshStats.glyphInstances, "Renderer glyph count must match fresh planner without stale glyph retention")
            XCTAssertEqual(planner.glyphInstances, freshPlanner.glyphInstances)
        }
    }


}
#endif
