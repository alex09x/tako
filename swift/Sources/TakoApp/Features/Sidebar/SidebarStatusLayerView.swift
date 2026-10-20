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

    func makeNSView(context: Context) -> StatusLayerHostView {
        StatusLayerHostView()
    }

    func updateNSView(_ view: StatusLayerHostView, context: Context) {
        view.configure(.init(state: state, ringCenter: ringCenter, cornerRadius: cornerRadius,
                             reduceMotion: reduceMotion, paused: paused, pulses: pulses,
                             progressInset: progressInset, cometForProgress: cometForProgress,
                             drawsRing: drawsRing, ringOnly: ringOnly))
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
    }

    let statusLayer = Tako.TabStatusLayer()
    private var config: Config?

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

    private func apply() {
        guard let config, bounds.width > 0, bounds.height > 0 else { return }
        if let side = config.ringOnly {
            // A pill's 14 pt ring, centred and scaled to `side`.
            statusLayer.drawsSurface = false
            statusLayer.geometry = .init(cornerRadius: 0, ringOrigin: .zero)
            let ring = CGRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
            statusLayer.apply(state: config.state, in: ring, hideRing: false, reduceMotion: config.reduceMotion,
                              paused: config.paused, pulses: config.pulses)
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
                          paused: config.paused, pulses: config.pulses)
    }
}

/// Where a row's ring sits, for the layer drawn over the row.
struct SidebarRingAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
