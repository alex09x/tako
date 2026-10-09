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
import Foundation
import Testing
@testable import Tako

@MainActor
extension TabBarViewCoverageTests {
    private final class ButtonActionRecorder: NSObject, NSApplicationDelegate {
        var newTabInvoked = false
        var splitInvoked = false
        var aboutInvoked = false
        @objc func newTab(_ sender: Any?) { newTabInvoked = true }
        @objc func splitRight(_ sender: Any) { splitInvoked = true }
        @objc func showAbout(_ sender: Any?) { aboutInvoked = true }
    }

    @Test func clickingTheNewTabButtonSendsTheAction() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)

        Tako.CustomTabGroup.join(makeWindow(title: "b"), to: window, select: false)
        draw(bar)

        let recorder = ButtonActionRecorder()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = recorder
        defer { NSApplication.shared.delegate = originalDelegate }

        click(bar, at: NSPoint(x: 378, y: 19), in: window)
        #expect(recorder.newTabInvoked)
    }

    @Test func clickingTheSplitButtonSendsTheAction() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)

        Tako.CustomTabGroup.join(makeWindow(title: "b"), to: window, select: false)
        draw(bar)

        let recorder = ButtonActionRecorder()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = recorder
        defer { NSApplication.shared.delegate = originalDelegate }

        click(bar, at: NSPoint(x: 346, y: 19), in: window)
        #expect(recorder.splitInvoked)
    }

    @Test func clickingTheAboutButtonSendsTheAction() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)

        Tako.CustomTabGroup.join(makeWindow(title: "b"), to: window, select: false)
        draw(bar)

        let recorder = ButtonActionRecorder()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = recorder
        defer { NSApplication.shared.delegate = originalDelegate }

        click(bar, at: NSPoint(x: 314, y: 19), in: window)
        #expect(recorder.aboutInvoked)
    }

    @Test func buttonsAreClickableInLoneWindowMode() {
        let window = makeWindow(title: "lone")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        draw(bar)

        let recorder = ButtonActionRecorder()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = recorder
        defer { NSApplication.shared.delegate = originalDelegate }

        click(bar, at: NSPoint(x: 314, y: 19), in: window)
        #expect(recorder.aboutInvoked)

        click(bar, at: NSPoint(x: 346, y: 19), in: window)
        #expect(recorder.splitInvoked)

        click(bar, at: NSPoint(x: 378, y: 19), in: window)
        #expect(recorder.newTabInvoked)
    }

    @Test func toolTipsReportCorrectLabels() {
        let window = makeWindow(title: "tooltips")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        draw(bar)

        func move(to point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0)!
            bar.mouseMoved(with: event)
        }

        move(to: NSPoint(x: 314, y: 19))
        #expect(bar.toolTip?.contains("About Tako") == true)

        move(to: NSPoint(x: 346, y: 19))
        #expect(bar.toolTip?.contains("Split Terminal") == true)

        move(to: NSPoint(x: 378, y: 19))
        #expect(bar.toolTip?.contains("New Tab") == true)

        move(to: NSPoint(x: 5, y: 5))
        #expect(bar.toolTip == nil)
    }

    @Test func clickingATabSelectsIt() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        #expect(group.selectedWindow === a)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        // Tab 1 ("b") sits at x: 210...330 at the clamped minimum width.
        click(bar, at: NSPoint(x: 250, y: 14), in: a)
        #expect(group.selectedWindow === b)
    }

    @Test func clickingTheCloseGlyphClosesThatTab() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        // Tab 0 ("a") is active, so its close glyph is drawn; its hit rect
        // sits near the right edge of the 90...210 frame.
        a.orderFront(nil)
        #expect(a.isVisible)
        click(bar, at: NSPoint(x: 195, y: 14), in: a)
        #expect(!a.isVisible)
    }

    @Test func emptyBarDoubleClickZoomsTheWindow() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        window.makeKeyAndOrderFront(nil)
        #expect(!window.isZoomed)

        // Single-window group never shows a strip, so `tabs` stays empty and
        // any click falls into the "empty bar" branch.
        click(bar, at: NSPoint(x: 200, y: 19), in: window, clickCount: 2)

        #expect(window.isZoomed)
        window.close()
    }

    @Test func commandKeyHeldEventuallyShowsBadgesThenClearsOnRelease() async throws {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        let baseline = snapshot(bar)

        bar.commandKeyChanged(held: true)
        var sawBadges = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !bitmapsEqual(snapshot(bar), baseline) {
                sawBadges = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Exercises the numbered-badge branch of drawCrab(for:in:ctx:), once
        // the 0.15s delay elapses.
        #expect(sawBadges)

        bar.commandKeyChanged(held: false)
        // Release is synchronous: the badges are gone immediately.
        #expect(bitmapsEqual(snapshot(bar), baseline))

        // Cancelling before the delay fires exercises the "already hidden"
        // early-return branch, and must never show badges at all.
        bar.commandKeyChanged(held: true)
        bar.commandKeyChanged(held: false)
        #expect(bitmapsEqual(snapshot(bar), baseline))
    }
}

// MARK: - CrabPainter

@Suite
struct CrabPainterCoverageTests {
    @MainActor
    @Test func drawsTheBrandMarkAtVariousSizes() {
        for size: CGFloat in [0.5, 4, 16, 40] {
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                Tako.CrabPainter.draw(
                    in: CGRect(x: 0, y: 0, width: size, height: size),
                    color: .orange,
                    context: ctx)
            }
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
                Issue.record("could not rasterize the \(size)pt mark")
                continue
            }
            let hasColoredPixel = (0..<bitmap.pixelsWide).contains { x in
                (0..<bitmap.pixelsHigh).contains { y in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
                }
            }
            // step = floor(min(width/10, height/7)); for a square rect that's
            // floor(size/10), which only reaches 1 once size >= 10 -- below
            // that the early-return guard leaves the image blank.
            if size >= 10 {
                #expect(hasColoredPixel)
            } else {
                #expect(!hasColoredPixel)
            }
        }
    }
}
