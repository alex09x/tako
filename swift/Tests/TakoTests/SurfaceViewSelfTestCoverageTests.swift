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
import CoreGraphics
import Darwin
import Foundation
import TakoKit
import Testing
@testable import Tako


// MARK: - TakoTerminalNSViewDelegate conformance

@MainActor
struct SurfaceViewShellIntegrationEventTests {
    // NOTE ON UNREACHABLE CODE: `setupCoreAndPty`'s PTY `onData` closure
    // routes every OSC-driven event (bell, title, pwd, clipboard set/query,
    // notification, progress, command start/end -- roughly the block from
    // `case .bell:` through the end of `case .clipboardQuery:`) through
    // `DispatchQueue.main.sync` because it is called from the parser queue.
    // A bare `swift test` host process never runs a run loop on the literal
    // main thread, so nothing ever drains `DispatchQueue.main`: a `.sync`
    // call onto it from a background thread blocks forever. This is
    // confirmed independently and non-destructively by
    // `TakoNamespaceHelperCoverageTests.moveFocusWithADelayDoesNotCrash`,
    // which shows the same `DispatchQueue.main.asyncAfter` pattern never
    // fires its closure in this harness either. Deliberately feeding an OSC
    // sequence through a live surface here to exercise that switch would
    // permanently wedge a parser-queue thread for the rest of the test
    // process, for coverage this harness cannot ever observe -- so that
    // block is left uncovered rather than contorted around. Everything
    // reachable without it (plain text, encoded key/mouse/paste bytes,
    // which skip `requiresSynchronousMainApplication`) is covered above.

    @Test func resizeCallbackForwardsToThePty() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let pty = try #require(view.pty)

        // Directly exercises the TakoTerminalNSViewDelegate conformance
        // methods without depending on window-driven resize plumbing.
        view.terminalView(view, didResizeCols: 100, rows: 32)

        // The pty's own kernel-tracked window size is the observable proof
        // the resize actually reached it, not just that the call compiled.
        var size = winsize()
        #expect(ioctl(pty.master, TIOCGWINSZ, &size) == 0)
        #expect(size.ws_col == 100)
        #expect(size.ws_row == 32)

        view.terminalView(view, sendInputData: Data([0x61]))
        view.terminalView(view, sendDeviceReplyData: Data([0x62]))
    }
}

// MARK: - Self-tests (key path proof, independent of a live display link)

@MainActor
struct SurfaceViewSelfTestCoverageTests {
    /// Hosts `view` a level *below* the window's content view, so the
    /// self-tests' own `find(_:)` walk has to recurse into `subviews`
    /// instead of matching the content view directly.
    private func hostedWindow(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wrapper.addSubview(view)
        window.contentView = wrapper
        window.orderFront(nil)
        return window
    }

    /// `runKeySelfTest` depends only on real `NSEvent`s reaching `keyDown`
    /// and being captured -- no display link, no GPU. It writes its report
    /// to `/tmp/tako-keytest.txt`, which is the observable proof of what it
    /// did.
    @Test func keySelfTestEncodesEveryCaseIncludingCyrillicCtrlC() {
        // A private report directory: another run on this machine (or the
        // app's own self-test) must not delete or overwrite this file.
        let dir = NSTemporaryDirectory() + "tako-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previousDir = Tako.selfTestReportDirectory
        Tako.selfTestReportDirectory = dir
        defer { Tako.selfTestReportDirectory = previousDir; try? FileManager.default.removeItem(atPath: dir) }
        let reportPath = Tako.selfTestReportPath("tako-keytest.txt")

        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        // The self-test targets the key window; make it this one, not a
        // window some other test left open.
        window.makeKeyAndOrderFront(nil)
        #expect(NSApplication.shared.windows.contains(where: { $0.contentView?.subviews.contains(view) == true }))

        Tako.runKeySelfTest()

        #expect(waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: reportPath) })
        let report = (try? String(contentsOfFile: reportPath, encoding: .utf8)) ?? ""
        #expect(report.contains("ctrl+c"))
        #expect(report.contains("shift+1"))
    }

    /// A 100x60 BGRA frame: red in each of `reds`, a dark background elsewhere.
    private func selfTestFrame(red reds: [CGRect]) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 100 * 60 * 4)
        for y in 0..<60 {
            for x in 0..<100 {
                let i = (y * 100 + x) * 4
                let inside = reds.contains { $0.contains(CGPoint(x: x, y: y)) }
                pixels[i] = inside ? 0 : 14        // B
                pixels[i + 1] = inside ? 0 : 16    // G
                pixels[i + 2] = inside ? 220 : 20  // R
                pixels[i + 3] = 255
            }
        }
        return pixels
    }

    private func frameCheck(_ pixels: [UInt8], padding: CGFloat,
                            _ color: TerminalTheme.WindowPaddingColor) -> String? {
        let cell = CGSize(width: 10, height: 20)
        let layout = TerminalGridLayout(
            viewSize: CGSize(width: 100, height: 60), cellSize: cell,
            padding: TerminalPadding(uniform: padding), balance: false)
        return Tako.frameCheck(pixels: pixels, width: 100, height: 60, scale: 1, layout: layout,
                               cell: cell, paddingColor: color)
    }

    /// The frame self-test's verdict: nil until the red block is drawn, then
    /// ok when the four red cells start at the grid's edge and the margins are
    /// filled as `window-padding-color` says, FAIL when the block is drawn
    /// over the margin or a margin shows the wrong colour.
    @Test func frameCheckFindsTheGridInsideItsPaddingWithABackgroundMargin() {
        #expect(frameCheck(selfTestFrame(red: []), padding: 10, .background) == nil, "no red block yet: keep waiting")
        let inside = frameCheck(selfTestFrame(red: [CGRect(x: 10, y: 10, width: 40, height: 20)]),
                                padding: 10, .background)
        #expect(inside?.contains("FAIL") == false)
        let overPadding = frameCheck(selfTestFrame(red: [CGRect(x: 0, y: 0, width: 60, height: 40)]),
                                     padding: 10, .background)
        #expect(overPadding?.contains("FAIL left margin is the background") == true)
        #expect(overPadding?.contains("FAIL top margin is the background") == true)
        #expect(overPadding?.contains("FAIL the block ends four cells in") == true)
        #expect(Tako.frameCheck(pixels: [1, 2, 3], width: 100, height: 60, scale: 1,
                                layout: TerminalGridLayout(viewSize: .zero, cellSize: .zero,
                                                           padding: TerminalPadding(uniform: 0), balance: false),
                                cell: .zero) == nil, "a short buffer is not a frame")
    }

    /// `extend`, the default: the margin beside the grid repeats the edge
    /// cell, the margin above it stays the background (the block's row has
    /// default-background cells), and the block's end still places the grid.
    @Test func frameCheckAcceptsTheExtendedMarginAndStillPlacesTheGrid() {
        let block = CGRect(x: 10, y: 10, width: 40, height: 20)
        let extended = CGRect(x: 0, y: 10, width: 10, height: 20)
        let ok = frameCheck(selfTestFrame(red: [block, extended]), padding: 10, .extend)
        #expect(ok?.contains("FAIL") == false, "\(ok ?? "nil")")
        #expect(ok?.contains("ok   left margin repeats the edge cell") == true)
        // A margin left as the background where `extend` should have repeated the cell.
        let unextended = frameCheck(selfTestFrame(red: [block]), padding: 10, .extend)
        #expect(unextended?.contains("FAIL left margin repeats the edge cell") == true)
        // The grid drawn 6 pt into the margin: the margin is red either way,
        // but red now stops 6 pt early.
        let shifted = frameCheck(selfTestFrame(red: [CGRect(x: 4, y: 10, width: 40, height: 20),
                                                     CGRect(x: 0, y: 10, width: 4, height: 20)]),
                                 padding: 10, .extend)
        #expect(shifted?.contains("FAIL the block ends four cells in") == true)
        // extend-always repeats the edge row above the grid too.
        let always = frameCheck(selfTestFrame(red: [block, extended, CGRect(x: 10, y: 0, width: 40, height: 10)]),
                                padding: 10, .extendAlways)
        #expect(always?.contains("FAIL") == false, "\(always ?? "nil")")
    }

    /// The hosted CI's frame (run 43781688685): the 6 pt command-mark gutter
    /// and no top padding, 8x18 cells, the default `extend`. The gutter
    /// repeats the red edge cell, as the renderer's own tests require.
    @Test func frameCheckPassesTheHostedCIGutterFrame() {
        let cell = CGSize(width: 8, height: 18)
        let layout = TerminalGridLayout(
            viewSize: CGSize(width: 100, height: 60), cellSize: cell,
            padding: TerminalPadding(left: 6, right: 0, top: 0, bottom: 0), balance: false)
        #expect(layout.left == 6 && layout.top == 0)
        let pixels = selfTestFrame(red: [CGRect(x: 0, y: 0, width: 6 + 32, height: 18)])
        let report = Tako.frameCheck(pixels: pixels, width: 100, height: 60, scale: 1, layout: layout,
                                     cell: cell, paddingColor: .extend)
        #expect(report?.contains("FAIL") == false, "\(report ?? "nil")")
        #expect(report?.contains("ok   left margin repeats the edge cell") == true)
        #expect(report?.contains("--   no top margin (0 pt)") == true)
    }

    /// No padding: the hosted CI's real case had no top margin at all, and
    /// a check of the pixels above the grid would sample the grid itself.
    @Test func frameCheckSaysWhenThereIsNoMarginToCheck() {
        let report = frameCheck(selfTestFrame(red: [CGRect(x: 0, y: 0, width: 40, height: 20)]), padding: 0, .extend)
        #expect(report?.contains("FAIL") == false, "\(report ?? "nil")")
        #expect(report?.contains("--   no left margin (0 pt)") == true)
        #expect(report?.contains("--   no top margin (0 pt)") == true)
    }

    @Test func writePNGSavesTheFrameAsAnImage() throws {
        let path = NSTemporaryDirectory() + "tako-frame-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        Tako.writePNG([UInt8](repeating: 200, count: 4 * 2 * 4), width: 4, height: 2, to: path)
        let image = try #require(NSImage(contentsOfFile: path))
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsWide == 4)
        #expect(rep.pixelsHigh == 2)
    }

    /// Without a Metal renderer -- a test host has none -- the frame
    /// self-test says so instead of waiting for a frame that never comes.
    @Test func frameSelfTestReportsAMissingRenderer() {
        let dir = NSTemporaryDirectory() + "tako-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previousDir = Tako.selfTestReportDirectory
        Tako.selfTestReportDirectory = dir
        defer { Tako.selfTestReportDirectory = previousDir; try? FileManager.default.removeItem(atPath: dir) }
        let reportPath = Tako.selfTestReportPath("tako-frametest.txt")

        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        window.makeKeyAndOrderFront(nil)
        guard view.metalRendererForTesting == nil else { return }

        Tako.runFrameSelfTest()

        #expect(waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: reportPath) })
        let report = (try? String(contentsOfFile: reportPath, encoding: .utf8)) ?? ""
        #expect(report.hasPrefix("FAIL no Metal renderer"))
    }

    /// `runScrollSelfTest` proves the precise-wheel-to-row-fraction pipeline
    /// through the real responder chain. Whether a frame is ever actually
    /// *presented* depends on a live display link, which a `swift test`
    /// host does not drive -- so this checks the geometry lines the
    /// function always writes rather than the frame-submission summary.
    @Test func scrollSelfTestWritesRowFractionGeometry() {
        // A private report directory: another run on this machine (or the
        // app's own self-test) must not delete or overwrite this file.
        let dir = NSTemporaryDirectory() + "tako-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previousDir = Tako.selfTestReportDirectory
        Tako.selfTestReportDirectory = dir
        defer { Tako.selfTestReportDirectory = previousDir; try? FileManager.default.removeItem(atPath: dir) }
        let reportPath = Tako.selfTestReportPath("tako-scrolltest.txt")

        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        // The self-test targets the key window; make it this one, not a
        // window some other test left open.
        window.makeKeyAndOrderFront(nil)
        #expect(NSApplication.shared.windows.contains(where: { $0.contentView?.subviews.contains(view) == true }))

        Tako.runScrollSelfTest()

        #expect(waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: reportPath) })
        let report = (try? String(contentsOfFile: reportPath, encoding: .utf8)) ?? ""
        #expect(report.contains("start"))
        #expect(report.contains("after 3 of 3 points up"))
    }

    /// `runInputSelfTest` types a whole sentence through real `keyDown`
    /// events into the real shell, then writes its report from inside a
    /// `DispatchQueue.main.asyncAfter(1.5s)` closure. That closure needs a
    /// live run loop on the literal main thread to ever fire, which a bare
    /// `swift test` host does not drive (see the note in
    /// `SurfaceViewShellIntegrationEventTests`), so the report file itself
    /// is not observable here. Everything before that -- finding the
    /// surface, focusing it, and typing the whole sequence -- runs
    /// synchronously and reaches the real pty, so the shell's own echo is:
    /// ctrl+u clears everything typed before it, so "hello world" is what
    /// should actually survive to the screen.
    @Test func inputSelfTestTypesThroughTheRealResponderChainWithoutCrashing() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        Tako.runInputSelfTest()

        // `runInputSelfTest` resolves its target window via `NSApp.keyWindow
        // ?? NSApp.windows.first`; whether this process's window can ever
        // become key depends on activation the test host may or may not
        // grant (same caveat as
        // `TakoNamespaceHelperCoverageTests.focusedWorkingDirectoryReadsTheKeyWindowsFirstResponderSurface`).
        // ctrl+u clears everything typed before it, so "hello world" is what
        // should survive to the shell's echo whenever the lookup does land
        // on our window.
        if window.isKeyWindow {
            #expect(waitUntil(timeout: 8) { view.visibleText.contains("hello world") })
        }
    }
}
