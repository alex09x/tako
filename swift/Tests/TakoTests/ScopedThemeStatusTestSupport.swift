/*
 * tako — Scoped status palette rendering fixtures
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import QuartzCore
@testable import Tako

@MainActor extension ScopedThemeStatusColorTests {
    func makeWindow(title: String) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = title
        return win
    }

    func mount(_ bar: Tako.TabBarView, in window: NSWindow) {
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        window.contentView?.addSubview(bar)
    }

    func attachSurface(to window: NSWindow) -> Tako.SurfaceView {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(surface)
        return surface
    }

    func drawBar(_ bar: Tako.TabBarView) {
        bar.layoutTabs()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) { bar.cacheDisplay(in: bar.bounds, to: rep) }
    }

    func hex(for cgColor: CGColor?) -> String? {
        guard let cgColor, let nsColor = NSColor(cgColor: cgColor) else { return nil }
        return Tako.Brand.hexString(for: nsColor)
    }

    func findShapes(in layer: CALayer) -> [CAShapeLayer] {
        var result: [CAShapeLayer] = []
        if let shape = layer as? CAShapeLayer { result.append(shape) }
        for sub in layer.sublayers ?? [] { result.append(contentsOf: findShapes(in: sub)) }
        return result
    }

    func findGradients(in layer: CALayer) -> [CAGradientLayer] {
        var result: [CAGradientLayer] = []
        if let grad = layer as? CAGradientLayer { result.append(grad) }
        for sub in layer.sublayers ?? [] { result.append(contentsOf: findGradients(in: sub)) }
        return result
    }

    func makeTheme(working: String, waiting: String, done: String, error: String, idle: String) -> TerminalTheme {
        var theme = TerminalTheme.takoDefault
        theme.tabStatusColors["working"] = TerminalTheme.parseColor(working)
        theme.tabStatusColors["waiting"] = TerminalTheme.parseColor(waiting)
        theme.tabStatusColors["done"] = TerminalTheme.parseColor(done)
        theme.tabStatusColors["error"] = TerminalTheme.parseColor(error)
        theme.tabStatusColors["idle"] = TerminalTheme.parseColor(idle)
        return theme
    }
}
