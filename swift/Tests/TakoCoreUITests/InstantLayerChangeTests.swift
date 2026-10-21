/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Metal
import XCTest
@testable import TakoCoreUI

/// What a pane changes at once, without Core Animation's implicit quarter
/// second: the progress bar, the sticky header and its hover, the context
/// breadcrumbs, the link HUD and underline, the scroller and gutter marks,
/// trigger highlights, and the Metal layer as the pane resizes. Each change
/// is made on a view in a shown window, where implicit animations run, and
/// no layer may come out of it animating.
@MainActor
final class InstantLayerChangeTests: XCTestCase {
    private func makeView() throws -> TakoTerminalNSView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: shaders, encoding: .utf8), options: nil)
        TakoTerminalNSView.metalLibraryProviderForTesting = { _ in library }
        addTeardownBlock { TakoTerminalNSView.metalLibraryProviderForTesting = nil }
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        return view
    }

    /// Every animation on the layers under `root`, by layer and key.
    private func animations(under root: CALayer) -> Set<String> {
        var found = Set<String>()
        func walk(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] {
                found.insert("\(ObjectIdentifier(layer).hashValue) \(layer.name ?? String(describing: type(of: layer))).\(key)")
            }
            layer.sublayers?.forEach(walk)
            layer.mask.map(walk)
        }
        walk(root)
        return found
    }

    private func assertInstant(_ view: TakoTerminalNSView, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                               _ change: () -> Void) {
        CATransaction.flush()
        let root = view.layer!
        let before = animations(under: root)
        change()
        CATransaction.flush()
        let added = animations(under: root).subtracting(before)
        XCTAssertTrue(added.isEmpty, "\(what) animated: \(added.sorted())", file: file, line: line)
    }

    /// The check sees an implicit animation where there is one.
    func testAChangeLeftToAnimateIsSeen() throws {
        let view = try makeView()
        let plain = CALayer()
        plain.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        view.layer?.addSublayer(plain)
        CATransaction.flush()
        let before = animations(under: view.layer!)
        plain.opacity = 0.3
        CATransaction.flush()
        XCTAssertFalse(animations(under: view.layer!).subtracting(before).isEmpty, "the check is blind: a plain layer's fade was not seen")
    }

    func testTheProgressBarComesMovesAndGoesAtOnce() throws {
        let view = try makeView()
        view.paneProgressBarEnabled = true
        assertInstant(view, "the progress bar coming") { view.updateProgressBar(state: .normal, progress: 20) }
        XCTAssertFalse(view.paneProgressBarLayer.isHidden)
        assertInstant(view, "the progress bar moving") { view.updateProgressBar(state: .normal, progress: 80) }
        assertInstant(view, "the progress bar failing") { view.updateProgressBar(state: .error, progress: 80) }
        assertInstant(view, "the progress bar going") { view.updateProgressBar(state: .none, progress: nil) }
        XCTAssertTrue(view.paneProgressBarLayer.isHidden)
    }

    func testTheStickyHeaderAndItsHoverChangeAtOnce() throws {
        let view = try makeView()
        assertInstant(view, "the sticky header's hover") { view.updateStickyHeaderHover(true) }
        assertInstant(view, "the sticky header's hover going") { view.updateStickyHeaderHover(false) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.stickyHeaderLayer.isHidden = false
        CATransaction.commit()
        assertInstant(view, "the sticky header going") { view.updateStickyCommandHeader() }
        XCTAssertTrue(view.stickyHeaderLayer.isHidden)
    }

    func testTheContextBreadcrumbsGoAtOnce() throws {
        let view = try makeView()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.contextBreadcrumbsLayer.isHidden = false
        CATransaction.commit()
        assertInstant(view, "the context breadcrumbs going") { view.updateContextState() }
        XCTAssertTrue(view.contextBreadcrumbsLayer.isHidden)
    }

    func testTheLinkHUDComesChangesAndGoesAtOnce() throws {
        let view = try makeView()
        func link(_ mismatch: Bool) -> TerminalLink {
            TerminalLink(url: URL(string: "https://example.com/a")!, text: "example", row: 0, colStart: 0, colEnd: 6,
                         isOsc8: true, isMismatch: mismatch, isSchemeAllowedWithoutPrompt: true)
        }
        assertInstant(view, "the link HUD coming") { view.updateLinkHUD(link: link(false)) }
        XCTAssertFalse(view.linkHUDLayer.isHidden)
        assertInstant(view, "the link HUD turning red") { view.updateLinkHUD(link: link(true)) }
        assertInstant(view, "the link HUD going") { view.updateLinkHUD(link: nil) }
        XCTAssertTrue(view.linkHUDLayer.isHidden)
    }

    func testTheLinkUnderlineComesAndGoesAtOnce() throws {
        let view = try makeView()
        view.feed(data: Data("see https://example.com/page now\r\n".utf8))
        view.mouseCell = (row: 0, col: 8)
        assertInstant(view, "the link underline coming") { view.updateHoveredLink(commandHeld: true) }
        XCTAssertFalse(view.linkUnderlineLayer.isHidden, "no link under the pointer: the test hovers nothing")
        assertInstant(view, "the link underline going") { view.updateHoveredLink(commandHeld: false) }
        XCTAssertTrue(view.linkUnderlineLayer.isHidden)
    }

    func testTheScrollerAndTheGutterMarksMoveAtOnce() throws {
        let view = try makeView()
        view.commandMarksEnabled = true
        for i in 0..<60 {
            view.feed(data: Data("\u{1b}]133;A\u{07}$ cmd\(i)\r\n\u{1b}]133;C\u{07}out\(i)\r\n\u{1b}]133;D;\(i % 2)\u{07}".utf8))
        }
        view.updateScroller()
        XCTAssertGreaterThan(view.gutterMarksLayer.sublayers?.count ?? 0, 0, "no gutter marks: the test moves nothing")
        assertInstant(view, "the scroller and the marks scrolling to the top") { view.scrollPosition = 0 }
        assertInstant(view, "the scroller and the marks scrolling back") { view.scrollPosition = 1 }
    }

    func testTriggerHighlightsComeAndMoveAtOnce() throws {
        let view = try makeView()
        view.feed(data: Data("[ERROR] Database failure\r\n".utf8))
        view.regexTriggers = [TerminalRegexTrigger(pattern: "\\[ERROR\\]", action: .highlight, colorName: "red", style: .box)!]
        assertInstant(view, "a trigger highlight coming") { view.updateRegexTriggerHighlights() }
        XCTAssertEqual(view.triggerHighlightsLayer.sublayers?.count, 1)
        assertInstant(view, "a trigger highlight moving with the output") {
            view.feed(data: Data("more\r\nlines\r\n".utf8))
            view.updateRegexTriggerHighlights()
        }
    }

    func testAResizedPaneTakesItsNewSizeAtOnce() throws {
        let view = try makeView()
        view.regexTriggers = [TerminalRegexTrigger(pattern: "x", action: .highlight, colorName: "red", style: .box)!]
        assertInstant(view, "the pane's layers resizing") {
            view.window?.setContentSize(NSSize(width: 480, height: 300))
            view.layoutSubtreeIfNeeded()
        }
    }
}
#endif
