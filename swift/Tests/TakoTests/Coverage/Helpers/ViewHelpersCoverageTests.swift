import Testing
import Foundation
import AppKit
import SwiftUI
import MetalKit
@testable import Tako

// MARK: Test window harness

@MainActor
private func withOffscreenWindow<T>(size: NSSize = .init(width: 200, height: 150), _ body: (NSWindow) -> T) -> T {
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = NSWindow(
        contentRect: NSRect(x: frame.minX + 10, y: frame.minY + 10, width: size.width, height: size.height),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    return body(window)
}

// MARK: CrossKit

private struct ProbeRepresentable: OSViewRepresentable {
    final class Marker: NSView {
        var makeCalled = false
        var updateCalled = false
    }

    let onMake: () -> Void
    let onUpdate: () -> Void

    func makeOSView(context: Context) -> Marker {
        onMake()
        let view = Marker()
        view.makeCalled = true
        return view
    }

    func updateOSView(_ osView: Marker, context: Context) {
        onUpdate()
        osView.updateCalled = true
    }
}

@MainActor
struct CrossKitTests {
    @Test func osViewRepresentableBridgesToNSViewRepresentableDefaultImplementations() {
        withOffscreenWindow { window in
            var madeCount = 0
            var updatedCount = 0
            let view = ProbeRepresentable(onMake: { madeCount += 1 }, onUpdate: { updatedCount += 1 })
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: .init(width: 100, height: 100))
            window.contentView?.addSubview(hosting)
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            let deadline = Date().addingTimeInterval(2)
            while madeCount == 0 && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }

            #expect(madeCount >= 1)
        }
    }
}

// MARK: Backport

@MainActor
struct BackportTests {
    @Test func backportWrapsViewContent() {
        let view = Rectangle().fill(.blue)
        let backport = view.backport
        #expect(type(of: backport.content) == type(of: view))
    }

    @Test func pointerStyleProducesRenderableView() {
        let wrapped = Rectangle().backport.pointerStyle(.default)
        let hosting = NSHostingView(rootView: wrapped)
        hosting.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        #expect(hosting.fittingSize.width >= 0)
    }

    @Test func pointerStyleAcceptsNil() {
        let wrapped = Rectangle().backport.pointerStyle(nil)
        let hosting = NSHostingView(rootView: wrapped)
        hosting.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        #expect(hosting.fittingSize.width >= 0)
    }

    @Test func everyBackportPointerStyleCaseResolvesToAnOfficialStyleOnSupportedOS() {
        if #available(macOS 15, *) {
            let styles: [BackportPointerStyle] = [
                .default, .grabIdle, .grabActive, .horizontalText, .verticalText, .link,
                .resizeLeft, .resizeRight, .resizeUp, .resizeDown, .resizeUpDown, .resizeLeftRight,
            ]
            for style in styles {
                _ = style.official
            }
            #expect(true)
        }
    }

    @Test func glassStyleCasesResolveOnSupportedOS() {
        if #available(macOS 26, *) {
            #expect(BackportNSGlassStyle.regular.official == .regular)
            #expect(BackportNSGlassStyle.clear.official == .clear)
        }
    }
}

// MARK: HostingWindow

@MainActor
struct HostingWindowKeyTests {
    @Test func defaultValueReturnsNil() {
        #expect(HostingWindowKey.defaultValue() == nil)
    }

    @Test func environmentValueRoundTripsThroughHostingWindow() {
        withOffscreenWindow { window in
            var seenWindow: NSWindow?
            struct Probe: View {
                let onAppear: (NSWindow?) -> Void
                @Environment(\.hostingWindow) var hostingWindow
                var body: some View {
                    Color.clear.onAppear { onAppear(hostingWindow()) }
                }
            }

            let hosting = NSHostingView(rootView: Probe(onAppear: { seenWindow = $0 })
                .environment(\.hostingWindow, { [weak window] in window }))
            hosting.frame = NSRect(origin: .zero, size: .init(width: 40, height: 40))
            window.contentView?.addSubview(hosting)
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            let deadline = Date().addingTimeInterval(2)
            while seenWindow == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }

            #expect(seenWindow === window)
        }
    }
}

// MARK: NonDraggableHostingView

@MainActor
struct NonDraggableHostingViewTests {
    @Test func mouseDownCanMoveWindowIsAlwaysFalse() {
        let view = NonDraggableHostingView(rootView: Color.red)
        #expect(view.mouseDownCanMoveWindow == false)
    }
}

// MARK: MetalView

@MainActor
struct MetalViewTests {
    @Test func rendersAnMTKViewIntoTheHierarchy() {
        withOffscreenWindow { window in
            let metalView = MetalView<MTKView>()
            let hosting = NSHostingView(rootView: metalView)
            hosting.frame = NSRect(origin: .zero, size: .init(width: 64, height: 64))
            window.contentView?.addSubview(hosting)
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            let found = hosting.firstDescendant(withClassName: "MTKView")
            #expect(found != nil)
        }
    }
}

// MARK: URLHoverBanner

@MainActor
struct URLHoverBannerTests {
    @Test func rendersWithoutCrashingAndProducesPixels() {
        withOffscreenWindow { window in
            let banner = URLHoverBanner(url: "https://example.com/some/very/long/path/that/should/truncate")
            let hosting = NSHostingView(rootView: banner)
            hosting.frame = NSRect(origin: .zero, size: .init(width: 240, height: 40))
            window.contentView?.addSubview(hosting)
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                Issue.record("Expected a bitmap representation of the rendered banner")
                return
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            #expect(bitmap.pixelsHigh > 0)
        }
    }
}
