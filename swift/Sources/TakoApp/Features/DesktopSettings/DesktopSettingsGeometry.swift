/*
 * tako — Centered, host-bounded geometry for the native settings window
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// Settings are 820×700 at most, never closer than 24 pt to any host edge,
/// and always centered on the host content, whatever its size.
enum DesktopSettingsGeometry {
    static let margin: CGFloat = DesktopMetrics.contentInset
    /// Below this width the sidebar collapses to a section menu.
    static let compactWidth: CGFloat = 640

    static func frame(in host: CGRect) -> CGRect {
        let width = max(0, min(DesktopMetrics.settingsWidth, host.width - margin * 2))
        let height = max(0, min(DesktopMetrics.settingsHeight, host.height - margin * 2))
        let x = (host.minX + (host.width - width) / 2).rounded(.down)
        let y = (host.minY + (host.height - height) / 2).rounded(.down)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func isCompact(_ size: CGSize) -> Bool { size.width < compactWidth }
}
