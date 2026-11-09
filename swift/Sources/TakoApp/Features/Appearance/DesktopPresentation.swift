/*
 * tako — Shared native desktop colors and presentation state
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine

struct DesktopPalette {
    let background: NSColor
    let panel: NSColor
    let raised: NSColor
    let hover: NSColor
    let field: NSColor
    let separator: NSColor
    let border: NSColor
    let text: NSColor
    let secondary: NSColor
    let muted: NSColor
    let popover: NSColor
    let popoverHover: NSColor
    let accent: NSColor
    let accentBright: NSColor
    /// Config-key captions under settings rows (reference `.pf-rl code`).
    let faint: NSColor
    /// Shadow under floating panels (settings, menus).
    let shadow: NSColor

    static let dark = DesktopPalette(
        background: color(0x100d0b), panel: color(0x231f1d), raised: color(0x2e2a27),
        hover: color(0x1a1715), field: color(0x120f0d), separator: color(0x24211e),
        border: color(0x312e2b), text: color(0xede6df), secondary: color(0xb1aba6),
        muted: color(0x8a8480), popover: color(0x241c16), popoverHover: color(0x30261e),
        accent: color(0xf4581c), accentBright: color(0xff7a3d),
        faint: color(0x686460), shadow: NSColor.black.withAlphaComponent(0.6))

    static let light = DesktopPalette(
        background: color(0xefede7), panel: color(0xeae7e2), raised: color(0xe1dfd9),
        hover: color(0xe5e3dd), field: color(0xf6f4ee), separator: color(0xd9d7d1),
        border: color(0xcdcbc5), text: color(0x262320), secondary: color(0x5c5a56),
        muted: color(0x807e7a), popover: color(0xffffff), popoverHover: color(0xeeeded),
        accent: color(0xf4581c), accentBright: color(0xff7a3d),
        faint: color(0x9f9c97), shadow: color(0x3c2814).withAlphaComponent(0.18))

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

enum DesktopMetrics {
    static let settingsWidth: CGFloat = 820
    static let settingsHeight: CGFloat = 700
    static let settingsSidebarWidth: CGFloat = 232
    static let navigationRowHeight: CGFloat = 32
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 7
    static let panelRadius: CGFloat = 12
    static let contentInset: CGFloat = 24
    static let footerHeight: CGFloat = 52
    static let bodyFontSize: CGFloat = 13
    static let titleFontSize: CGFloat = 17
}

/// Observes configuration and OS appearance, never PTY output. Consumers opt into
/// these colors without changing NSApplication.appearance or terminal theme state.
@MainActor
final class DesktopPresentation: ObservableObject {
    static let shared = DesktopPresentation()
    @Published private(set) var preferences = DesktopPreferences { _ in nil }
    @Published private(set) var isDark: Bool
    private var systemIsDark: Bool
    private var appearanceObservation: NSKeyValueObservation?
    private var configObserver: NSObjectProtocol?

    var palette: DesktopPalette { isDark ? .dark : .light }

    init(observe: Bool = true, systemIsDark: Bool? = nil) {
        let dark = systemIsDark ?? (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        self.systemIsDark = dark
        self.isDark = dark
        guard observe else { return }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Task { @MainActor [weak self] in self?.updateSystemAppearance(isDark: dark) }
        }
        configObserver = NotificationCenter.default.addObserver(forName: .takoConfigDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.object == nil,
                  let config = note.userInfo?[Notification.Name.TakoConfigChangeKey] as? Tako.Config else { return }
            MainActor.assumeIsolated { self?.configure(config) }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func configure(_ config: Tako.Config) {
        apply(config.desktopPreferences)
    }

    func apply(_ next: DesktopPreferences) {
        if preferences != next { preferences = next }
        if isPresenting { LivingAnimationState.shared.applyStatusPreferences(next) }
        resolveAppearance()
    }

    /// Only the shared instance drives process-wide state (tokens, status
    /// layers); a test's own instance stays local.
    private var isPresenting: Bool { self === Self.shared }

    func updateSystemAppearance(isDark: Bool) {
        systemIsDark = isDark
        resolveAppearance()
    }

    private func resolveAppearance() {
        let next = preferences.appearance.usesDarkColors(systemIsDark: systemIsDark)
        if isDark != next { isDark = next }
        // Also on the first resolve: an app that starts light must repaint.
        guard isPresenting, Tako.LivingTokens.isLight == next else { return }
        Tako.LivingTokens.isLight = !next
        Tako.TabBarController.refreshAll()
        NotificationCenter.default.post(name: .takoShellSchemeDidChange, object: nil)
    }
}
