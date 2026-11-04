// tako — Live surface host layout and move regressions
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import Tako

@MainActor
struct SurfaceHostingViewTests {
    @Test func aSurfaceFitsTheSpaceSwiftUIActuallyGivesItsHost() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        defer { surface.close() }
        let host = SurfaceHostingView(surfaceView: surface)
        host.frame.size = NSSize(width: 220, height: 130)
        host.layoutSubtreeIfNeeded()
        #expect(surface.frame.size == host.bounds.size)
        #expect(surface.bounds.size == host.bounds.size)
        host.frame.size = NSSize(width: 310, height: 180)
        host.layoutSubtreeIfNeeded()
        #expect(surface.frame.size == host.bounds.size)
        #expect(surface.bounds.size == host.bounds.size)
    }

    @Test func reusingASlotDoesNotPullAMovedSurfaceOutOfItsNewHost() {
        let moved = Tako.SurfaceView(frame: .zero)
        let replacement = Tako.SurfaceView(frame: .zero)
        defer { moved.close(); replacement.close() }
        let oldHost = SurfaceHostingView(surfaceView: moved)
        let newHost = SurfaceHostingView(surfaceView: moved)
        #expect(!oldHost.mount(moved))
        #expect(moved.superview === newHost)
        #expect(oldHost.mount(replacement))
        #expect(moved.superview === newHost)
        #expect(replacement.superview === oldHost)
        #expect(newHost.surfaceView === moved)
        #expect(oldHost.surfaceView === replacement)
        #expect(!oldHost.mount(replacement))
    }

    @Test func aReflowCannotResizeTheSwiftUIOwnedParent() {
        let surface = Tako.SurfaceView(frame: .zero)
        defer { surface.close() }
        let host = SurfaceHostingView(surfaceView: surface)
        host.frame.size = NSSize(width: 220, height: 130)
        host.layoutSubtreeIfNeeded()
        surface.reflow(to: NSSize(width: 400, height: 400))
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.size == NSSize(width: 220, height: 130))
        #expect(surface.frame.size == host.bounds.size)
    }
}
