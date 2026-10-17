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
import Testing
@testable import Tako

/// A tab nobody can see does not draw: background tabs are ordered-out
/// windows, and each used to plan and present every frame of its output.
@Suite
@MainActor
struct SurfaceVisibilityTests {
    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                 styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func aWindowNeverOrderedInShowsNothing() {
        #expect(!Tako.SurfaceVisibilityWatch.isShowing(makeWindow()))
    }

    @Test func drawingPausesWhileHiddenAndResumesWhenShown() {
        let window = makeWindow()
        let view = TakoTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var showing = false
        let watch = Tako.SurfaceVisibilityWatch(surface: view, window: window, isShowing: { _ in showing })
        #expect(view.isPresentationPaused)

        showing = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(!view.isPresentationPaused)

        showing = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(view.isPresentationPaused)

        // Another window's change is not this one's.
        showing = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: makeWindow())
        #expect(view.isPresentationPaused)
        withExtendedLifetime(watch) {}
    }
}
