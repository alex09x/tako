import Testing
import AppKit
import SwiftUI
@testable import Tako

@MainActor
struct SecureInputOverlayTests {
    @Test func rendersVisiblePixelsAndRunsItsOnAppearAnimationsWithoutCrashing() throws {
        let hosting = NSHostingView(rootView: SecureInputOverlay())
        hosting.frame = NSRect(x: 0, y: 0, width: 60, height: 60)

        let screenOrigin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(
            contentRect: NSRect(origin: screenOrigin, size: hosting.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        QTTestSupport.waitUntil(timeout: 1) { hosting.window != nil }
        hosting.layout()
        // Let SwiftUI's appearance lifecycle run so the `.onAppear` block
        // (which starts the looping gradient animations) actually fires.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        var sawVisiblePixel = false
        for x in stride(from: 0, to: Int(hosting.bounds.width), by: 3) where !sawVisiblePixel {
            for y in stride(from: 0, to: Int(hosting.bounds.height), by: 3) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    sawVisiblePixel = true
                    break
                }
            }
        }
        #expect(sawVisiblePixel)
    }
}
