/*
 * tako — Logical panes of a background tab before its first presentation
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct BackgroundTabMetadataTests {
    @Test func aNormalBackgroundTabKeepsItsPanesBeforeTheyAreMounted() throws {
        let fixture = try PrivateSurfaceFixture()
        defer { fixture.cleanUp() }
        let surface = fixture.surface()
        let (controller, window) = TerminalTestSupport.makeController(baseConfig: fixture.configuration,
                                                                    surfaceTree: .init(view: surface))
        window.windowController = controller
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(window.windowController === controller)
        #expect(!window.isVisible)
        #expect(surface.window == nil)
        #expect(!controller.isMinimizedInFloatingCanvas(surface.id))
        #expect(surface.pty?.startedInDirectory == fixture.root.path)
        let panes = Tako.surfaces(in: window)
        #expect(panes.count == 1 && panes.first === surface,
                "a background controller's logical tree is still its terminal metadata")
        #expect(Tako.surface(in: window) === surface)
    }

    @Test func aPaneMountedInAnotherWindowDoesNotBelongToTheOldTree() throws {
        let fixture = try PrivateSurfaceFixture()
        defer { fixture.cleanUp() }
        let surface = fixture.surface()
        let (controller, window) = TerminalTestSupport.makeController(baseConfig: fixture.configuration,
                                                                    surfaceTree: .init(view: surface))
        window.windowController = controller
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                             styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer {
            surface.removeFromSuperview()
            other.close()
            TerminalTestSupport.tearDown(controller, window)
        }
        other.contentView?.addSubview(surface)
        #expect(surface.window === other)
        #expect(Tako.surfaces(in: window).isEmpty)
        #expect(Tako.surface(in: window) == nil)
        #expect(Tako.surfaces(in: other).first === surface,
                "a non-controller window still resolves its actually mounted view")
    }
}
