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
import SwiftUI
@testable import Tako

/// A surface the Core Animation status layer draws, put through states the
/// way the app puts it: a pill's layer as the tab bar drives it, a sidebar
/// row through the row view itself in a window.
@MainActor
final class MotionSurfaceHarness {
    let surface: MotionSpec.Surface
    let reduceMotion: Bool
    static let pillSize = CGSize(width: 140, height: 28)

    /// Set once a sidebar row showed no status layer where it must have one.
    private static var rowsDrawNoLayer = false

    private var pill: Tako.TabStatusLayer?
    private var pulses = 0
    private let model = RowModel()
    private var window: NSWindow?
    private var hosting: NSView?
    private var shown: Tako.SurfaceState?

    init(_ surface: MotionSpec.Surface, reduceMotion: Bool = false) {
        self.surface = surface
        self.reduceMotion = reduceMotion
    }

    deinit {
        MainActor.assumeIsolated { window?.close() }
    }

    /// The surface in `state`, as a change from what it showed, if anything.
    func show(_ state: Tako.SurfaceState, pulses: Int? = nil) {
        if let pulses { self.pulses = pulses }
        shown = state
        switch surface {
        case .pill:
            let layer = pill ?? Tako.TabStatusLayer()
            pill = layer
            layer.apply(state: state, in: CGRect(origin: .zero, size: Self.pillSize), hideRing: false,
                        reduceMotion: reduceMotion, paused: false, pulses: self.pulses)
        case .row, .paneSurface, .paneRing:
            model.item = Self.item(state, isChild: surface != .row, pulses: self.pulses)
            if window == nil { makeWindow() }
            hosting?.layoutSubtreeIfNeeded()
            // Rows that draw no layer at all fail every case at once rather
            // than each waiting its second out: hundreds of cases would keep
            // the gate from failing for minutes.
            guard !Self.rowsDrawNoLayer else { return }
            let settled = TerminalTestSupport.waitUntil(timeout: 1) { self.settled(on: state) }
            if !settled && hosts.isEmpty && surface != .paneSurface { Self.rowsDrawNoLayer = true }
        }
    }

    /// The layer whose effects the spec speaks of for this surface; nil for
    /// a pane row's border that is not drawn at all.
    var layer: Tako.TabStatusLayer? {
        switch surface {
        case .pill: return pill
        case .row, .paneSurface: return hosts.first { $0.statusLayer.drawsSurface }?.statusLayer
        case .paneRing: return hosts.first { !$0.statusLayer.drawsSurface }?.statusLayer
        }
    }

    /// The view the layer is hosted in, for a row.
    var hostView: StatusLayerHostView? {
        switch surface {
        case .pill: return nil
        case .row, .paneSurface: return hosts.first { $0.statusLayer.drawsSurface }
        case .paneRing: return hosts.first { !$0.statusLayer.drawsSurface }
        }
    }

    func effects() -> Set<MotionSpec.Effect> {
        guard let layer else { return [.ringHidden] }
        return StatusLayerInventory.effects(of: layer)
    }

    func close() {
        window?.close()
        window = nil
    }

    // MARK: -

    private final class RowModel: ObservableObject {
        @Published var item = MotionSurfaceHarness.item(.idle, isChild: false, pulses: 0)
    }

    private struct RowHost: View {
        @ObservedObject var model: RowModel
        let reduceMotion: Bool
        var body: some View {
            SessionSidebarRowView(item: model.item, index: 0, selectedIndex: -1, targetWindow: nil,
                                  editingItemId: .constant(nil), editingDescriptionText: .constant(""),
                                  isPresented: .constant(true), now: nil, reduceMotion: reduceMotion, onSelect: {})
                .frame(width: 280)
        }
    }

    private func makeWindow() {
        let view = NSHostingView(rootView: RowHost(model: model, reduceMotion: reduceMotion))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        self.window = window
        hosting = view
    }

    private var hosts: [StatusLayerHostView] {
        guard let hosting else { return [] }
        func walk(_ view: NSView) -> [StatusLayerHostView] {
            view.subviews.flatMap { ($0 as? StatusLayerHostView).map { [$0] } ?? walk($0) }
        }
        return walk(hosting)
    }

    /// Whether the row's layer has taken `state` -- or, for a pane row's
    /// border in a state it does not draw, has gone.
    private func settled(on state: Tako.SurfaceState) -> Bool {
        switch surface {
        case .pill: return true
        case .row, .paneRing: return layer?.currentState == state
        case .paneSurface:
            let drawn: Tako.SurfaceState? = (state == .working || state == .failed) ? state : nil
            return layer?.currentState == drawn
        }
    }

    /// A sidebar row's item in `state`.
    nonisolated static func item(_ state: Tako.SurfaceState, isChild: Bool, pulses: Int) -> SessionSidebarItem {
        var status: Tako.PaneStatus = .idle
        var progress: Double?
        var progressState: TakoTerminalNSView.ProgressState = .none
        var live: Tako.LiveActivity?
        switch state {
        case .idle: break
        case .working: status = .working
        case .progress(let p): status = .working; progress = p; progressState = .normal
        case .waiting: status = .needsApproval
        case .done: status = .done
        case .failed: status = .error
        case .offline: status = .disconnected
        case .live(let flowing):
            var activity = Tako.LiveActivity(program: "tail")
            activity.isFlowing = flowing
            activity.pulses = pulses
            live = activity
        }
        return SessionSidebarItem(id: "motion-row", index: 0, isSelected: false, title: "psql", status: status,
                                  progress: progress, progressState: progressState, live: live,
                                  workingDirectory: "/tmp", isChild: isChild, parentId: isChild ? UUID() : nil,
                                  indentationLevel: isChild ? 2 : 1, workspaceId: UUID(), tabId: "motion-tab")
    }
}
