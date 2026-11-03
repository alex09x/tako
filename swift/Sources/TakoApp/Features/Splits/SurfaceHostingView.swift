// tako — Native layout for a live terminal surface inside SwiftUI
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit

final class SurfaceHostingView: NSView {
    private(set) weak var surfaceView: Tako.SurfaceView?
    private var edges: [NSLayoutConstraint] = []

    init(surfaceView: Tako.SurfaceView) {
        super.init(frame: .zero)
        mount(surfaceView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @discardableResult
    func mount(_ surface: Tako.SurfaceView) -> Bool {
        // A stale update of the old SwiftUI slot must not reclaim a surface
        // that another slot has already mounted during a move.
        guard surfaceView !== surface else { return false }
        NSLayoutConstraint.deactivate(edges)
        // A previous SwiftUI slot can still exist after its surface has moved.
        // It must never remove that view from the new slot/window.
        if surfaceView?.superview === self { surfaceView?.removeFromSuperview() }
        surface.removeFromSuperview()
        surfaceView = surface
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        edges = [
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(edges)
        needsLayout = true
        return true
    }

    override func layout() {
        super.layout()
        if let surfaceView, surfaceView.superview === self { surfaceView.reflowToCurrentBounds() }
    }
}
