/*
 * tako — Centered, host-bounded geometry for the native settings window
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// The frozen reference's placeSet (desktop-reference prefs-detail.js):
/// width min(820, host − 24), height min(700, max(320, host − 24)), centred,
/// so 12 pt per side; the top never comes closer than 12 pt. Only a host
/// under 344 pt tall lets the 320 pt minimum run past the bottom edge.
enum DesktopSettingsGeometry {
    /// Total inset per axis: 12 pt on each side.
    static let inset: CGFloat = 24
    static let minimumHeight: CGFloat = 320
    /// Below this width the sidebar collapses to a section menu.
    static let compactWidth: CGFloat = 640

    /// `host` is in an unflipped view (origin bottom-left), like the overlay.
    static func frame(in host: CGRect) -> CGRect {
        let width = max(0, min(DesktopMetrics.settingsWidth, host.width - inset))
        let height = min(DesktopMetrics.settingsHeight, max(minimumHeight, host.height - inset))
        let x = (host.minX + (host.width - width) / 2).rounded()
        let top = max(inset / 2, (host.height - height) / 2).rounded()
        return CGRect(x: x, y: host.maxY - top - height, width: width, height: height)
    }

    static func isCompact(_ size: CGSize) -> Bool { size.width < compactWidth }
}
