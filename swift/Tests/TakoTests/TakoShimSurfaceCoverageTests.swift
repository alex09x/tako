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
import SwiftUI
import UniformTypeIdentifiers
import Testing
@testable import Tako

// Coverage for the two _TakoShim files this task's acceptance gate singles
// out as under the line-coverage floor: Tako+CrabView.swift's
// `CrabTabBinding` (the Combine glue between a surface's `CrabTracker` and
// its tab's progress label) and Tako+SurfaceUI.swift's SwiftUI plumbing
// (`SurfaceWrapper`, `InspectableSurface`, and the FocusedValues round trip).


/// Recursively searches a hosted SwiftUI view tree for `target`, the way
/// `NSHostingView` buries an `NSViewRepresentable`'s represented view a few
/// levels deep rather than as a direct subview.
@MainActor
private func containsView(_ root: NSView, _ target: NSView) -> Bool {
    if root === target { return true }
    for subview in root.subviews where containsView(subview, target) {
        return true
    }
    return false
}

// MARK: - CrabTabBinding

@Suite
@MainActor
struct CrabTabBindingCoverageTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                origin: NSScreen.main.map { NSPoint(x: $0.visibleFrame.minX + 40, y: $0.visibleFrame.minY + 40) } ?? .zero,
                size: NSSize(width: 200, height: 100)),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func initFailsWithoutAStackViewAccessory() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer { view.close() }
        let window = makeWindow()

        #expect(window.tab.accessoryView == nil)
        #expect(Tako.CrabTabBinding(surface: view, window: window) == nil)

        window.tab.accessoryView = NSView()
        #expect(Tako.CrabTabBinding(surface: view, window: window) == nil)
    }

    @Test func initInsertsTheProgressLabelAtTheHeadOfTheStack() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer { view.close() }
        let window = makeWindow()
        let stack = NSStackView()
        stack.addArrangedSubview(NSView()) // Stands in for upstream's key-equivalent label.
        window.tab.accessoryView = stack

        let binding = Tako.CrabTabBinding(surface: view, window: window)
        #expect(binding != nil)
        #expect(stack.arrangedSubviews.count == 2)
        #expect(stack.arrangedSubviews[0] is NSTextField)
        #expect(stack.arrangedSubviews[0].identifier == Tako.CrabTabBinding.labelIdentifier)
    }

    @Test func reInitOnTheSameStackRemovesThePreviousLabel() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer { view.close() }
        let window = makeWindow()
        let stack = NSStackView()
        window.tab.accessoryView = stack

        let first = Tako.CrabTabBinding(surface: view, window: window)
        #expect(first != nil)
        let second = Tako.CrabTabBinding(surface: view, window: window)
        #expect(second != nil)
        // The stale label from `first` is removed before `second`'s is
        // inserted, so the stack never collects one per call.
        #expect(stack.arrangedSubviews.filter { $0.identifier == Tako.CrabTabBinding.labelIdentifier }.count == 1)
    }

    @Test func progressReportedUpdatesTheLabelAndHidesWhenCleared() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer { view.close() }
        let window = makeWindow()
        let stack = NSStackView()
        window.tab.accessoryView = stack

        let binding = Tako.CrabTabBinding(surface: view, window: window)
        #expect(binding != nil)
        guard let label = stack.arrangedSubviews.first as? NSTextField else {
            Issue.record("expected the progress label at index 0")
            return
        }

        // Nothing running yet: the label starts hidden.
        #expect(waitUntil { label.isHidden })

        view.crab.progressReported(state: 1, value: 42)
        #expect(waitUntil { label.stringValue == "42%" })
        #expect(!label.isHidden)

        view.crab.progressReported(state: 0, value: nil)
        #expect(waitUntil { label.stringValue.isEmpty })
        #expect(label.isHidden)
    }
}

// MARK: - SurfaceUI

@Suite
@MainActor
struct SurfaceWrapperCoverageTests {
    @Test func surfaceWrapperHostsTheExactSurfaceView() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        defer { surfaceView.close() }
        let wrapper = Tako.SurfaceWrapper(surfaceView: surfaceView, isSplit: true)

        let hosting = NSHostingView(rootView: wrapper)
        hosting.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hosting.layout()

        #expect(containsView(hosting, surfaceView))
    }


    /// A dragged surface travels as its identifier, not as a copy of itself.
    @available(macOS 15.2, *)
    @Test func aDraggedSurfaceExportsItsIdentifierAsText() async throws {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        defer { surface.close() }
        let data = try await surface.exported(as: .utf8PlainText)
        #expect(String(decoding: data, as: UTF8.self) == String(describing: surface.id))
    }

    /// `FocusedValues` has no publicly accessible initializer to construct
    /// one directly in a test. Hosting a real `@FocusedValue` reader
    /// alongside the `InspectableSurface` at least proves the whole chain
    /// -- `body`'s `.focusedValue` calls and the FocusedValues get/set pair
    /// they route through -- builds and renders without crashing.
    @Test func focusedValueReaderHostsAlongsideInspectableSurfaceWithoutCrashing() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        defer { surfaceView.close() }

        struct Reader: View {
            @FocusedValue(\.takoSurfaceView) var focusedSurface
            @FocusedValue(\.takoSurfacePwd) var focusedPwd
            @FocusedValue(\.takoSurfaceCellSize) var focusedCellSize
            var body: some View { Color.clear }
        }

        let inspectable = Tako.InspectableSurface(surfaceView: surfaceView)
        let hosting = NSHostingView(rootView: VStack { inspectable; Reader() })
        hosting.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hosting.layout()

        #expect(containsView(hosting, surfaceView))
    }
}
