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

/// A sidebar row's status drawn as a pill tab's is: the same Core Animation
/// layers -- ring, comet or breathing border, waiting glow, done glint and
/// pop, progress line -- run by the render server, not by SwiftUI frames.
/// Drawn by SwiftUI, every frame of a spinning ring laid out the window
/// again: one working row kept a third of a core busy, and five working
/// tabs stalled every row in the sidebar for 75-140 ms at a time.
struct SidebarStatusLayerView: NSViewRepresentable {
    let state: Tako.SurfaceState
    /// The ring's centre in the row's own coordinates (y down); nil centres it.
    let ringCenter: CGPoint?
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    let paused: Bool
    let pulses: Int
    /// The progress line's inset from each side; a row in progress runs the comet too.
    var progressInset: CGFloat = 0
    var cometForProgress = false
    /// False draws the surface alone: a pane row's ring shows another state.
    var drawsRing = true
    /// The ring alone, drawn this many points across (a pill's ring is 14).
    var ringOnly: CGFloat? = nil
    /// `status-show` / `status-animate`, read when the row is built so a
    /// change re-renders it (the sidebar observes LivingAnimationState).
    var statusShown = LivingAnimationState.shared.statusShown
    var statusAnimates = LivingAnimationState.shared.statusAnimates
    var palette: Tako.TabStatusPalette? = nil
    /// The panes whose bursts ripple the ring, watched by the layer itself.
    var pulseSources: Set<UUID> = []

    func makeNSView(context: Context) -> StatusLayerHostView {
        StatusLayerHostView()
    }

    func updateNSView(_ view: StatusLayerHostView, context: Context) {
        view.watchPulses(of: pulseSources)
        view.configure(.init(state: statusShown ? state : .idle, ringCenter: ringCenter, cornerRadius: cornerRadius,
                             reduceMotion: reduceMotion || !statusAnimates, paused: paused, pulses: statusShown ? pulses : 0,
                             progressInset: progressInset, cometForProgress: cometForProgress,
                              drawsRing: drawsRing, ringOnly: ringOnly, palette: palette))
    }
}

/// Hosts a `Tako.TabStatusLayer` over a sidebar row; clicks pass through to the row.
final class StatusLayerHostView: NSView {
    struct Config: Equatable {
        var state: Tako.SurfaceState
        var ringCenter: CGPoint?
        var cornerRadius: CGFloat
        var reduceMotion: Bool
        var paused: Bool
        var pulses: Int
        var progressInset: CGFloat
        var cometForProgress: Bool
        var drawsRing: Bool
        var ringOnly: CGFloat?
        var palette: Tako.TabStatusPalette? = nil
    }

    let statusLayer = Tako.TabStatusLayer()
    private var config: Config?
    private struct WeakCrab { weak var crab: Tako.CrabTracker? }
    private var pulseSources: Set<UUID> = []
    private var pulseCrabs: [WeakCrab] = []
    private var pulseWatch: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(statusLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        apply()
    }

    func configure(_ new: Config) {
        guard new != config else { return }
        config = new
        apply()
    }

    /// Ripples the ring for each burst of these panes' output, without
    /// SwiftUI: a burst comes every second a stream prints, and a row rebuilt
    /// for it rebuilt the whole sidebar.
    func watchPulses(of ids: Set<UUID>) {
        guard ids != pulseSources else { return }
        pulseSources = ids
        let surfaces = ids.isEmpty ? [] : TerminalController.all.flatMap { Array($0.surfaceTree) }
        watchPulses(of: surfaces.filter { ids.contains($0.id) }.map(\.crab))
    }

    /// Internal so a test can hand it trackers of panes in no window.
    func watchPulses(of crabs: [Tako.CrabTracker]) {
        pulseCrabs = crabs.map { WeakCrab(crab: $0) }
        pulseWatch = crabs.isEmpty ? nil : Publishers.MergeMany(crabs.map { $0.$live.dropFirst().map { _ in () } })
            // On the next turn: a publisher fires before the value is set.
            .receive(on: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.pulsed() } }
    }

    /// The watched panes' bursts, nil when none are watched.
    private var watchedPulses: Int? {
        let crabs = pulseCrabs.compactMap(\.crab)
        return crabs.isEmpty ? nil : crabs.reduce(0) { $0 &+ ($1.live?.pulses ?? 0) }
    }

    private func pulsed() {
        // A row that is not flowing yet keeps the burst: the change that
        // makes it flow ripples it, as it did when both came together.
        guard let config, config.state == .live(flowing: true), let pulses = watchedPulses else { return }
        statusLayer.rippleIfPulsed(pulses, state: config.state, reduceMotion: config.reduceMotion, paused: config.paused)
    }

    private func apply() {
        guard let config, bounds.width > 0, bounds.height > 0 else { return }
        // The row's own count is the one it was built with, seconds old. A
        // row laid out before it knows its stream flows keeps the burst for
        // the change that makes it flow.
        let pulses = watchedPulses.map { config.state == .live(flowing: true) ? $0 : statusLayer.lastPulses }
            ?? config.pulses
        if let side = config.ringOnly {
            // A pill's 14 pt ring, centred and scaled to `side`.
            statusLayer.drawsSurface = false
            statusLayer.geometry = .init(cornerRadius: 0, ringOrigin: .zero)
            let ring = CGRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
            statusLayer.apply(state: config.state, in: ring, hideRing: false, reduceMotion: config.reduceMotion,
                              paused: config.paused, pulses: pulses, palette: config.palette)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            statusLayer.transform = CATransform3DMakeScale(side / 14, side / 14, 1)
            CATransaction.commit()
            return
        }
        // The layer is y up; SwiftUI gave the ring's centre y down.
        statusLayer.geometry = .init(
            cornerRadius: config.cornerRadius,
            ringOrigin: config.ringCenter.map { CGPoint(x: ($0.x - 7).rounded(), y: (bounds.height - $0.y - 7).rounded()) },
            progressInset: config.progressInset,
            cometForProgress: config.cometForProgress)
        statusLayer.apply(state: config.state, in: bounds, hideRing: !config.drawsRing, reduceMotion: config.reduceMotion,
                          paused: config.paused, pulses: pulses, palette: config.palette)
    }
}

/// Where a row's ring sits, for the layer drawn over the row.
struct SidebarRingAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
