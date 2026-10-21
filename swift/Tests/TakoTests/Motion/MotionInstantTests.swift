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
import Testing
@testable import Tako

/// What the status layer and the sidebar change at once, without Core
/// Animation's implicit quarter second: the progress arc and line, the
/// exported pose, the shake and lean, a ring-only row's scale and the resize
/// edge. Each change is made on a layer in a window's tree, committed, where
/// implicit animations run; none may come out of it animating.
@Suite(.serialized) @MainActor
struct MotionInstantTests {
    final class Host {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: .borderless,
                              backing: .buffered, defer: false)
        let view: NSView
        init() {
            window.isReleasedWhenClosed = false
            view = NSView(frame: window.contentLayoutRect)
            view.wantsLayer = true
            window.contentView = view
            window.orderFrontRegardless()
            CATransaction.flush()
        }
        func close() { window.close() }
    }

    static func animations(under root: CALayer) -> Set<String> {
        var found = Set<String>()
        func walk(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] {
                found.insert("\(ObjectIdentifier(layer).hashValue) \(layer.name ?? String(describing: type(of: layer))).\(key)")
            }
            layer.sublayers?.forEach(walk)
            layer.mask.map(walk)
        }
        walk(root)
        return found
    }

    /// The animations `change` started on the layers under `root`.
    static func started(under root: CALayer, _ change: () -> Void) -> Set<String> {
        CATransaction.flush()
        let before = animations(under: root)
        change()
        CATransaction.flush()
        return animations(under: root).subtracting(before)
    }

    private let rect = CGRect(x: 10, y: 5, width: 140, height: 28)

    @Test func theCheckSeesAChangeLeftToAnimate() {
        let host = Host()
        defer { host.close() }
        let plain = CALayer()
        plain.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        host.view.layer?.addSublayer(plain)
        #expect(!Self.started(under: host.view.layer!) { plain.opacity = 0.3 }.isEmpty, "the check is blind")
    }

    @Test func theProgressArcAndLineMoveAtOnce() {
        let host = Host()
        defer { host.close() }
        let layer = Tako.TabStatusLayer()
        host.view.layer?.addSublayer(layer)
        layer.apply(state: .progress(0.2), in: rect, hideRing: false, reduceMotion: false, paused: false)
        let moved = Self.started(under: host.view.layer!) {
            layer.apply(state: .progress(0.7), in: rect, hideRing: false, reduceMotion: false, paused: false)
        }
        #expect(moved.isEmpty, "the progress moved by animation: \(moved.sorted())")
    }

    @Test func anExportedPoseIsSetAtOnce() {
        let host = Host()
        defer { host.close() }
        let layer = Tako.TabStatusLayer()
        host.view.layer?.addSublayer(layer)
        layer.apply(state: .failed, in: rect, hideRing: false, reduceMotion: false, paused: false)
        let posed = Self.started(under: host.view.layer!) { layer.applySnapshotPhase(at: 0.3, doneElapsed: 0.3, failedElapsed: 0.064) }
        #expect(posed.isEmpty, "an exported pose animated: \(posed.sorted())")
    }

    @Test func aShakeOrALeanIsSetAtOnce() {
        let host = Host()
        defer { host.close() }
        let layer = Tako.TabStatusLayer()
        host.view.layer?.addSublayer(layer)
        layer.apply(state: .idle, in: rect, hideRing: false, reduceMotion: false, paused: false)
        let leant = Self.started(under: host.view.layer!) { layer.setPose(dx: 2, tiltDegrees: 3) }
        #expect(leant.isEmpty, "a lean animated: \(leant.sorted())")
        let back = Self.started(under: host.view.layer!) { layer.setPose(dx: 0, tiltDegrees: 0) }
        #expect(back.isEmpty, "the pose coming back animated: \(back.sorted())")
    }

    @Test func aRingOnlyRowTakesItsScaleAtOnce() {
        let host = Host()
        defer { host.close() }
        let row = StatusLayerHostView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        host.view.addSubview(row)
        func config(_ side: CGFloat) -> StatusLayerHostView.Config {
            .init(state: .working, ringCenter: nil, cornerRadius: 0, reduceMotion: false, paused: false, pulses: 0,
                  progressInset: 0, cometForProgress: false, drawsRing: true, ringOnly: side)
        }
        row.configure(config(10))
        row.layout()
        let scaled = Self.started(under: host.view.layer!) {
            row.configure(config(18))
            row.layout()
        }
        #expect(scaled.isEmpty, "a ring-only row's scale animated: \(scaled.sorted())")
    }

    @Test func theResizeEdgeFollowsTheSidebarAtOnce() {
        let host = Host()
        defer { host.close() }
        let grip = SessionSidebarGripView(frame: NSRect(x: 0, y: 0, width: 12, height: 80))
        host.view.addSubview(grip)
        grip.layout()
        let followed = Self.started(under: host.view.layer!) {
            grip.setFrameSize(NSSize(width: 12, height: 110))
            grip.layout()
        }
        #expect(followed.isEmpty, "the resize edge moved by animation: \(followed.sorted())")
    }
}
