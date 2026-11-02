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
import QuartzCore
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct ScopedThemeStatusColorTests {

    private func makeWindow(title: String) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = title
        return win
    }

    private func mount(_ bar: Tako.TabBarView, in window: NSWindow) {
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        window.contentView?.addSubview(bar)
    }

    private func attachSurface(to window: NSWindow) -> Tako.SurfaceView {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(surface)
        return surface
    }

    private func drawBar(_ bar: Tako.TabBarView) {
        bar.layoutTabs()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
        }
    }

    private func hex(for cgColor: CGColor?) -> String? {
        guard let cgColor, let nsColor = NSColor(cgColor: cgColor) else { return nil }
        return Tako.Brand.hexString(for: nsColor)
    }

    private func findShapes(in layer: CALayer) -> [CAShapeLayer] {
        var result: [CAShapeLayer] = []
        if let shape = layer as? CAShapeLayer {
            result.append(shape)
        }
        for sub in layer.sublayers ?? [] {
            result.append(contentsOf: findShapes(in: sub))
        }
        return result
    }

    private func findGradients(in layer: CALayer) -> [CAGradientLayer] {
        var result: [CAGradientLayer] = []
        if let grad = layer as? CAGradientLayer {
            result.append(grad)
        }
        for sub in layer.sublayers ?? [] {
            result.append(contentsOf: findGradients(in: sub))
        }
        return result
    }

    private func makeTheme(working: String, waiting: String, done: String, error: String, idle: String) -> TerminalTheme {
        var theme = TerminalTheme.takoDefault
        theme.tabStatusColors["working"] = TerminalTheme.parseColor(working)
        theme.tabStatusColors["waiting"] = TerminalTheme.parseColor(waiting)
        theme.tabStatusColors["done"] = TerminalTheme.parseColor(done)
        theme.tabStatusColors["error"] = TerminalTheme.parseColor(error)
        theme.tabStatusColors["idle"] = TerminalTheme.parseColor(idle)
        return theme
    }

    @Test func independentSurfacesAndWindowsRetainDistinctCAColorsAndTabReports() throws {
        let prevOverride = Tako.overrideTabStatusTheme
        defer { Tako.overrideTabStatusTheme = prevOverride }
        Tako.overrideTabStatusTheme = nil

        let winA = makeWindow(title: "win-a")
        let winB = makeWindow(title: "win-b")
        defer {
            Tako.CustomTabGroup.leave(winA)
            Tako.CustomTabGroup.leave(winB)
        }

        let surfA = attachSurface(to: winA)
        let surfB = attachSurface(to: winB)
        defer {
            surfA.removeFromSuperview()
            surfB.removeFromSuperview()
        }

        let barA = Tako.TabBarView(frame: .zero)
        mount(barA, in: winA)
        defer { barA.removeFromSuperview() }

        let barB = Tako.TabBarView(frame: .zero)
        mount(barB, in: winB)
        defer { barB.removeFromSuperview() }

        let themeA = makeTheme(working: "#ff1122", waiting: "#ffaa11", done: "#11ee22", error: "#ee1155", idle: "#445566")
        let themeB = makeTheme(working: "#2233ff", waiting: "#ffdd00", done: "#00bbcc", error: "#bb0022", idle: "#778899")

        surfA.applyTheme(themeA)
        surfB.applyTheme(themeB)

        surfA.crab.isFocused = false
        surfB.crab.isFocused = false

        // 1. Test Window A across all 5 states, verifying both reports and retained CA layers
        let statesA: [(status: Tako.PaneStatus, dot: String, expectedHex: String)] = [
            (.working, "ember", "#ff1122"),
            (.waitingForInput, "claw", "#ffaa11"),
            (.done, "ok", "#11ee22"),
            (.error, "error", "#ee1155"),
            (.idle, "dim", "#445566"),
        ]

        for entry in statesA {
            surfA.crab.setStatus(entry.status, text: "test-\(entry.dot)")

            let reportA = Tako.tabVisualStatus(for: winA)
            #expect(reportA.dot == entry.dot)
            #expect(reportA.hex == entry.expectedHex)
            #expect(reportA.color == entry.expectedHex)

            drawBar(barA)
            let tabA = try #require(barA.tabs.first)
            #expect(Tako.Brand.hexString(for: barA.pillIndicatorColor(for: tabA)) == entry.expectedHex)

            let statusLayerA = try #require(barA.statusLayers[ObjectIdentifier(winA)])

            switch entry.status {
            case .working:
                let grad = try #require(findGradients(in: statusLayerA.ringContainer).first { $0.name == "workingSpin" })
                let gradHexes = (grad.colors as? [CGColor] ?? []).compactMap { hex(for: $0) }
                #expect(gradHexes.contains(entry.expectedHex))
                let bgCircle = try #require(findShapes(in: statusLayerA.ringContainer).first { $0.strokeColor != nil && $0.fillColor == nil })
                #expect(hex(for: bgCircle.strokeColor) == entry.expectedHex)

            case .waitingForInput:
                let dot = try #require(findShapes(in: statusLayerA.ringContainer).first { $0.name == "waitingDot" })
                #expect(hex(for: dot.fillColor) == entry.expectedHex)
                let ring = try #require(findShapes(in: statusLayerA.ringContainer).first { $0.strokeColor != nil && $0.fillColor == nil })
                #expect(hex(for: ring.strokeColor) == entry.expectedHex)
                if let breathe = statusLayerA.named(Tako.TabStatusLayer.LayerName.breathe) as? CAShapeLayer {
                    #expect(hex(for: breathe.strokeColor) == entry.expectedHex)
                }
                if let glow = statusLayerA.named(Tako.TabStatusLayer.LayerName.breatheGlowShadow) as? CAShapeLayer {
                    #expect(hex(for: glow.shadowColor) == entry.expectedHex)
                }

            case .done:
                let disc = try #require(findShapes(in: statusLayerA.ringContainer).first { $0.fillColor != nil && $0.strokeColor == nil })
                #expect(hex(for: disc.fillColor) == entry.expectedHex)

            case .error:
                let disc = try #require(findShapes(in: statusLayerA.ringContainer).first { $0.fillColor != nil && $0.strokeColor == nil })
                #expect(hex(for: disc.fillColor) == entry.expectedHex)
                if let line = statusLayerA.named(Tako.TabStatusLayer.LayerName.failedLine) as? CAShapeLayer {
                    #expect(hex(for: line.fillColor) == entry.expectedHex)
                }

            case .idle:
                let ring = try #require(findShapes(in: statusLayerA.ringContainer).first { $0.strokeColor != nil && $0.fillColor == nil })
                #expect(hex(for: ring.strokeColor) == entry.expectedHex)

            default:
                break
            }
        }

        // 2. Test Window B retains Theme B colors independently
        surfB.crab.setStatus(.working, text: "win-b-work")
        let reportB = Tako.tabVisualStatus(for: winB)
        #expect(reportB.dot == "ember")
        #expect(reportB.hex == "#2233ff")

        drawBar(barB)
        let tabB = try #require(barB.tabs.first)
        #expect(Tako.Brand.hexString(for: barB.pillIndicatorColor(for: tabB)) == "#2233ff")

        let statusLayerB = try #require(barB.statusLayers[ObjectIdentifier(winB)])
        let gradB = try #require(findGradients(in: statusLayerB.ringContainer).first { $0.name == "workingSpin" })
        let gradHexesB = (gradB.colors as? [CGColor] ?? []).compactMap { hex(for: $0) }
        #expect(gradHexesB.contains("#2233ff"))
        #expect(!gradHexesB.contains("#ff1122"))
    }

    @Test func liveThemePresetPreviewAndCancelUpdatesAndRestoresCALayerColors() throws {
        let prevOverride = Tako.overrideTabStatusTheme
        defer { Tako.overrideTabStatusTheme = prevOverride }
        Tako.overrideTabStatusTheme = nil

        let window = makeWindow(title: "preview-cancel-win")
        defer { Tako.CustomTabGroup.leave(window) }

        let surface = attachSurface(to: window)
        defer { surface.removeFromSuperview() }

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        defer { bar.removeFromSuperview() }

        surface.crab.isFocused = false
        surface.crab.setStatus(.working, text: "working-preview")

        // Initial default theme
        drawBar(bar)
        let initialReport = Tako.tabVisualStatus(for: window)
        #expect(initialReport.dot == "ember")
        #expect(initialReport.hex == Tako.Brand.hex(for: "ember"))
        #expect(initialReport.color == "orange")

        let statusLayer = try #require(bar.statusLayers[ObjectIdentifier(window)])
        let initialGrad = try #require(findGradients(in: statusLayer.ringContainer).first { $0.name == "workingSpin" })
        let initialHexes = (initialGrad.colors as? [CGColor] ?? []).compactMap { hex(for: $0) }
        #expect(initialHexes.contains(Tako.Brand.hex(for: "ember")))

        // Set up ThemePresetPreview
        let dialog = TerminalSettingsDialog(style: .from(nil))
        let preview = ThemePresetPreview(owner: dialog, targets: [surface])

        let draft = makeTheme(working: "#ff8800", waiting: "#ffcc00", done: "#00dd66", error: "#ee1133", idle: "#667788")

        // 1. Preview Apply
        preview.apply(draft)
        drawBar(bar)

        let previewReport = Tako.tabVisualStatus(for: window)
        #expect(previewReport.dot == "ember")
        #expect(previewReport.hex == "#ff8800")
        #expect(previewReport.color == "#ff8800")

        let tab = try #require(bar.tabs.first)
        #expect(Tako.Brand.hexString(for: bar.pillIndicatorColor(for: tab)) == "#ff8800")

        let previewGrad = try #require(findGradients(in: statusLayer.ringContainer).first { $0.name == "workingSpin" })
        let previewHexes = (previewGrad.colors as? [CGColor] ?? []).compactMap { hex(for: $0) }
        #expect(previewHexes.contains("#ff8800"))

        // 2. Preview Cancel / Restore
        preview.restore()
        drawBar(bar)

        let restoredReport = Tako.tabVisualStatus(for: window)
        #expect(restoredReport.dot == "ember")
        #expect(restoredReport.hex == Tako.Brand.hex(for: "ember"))
        #expect(restoredReport.color == "orange")

        #expect(Tako.Brand.hexString(for: bar.pillIndicatorColor(for: tab)) == Tako.Brand.hex(for: "ember"))

        let restoredGrad = try #require(findGradients(in: statusLayer.ringContainer).first { $0.name == "workingSpin" })
        let restoredHexes = (restoredGrad.colors as? [CGColor] ?? []).compactMap { hex(for: $0) }
        #expect(restoredHexes.contains(Tako.Brand.hex(for: "ember")))
        #expect(!restoredHexes.contains("#ff8800"))
    }

    @Test func overridingAndRemovingStatusPaletteOnUnchangedStateUpdatesRetainedCALayers() throws {
        let prevOverride = Tako.overrideTabStatusTheme
        defer { Tako.overrideTabStatusTheme = prevOverride }
        Tako.overrideTabStatusTheme = nil

        let window = makeWindow(title: "unchanged-state-win")
        defer { Tako.CustomTabGroup.leave(window) }

        let surface = attachSurface(to: window)
        defer { surface.removeFromSuperview() }

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        defer { bar.removeFromSuperview() }

        surface.crab.isFocused = false

        // Keep state constant at .waiting throughout override application and removal
        surface.crab.setStatus(.waitingForInput, text: "waiting-unchanged")

        drawBar(bar)
        let initialReport = Tako.tabVisualStatus(for: window)
        #expect(initialReport.dot == "claw")
        #expect(initialReport.hex == Tako.Brand.hex(for: "claw"))
        #expect(initialReport.color == "amber")

        let statusLayer = try #require(bar.statusLayers[ObjectIdentifier(window)])
        let initialDot = try #require(findShapes(in: statusLayer.ringContainer).first { $0.name == "waitingDot" })
        #expect(hex(for: initialDot.fillColor) == Tako.Brand.hex(for: "claw"))

        // Apply override with custom waiting color
        let customTheme = makeTheme(working: "#ff8800", waiting: "#ffcc00", done: "#00dd66", error: "#ee1133", idle: "#667788")
        surface.applyTheme(customTheme)
        drawBar(bar)

        let overriddenReport = Tako.tabVisualStatus(for: window)
        #expect(overriddenReport.dot == "claw")
        #expect(overriddenReport.hex == "#ffcc00")
        #expect(overriddenReport.color == "#ffcc00")

        let overriddenDot = try #require(findShapes(in: statusLayer.ringContainer).first { $0.name == "waitingDot" })
        #expect(hex(for: overriddenDot.fillColor) == "#ffcc00")

        if let breathe = statusLayer.named(Tako.TabStatusLayer.LayerName.breathe) as? CAShapeLayer {
            #expect(hex(for: breathe.strokeColor) == "#ffcc00")
        }
        if let glow = statusLayer.named(Tako.TabStatusLayer.LayerName.breatheGlowShadow) as? CAShapeLayer {
            #expect(hex(for: glow.shadowColor) == "#ffcc00")
        }

        // Remove override back to default theme
        surface.applyTheme(.takoDefault)
        drawBar(bar)

        let revertedReport = Tako.tabVisualStatus(for: window)
        #expect(revertedReport.dot == "claw")
        #expect(revertedReport.hex == Tako.Brand.hex(for: "claw"))
        #expect(revertedReport.color == "amber")

        let revertedDot = try #require(findShapes(in: statusLayer.ringContainer).first { $0.name == "waitingDot" })
        #expect(hex(for: revertedDot.fillColor) == Tako.Brand.hex(for: "claw"))

        // Also test .done on unchanged state
        surface.crab.setStatus(.done, text: "done-unchanged")
        drawBar(bar)
        let doneReport1 = Tako.tabVisualStatus(for: window)
        #expect(doneReport1.dot == "ok")
        #expect(doneReport1.hex == Tako.Brand.hex(for: "ok"))

        let disc1 = try #require(findShapes(in: statusLayer.ringContainer).first { $0.fillColor != nil && $0.strokeColor == nil })
        #expect(hex(for: disc1.fillColor) == Tako.Brand.hex(for: "ok"))

        // Override done color
        surface.applyTheme(customTheme)
        drawBar(bar)
        let doneReport2 = Tako.tabVisualStatus(for: window)
        #expect(doneReport2.hex == "#00dd66")
        let disc2 = try #require(findShapes(in: statusLayer.ringContainer).first { $0.fillColor != nil && $0.strokeColor == nil })
        #expect(hex(for: disc2.fillColor) == "#00dd66")

        // Remove override
        surface.applyTheme(.takoDefault)
        drawBar(bar)
        let doneReport3 = Tako.tabVisualStatus(for: window)
        #expect(doneReport3.hex == Tako.Brand.hex(for: "ok"))
        let disc3 = try #require(findShapes(in: statusLayer.ringContainer).first { $0.fillColor != nil && $0.strokeColor == nil })
        #expect(hex(for: disc3.fillColor) == Tako.Brand.hex(for: "ok"))
    }

    @Test func multiPaneContributingSurfaceSelectsCorrectTabPalette() throws {
        let prevOverride = Tako.overrideTabStatusTheme
        defer { Tako.overrideTabStatusTheme = prevOverride }
        Tako.overrideTabStatusTheme = nil

        let window = makeWindow(title: "multipane-win")
        defer { Tako.CustomTabGroup.leave(window) }

        let pane1 = attachSurface(to: window)
        let pane2 = attachSurface(to: window)
        defer {
            pane1.removeFromSuperview()
            pane2.removeFromSuperview()
        }

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        defer { bar.removeFromSuperview() }

        let theme1 = makeTheme(working: "#ff0011", waiting: "#ffaa00", done: "#11aa22", error: "#ee0033", idle: "#334455")
        let theme2 = makeTheme(working: "#0011ff", waiting: "#00ff22", done: "#00bbcc", error: "#cc0011", idle: "#667788")

        pane1.applyTheme(theme1)
        pane2.applyTheme(theme2)

        pane1.crab.isFocused = false
        pane2.crab.isFocused = false

        // Pane 1 working, Pane 2 idle -> Pane 1 contributes aggregate state and palette
        pane1.crab.setStatus(.working, text: "p1-working")
        pane2.crab.setStatus(.idle, text: nil)

        let report1 = Tako.tabVisualStatus(for: window)
        #expect(report1.dot == "ember")
        #expect(report1.hex == "#ff0011")

        drawBar(bar)
        let statusLayer = try #require(bar.statusLayers[ObjectIdentifier(window)])
        let grad = try #require(findGradients(in: statusLayer.ringContainer).first { $0.name == "workingSpin" })
        let gradHexes = (grad.colors as? [CGColor] ?? []).compactMap { hex(for: $0) }
        #expect(gradHexes.contains("#ff0011"))

        // Pane 2 waiting (priority 5 > 4) -> Pane 2 contributes aggregate state and palette
        pane2.crab.setStatus(.waitingForInput, text: "p2-waiting")

        let report2 = Tako.tabVisualStatus(for: window)
        #expect(report2.dot == "claw")
        #expect(report2.hex == "#00ff22")

        drawBar(bar)
        let dot = try #require(findShapes(in: statusLayer.ringContainer).first { $0.name == "waitingDot" })
        #expect(hex(for: dot.fillColor) == "#00ff22")
    }
}
