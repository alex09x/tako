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
import Combine
import SwiftUI
import Testing
@testable import Tako

/// A live sidebar row's status runs on Core Animation, as a pill tab's does;
/// drawn by SwiftUI, every frame of it laid the window out again, and a few
/// working tabs stalled the whole sidebar. A snapshot's row, at its fixed
/// moment, is still drawn by SwiftUI.
@Suite(.serialized) @MainActor
struct SidebarLiveRowTests {
    private func row(_ status: Tako.PaneStatus, now: Date?) -> (NSWindow, NSView) {
        // Two lines: the title's, with the ring, and the directory's.
        let item = SessionSidebarItem(id: "live-row", index: 0, isSelected: false, title: "psql", status: status,
                                      workingDirectory: "/tmp", indentationLevel: 1, workspaceId: UUID(), tabId: "live-tab")
        let view = SessionSidebarRowView(item: item, index: 0, selectedIndex: -1, targetWindow: nil,
                                         editingItemId: .constant(nil), editingDescriptionText: .constant(""),
                                         isPresented: .constant(true), now: now, reduceMotion: false, onSelect: {})
        let hosting = NSHostingView(rootView: view.frame(width: 280))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private final class RowStatus: ObservableObject {
        @Published var status: Tako.PaneStatus
        init(_ status: Tako.PaneStatus) { self.status = status }
    }

    /// A live row whose status the test changes.
    private struct LiveRow: View {
        @ObservedObject var model: RowStatus
        var body: some View {
            SessionSidebarRowView(
                item: SessionSidebarItem(id: "live-row", index: 0, isSelected: false, title: "psql", status: model.status,
                                         workingDirectory: "/tmp", indentationLevel: 1, workspaceId: UUID(), tabId: "live-tab"),
                index: 0, selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil),
                editingDescriptionText: .constant(""), isPresented: .constant(true), now: nil, reduceMotion: false, onSelect: {})
            .frame(width: 280)
        }
    }

    private func layerViews(in view: NSView) -> [StatusLayerHostView] {
        view.subviews.flatMap { ($0 as? StatusLayerHostView).map { [$0] } ?? layerViews(in: $0) }
    }

    @Test func aLiveRowsStatusIsALayerWithItsRingInTheFirstLine() throws {
        let (window, hosting) = row(.working, now: nil)
        defer { window.close() }
        TerminalTestSupport.waitUntil(timeout: 1) { layerViews(in: hosting).first?.statusLayer.currentState != nil }
        let host = try #require(layerViews(in: hosting).first)
        #expect(host.statusLayer.currentState == .working)

        // The ring sits where the row keeps its place: past the chevron, on
        // the title's line -- the upper half of the row, the layer being y up.
        let ring = host.statusLayer.ringContainer.frame
        #expect(ring.size == CGSize(width: 14, height: 14))
        #expect((10...40).contains(ring.minX), "ring at x \(ring.minX)")
        #expect(ring.midY > host.bounds.height / 2, "ring at y \(ring.midY) of \(host.bounds.height)")
    }

    @Test func aSnapshotsRowIsDrawnBySwiftUI() {
        let (window, hosting) = row(.working, now: Date(timeIntervalSinceReferenceDate: 1))
        defer { window.close() }
        TerminalTestSupport.waitUntil(timeout: 0.2) { false }
        #expect(layerViews(in: hosting).isEmpty)
    }

    /// A working row has 1 pt more padding than a done one: the row's layer
    /// is resized, and its ring moved, in the same pass that makes it done.
    /// That pass rebuilt the ring and took the pop off before it was drawn.
    @Test func aRowThatFinishesKeepsItsPopThroughTheLayoutAfter() throws {
        let model = RowStatus(.working)
        let hosting = NSHostingView(rootView: LiveRow(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        TerminalTestSupport.waitUntil(timeout: 1) { layerViews(in: hosting).first?.statusLayer.currentState == .working }
        let host = try #require(layerViews(in: hosting).first)
        let working = host.bounds.size

        model.status = .done
        TerminalTestSupport.waitUntil(timeout: 1) { host.statusLayer.currentState == .done && host.bounds.size != working }
        hosting.layoutSubtreeIfNeeded()
        #expect(host.bounds.size != working, "the padding did not change: \(working)")
        #expect(host.statusLayer.ringContainer.animation(forKey: "donePop") != nil)
    }

    /// The "Needs you" ring is a pill's ring alone, scaled to its place; a
    /// pane row's border is the surface alone, its ring showing another state.
    @Test func aRingAloneAndASurfaceAlone() {
        func config(_ state: Tako.SurfaceState, drawsRing: Bool = true, ringOnly: CGFloat? = nil) -> StatusLayerHostView.Config {
            .init(state: state, ringCenter: nil, cornerRadius: 6, reduceMotion: false, paused: false, pulses: 0,
                  progressInset: 0, cometForProgress: false, drawsRing: drawsRing, ringOnly: ringOnly)
        }
        let header = StatusLayerHostView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        header.configure(config(.waiting, ringOnly: 10))
        #expect(header.statusLayer.currentState == .waiting)
        #expect(!header.statusLayer.drawsSurface)
        #expect(abs(header.statusLayer.transform.m11 - 10.0 / 14) < 0.001)
        #expect(header.statusLayer.frame.midX == 5 && header.statusLayer.frame.midY == 5)

        let pane = StatusLayerHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        pane.configure(config(.working, drawsRing: false))
        #expect(pane.statusLayer.currentState == .working)
        #expect(pane.statusLayer.drawsSurface)
        #expect(pane.statusLayer.ringContainer.isHidden)
    }

    /// A running command's clock, which no row shows, ticks twice a second;
    /// each tick drew every row of the sidebar again.
    @Test func aPanesClockTickIsNoChangeToItsRow() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        surface.selfTestCapturing = true
        defer { surface.close() }
        var changes = 0
        let watch = SessionSidebarStore.rowChanges(of: surface).sink { changes += 1 }
        defer { watch.cancel() }

        surface.crab.objectWillChange.send()
        surface.objectWillChange.send()
        TerminalTestSupport.waitUntil(timeout: 0.2) { false }
        #expect(changes == 0)

        surface.crab.setStatus(.working, text: nil)
        TerminalTestSupport.waitUntil(timeout: 1) { changes > 0 }
        #expect(changes == 1)

        // Focus picks a split tab's title, directory and chosen pane row.
        surface.focused.toggle()
        TerminalTestSupport.waitUntil(timeout: 1) { changes > 1 }
        #expect(changes == 2)
    }
}
