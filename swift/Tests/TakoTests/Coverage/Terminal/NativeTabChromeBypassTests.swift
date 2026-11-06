// Tako — custom tab strips must not run native tab-button decoration work
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import Tako

@MainActor
private final class NativeChromeTraversalProbe: NSView {
    var reads = 0
    override var subviews: [NSView] {
        get { reads += 1; return super.subviews }
        set { super.subviews = newValue }
    }
}

@Suite @MainActor
struct NativeTabChromeBypassTests {
    @Test func profileNativeLookupVersusCustomStripGuard() throws {
        try withAppDelegate { _ in
            let window = TitlebarTabsVenturaTerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let container = try #require(window.titlebarContainer)
            let fixture = NSView(frame: .zero)
            for _ in 0..<200 { fixture.addSubview(NSView(frame: .zero)) }
            container.addSubview(fixture)
            defer { fixture.removeFromSuperview() }
            func workload() -> Double {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<1000 {
                    window.updateNewTabButtonOpacity()
                    window.updateNewTabButtonImage()
                }
                return (ProcessInfo.processInfo.systemUptime - start) * 1000
            }
            window.tabbingMode = .preferred
            let nativeMS = workload()
            window.tabbingMode = .disallowed
            let customMS = workload()
            print("TITLEBAR_WORKLOAD iterations=1000 native_lookup_ms=\(nativeMS) custom_guard_ms=\(customMS)")
            #expect(window.newTabButtonImageLayer == nil)
        }
    }

    @Test func disallowedTabbingSkipsNativeDecorationsButNativeModeStillWorks() throws {
        try withAppDelegate { _ in
            let window = TitlebarTabsVenturaTerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let container = try #require(window.titlebarContainer)
            let probe = NativeChromeTraversalProbe(frame: .zero)
            probe.addSubview(NSView(frame: .zero))
            container.addSubview(probe)
            defer { probe.removeFromSuperview() }
            window.tabbingMode = .disallowed
            probe.reads = 0
            for _ in 0..<500 {
                window.updateNewTabButtonOpacity()
                window.updateNewTabButtonImage()
            }
            #expect(probe.reads == 0, "The custom strip must not search native tab-button descendants")
            #expect(window.newTabButtonImageLayer == nil)
            window.tabbingMode = .preferred
            probe.reads = 0
            window.updateNewTabButtonOpacity()
            window.updateNewTabButtonImage()
            #expect(probe.reads > 0, "The positive control must still exercise native discovery")
        }
    }
}
