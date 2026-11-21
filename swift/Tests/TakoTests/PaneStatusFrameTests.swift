/*
 * tako — Real terminal frames follow presentation settings without losing status
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@MainActor @Suite(.serialized)
struct PaneStatusFrameTests {
    @Test func actualPaneFrameDrawsItsStatusAndHidesOnlyPresentation() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1280, height: 700))
        controller.showWindow(nil)
        let surface = try #require(controller.focusedSurface)
        let content = try #require(window.contentView)
        let previous = DesktopPresentation.shared.preferences
        defer { LivingAnimationState.shared.applyStatusPreferences(previous) }
        LivingAnimationState.shared.applyStatusPreferences(DesktopPreferences { _ in nil })
        surface.crab.setStatus(.working, text: "working")
        func settle() { content.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)); content.layoutSubtreeIfNeeded() }
        settle()
        func hosts(_ root: NSView) -> [StatusLayerHostView] {
            root.subviews.flatMap { ($0 as? StatusLayerHostView).map { [$0] } ?? hosts($0) }
        }
        let frame = try #require(hosts(content).first { $0.bounds.width > 260 && $0.statusLayer.ringContainer.isHidden })
        #expect(frame.statusLayer.currentState == .working)
        #expect(frame.statusLayer.currentPalette == Tako.tabStatusPalette(surface: surface))
        LivingAnimationState.shared.applyStatusPreferences(DesktopPreferences { $0 == "status-show" ? "false" : nil })
        settle()
        #expect(frame.statusLayer.currentState == .idle)
        #expect(surface.crab.paneStatus == .working)
    }
}
