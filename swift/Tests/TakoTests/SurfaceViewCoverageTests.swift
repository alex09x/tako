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

struct SurfaceViewCoverageTests {
    /// Saves and restores `NSPasteboard.general` around a test, since
    /// `copy`/`paste` are hardwired to the real system pasteboard.
    func withSavedGeneralPasteboard(_ body: () -> Void) {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        body()
    }

    @Test func frameInitStartsAReadyLiveSurface() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        #expect(view.uuid == view.id)
        #expect(view.restoredID == nil)
        #expect(view.pty != nil)
        #expect(view.surface == nil)
        #expect(!view.processExited)
        #expect(!view.needsConfirmQuit)
        #expect(view.pid > 0)
        // The terminal device the shell runs on: the pty's slave, by
        // `ptsname` (the master itself has no `ttyname`).
        #expect(view.ttyName.hasPrefix("/dev/tty"))
        #expect(view.mouseCaptured == false)
        #expect(view.cellSize.width > 0 && view.cellSize.height > 0)
    }

    @Test func mouseCapturedFollowsTheProgramsMouseTrackingMode() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.core.feed(bytes: Data("\u{1b}[?1000h".utf8))
        #expect(view.mouseCaptured)
        view.core.feed(bytes: Data("\u{1b}[?1000l".utf8))
        #expect(!view.mouseCaptured)
    }

    @Test func appBackedInitDerivesConfigFromTheAppAndAcceptsABaseConfig() throws {
        let app = Tako.App()
        var base = Tako.SurfaceConfiguration()
        base.workingDirectory = NSHomeDirectory()
        base.initialInput = "echo base-config-initial-input\n"

        let view = Tako.SurfaceView(app, baseConfig: base)
        defer { view.close() }

        #expect(view.derivedConfig == Tako.SurfaceView.DerivedConfig(app.config))
        #expect(view.derivedConfig == view.derivedConfig)

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("base-config-initial-input") })
    }

    @Test func defaultDerivedConfigMatchesAnUnconfiguredSurface() {
        let config = Tako.SurfaceView.DerivedConfig()
        #expect(config.backgroundOpacity == 1.0)
        #expect(config.backgroundBlur == .disabled)
        #expect(config.macosWindowShadow)
        #expect(config.windowTitleFontFamily == nil)
        #expect(config.scrollbar == .system)
    }

    @Test func writeSendsTextToTheLiveShell() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.write("echo write-method-text\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("write-method-text") })
    }

    @Test func sendTextWritesAndScrollsToTheBottom() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.sendText("echo send-text-method\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("send-text-method") })
        #expect(view.core.snapshot().viewportOffset == 0)
    }

    /// The `else if event.key == .space` branch: the only key with no
    /// `ffiKeys` mapping of its own that still has to reach the shell.
    /// The pty's own line-discipline echo is what proves the space byte
    /// specifically made it across -- a dropped space would leave the two
    /// halves of the marker glued together.
    @Test func sendKeyEventWithSpaceInsertsALiteralSpace() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.write("MARKQA")
        view.send(keyEvent: Tako.Input.KeyEvent(key: .space, action: .press))
        view.write("MARKQB\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("MARKQA MARKQB") })
    }

    @Test func sendKeyEventWithANamedKeyEncodesThroughTheCore() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.write("echo enter-key-test")
        // Enter's own byte sequence, produced by the `ffiKeys` lookup, has
        // to be interpreted by the shell as a submitted line for this output
        // to ever appear.
        view.send(keyEvent: Tako.Input.KeyEvent(key: .enter, action: .press))

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("enter-key-test") })
    }

    /// `guard ffi.press else { return }` returns before touching the pty at
    /// all, synchronously -- so the grid must be byte-for-byte unchanged
    /// immediately after the call, with no waiting required.
    @Test func sendKeyEventReleaseIsDroppedBeforeReachingThePty() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.visibleText

        view.send(keyEvent: Tako.Input.KeyEvent(key: .enter, action: .release))

        #expect(view.visibleText == before)
    }

    /// `.unidentified` maps to `.character` with empty text: the "nothing to
    /// send" branch returns before the pty write, synchronously.
    @Test func sendKeyEventWithNoTextAndNoKeyIsDropped() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.visibleText

        view.send(keyEvent: Tako.Input.KeyEvent(key: .unidentified, action: .press, mods: [], text: nil))

        #expect(view.visibleText == before)
    }

    @Test func mousePosThenButtonUpdatesTheTrackedCellAndDoesNotCrash() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        #expect(view.mouseCell == nil)
        view.send(mousePos: Tako.Input.MousePosEvent(x: 10, y: 10, mods: []))
        #expect(view.mouseCell != nil)

        view.send(mouseButton: Tako.Input.MouseButtonEvent(action: .press, button: .left, mods: []))
        view.send(mouseButton: Tako.Input.MouseButtonEvent(action: .release, button: .left, mods: []))
    }

    @Test func mouseButtonWithoutAKnownCellPositionIsIgnored() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(view.mouseCell == nil)
        // The guard-return branch: no cell tracked yet.
        view.send(mouseButton: Tako.Input.MouseButtonEvent(action: .press, button: .middle, mods: []))
    }

    @Test func mouseScrollMovesTheViewportOutsideMouseReportingMode() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        for line in 0..<400 {
            view.core.feed(bytes: Data("line \(line)\r\n".utf8))
        }
        _ = view.core.takeOutput()
        view.core.scrollViewportUp(lines: 20)
        let before = view.core.snapshot().viewportOffset
        #expect(before > 0)

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: 3, mods: .init(precision: false, momentum: .none)))
        let afterUp = view.core.snapshot().viewportOffset
        #expect(afterUp > before)

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: -1, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset < afterUp)
    }

    /// With mouse tracking enabled the wheel becomes a report instead of a
    /// local scroll: the viewport must stay exactly where it was, for both
    /// scroll directions (the wheelUp/wheelDown branch of the report).
    @Test func mouseScrollReportsInsteadOfScrollingWhenMouseTrackingIsEnabled() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        for line in 0..<400 {
            view.core.feed(bytes: Data("line \(line)\r\n".utf8))
        }
        _ = view.core.takeOutput()
        view.core.scrollViewportUp(lines: 20)
        let before = view.core.snapshot().viewportOffset
        #expect(before > 0)

        view.core.feed(bytes: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        _ = view.core.takeOutput()
        view.send(mousePos: Tako.Input.MousePosEvent(x: 10, y: 10, mods: []))

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: 3, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset == before)

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: -3, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset == before)
    }

    @Test func mouseScrollWithNoVerticalMovementIsANoOp() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.core.snapshot().viewportOffset
        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: 0, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset == before)
    }

    @Test func copyWithNoSelectionLeavesThePasteboardAlone() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("untouched", forType: .string)

            view.copy(nil)

            #expect(NSPasteboard.general.string(forType: .string) == "untouched")
        }
    }

    @Test func copyPutsTheSelectedLineOnThePasteboard() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }
            // The live pty is also feeding this same core asynchronously
            // (shell startup banter), so this cannot assume the marker lands
            // on row 0: it polls for whichever row actually holds it.
            view.core.feed(bytes: Data("\r\ncopy-me-please\r\n".utf8))
            _ = view.core.takeOutput()

            var markerRow: Int?
            #expect(waitUntil(timeout: 5) {
                markerRow = (0..<view.rows).first { view.core.getLine(row: UInt32($0)).contains("copy-me-please") }
                return markerRow != nil
            })
            view.core.selectLine(row: UInt32(markerRow ?? 0), col: 0)

            view.copy(nil)

            #expect(NSPasteboard.general.string(forType: .string)?.contains("copy-me-please") == true)
        }
    }


}
