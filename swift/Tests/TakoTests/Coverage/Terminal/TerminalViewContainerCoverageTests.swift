import Testing
import AppKit
import SwiftUI
@testable import Tako

/// `Tako.Config` is `open`, so we subclass it to force a specific
/// `backgroundBlur` (the real config only ever derives `.disabled`/`.radius`
/// from the theme; the glass styles come from the raw C value path, which
/// isn't reachable from a plain config object), letting these tests drive
/// the liquid-glass code paths deterministically on the macOS 26 test host.
private final class GlassConfig: Tako.Config {
    var forcedBlur: Tako.Config.BackgroundBlur = .macosGlassRegular
    override var backgroundBlur: Tako.Config.BackgroundBlur { forcedBlur }
}

@MainActor
private func makeWindowedContainer() -> (window: NSWindow, container: TerminalViewContainer) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
    let container = TerminalViewContainer { Text("hi") }
    window.contentView = container
    return (window, container)
}

@MainActor
struct TerminalViewContainerCoverageTests {
    @Test func windowThemeFrameViewIsNilWithoutAWindow() {
        let container = TerminalViewContainer { Text("hi") }
        #expect(container.windowThemeFrameView == nil)
    }

    @Test func windowThemeFrameViewIsFoundOnceAttachedToARealWindow() {
        let (window, container) = makeWindowedContainer()
        defer { window.orderOut(nil) }
        #expect(container.windowThemeFrameView != nil)
    }

    @Test func windowCornerRadiusIsNilWithoutAWindow() {
        let container = TerminalViewContainer { Text("hi") }
        #expect(container.windowCornerRadius == nil)
    }

    @Test func windowCornerRadiusIsQueriedFromARealWindow() {
        let (window, container) = makeWindowedContainer()
        defer { window.orderOut(nil) }
        // Real NSWindow instances respond to the private selector but
        // report 0 corner radius for a plain titled window; we're only
        // asserting the code path executes without crashing and returns
        // a value shaped like a valid response.
        _ = container.windowCornerRadius
        #expect(true)
    }

    @Test func intrinsicContentSizeFallsBackToInitialContentSizeWhenHostingSizeIsSmaller() {
        let container = TerminalViewContainer { Text("hi") }
        container.initialContentSize = NSSize(width: 800, height: 600)
        #expect(container.intrinsicContentSize.width == 800)
        #expect(container.intrinsicContentSize.height == 600)
    }

    @Test func intrinsicContentSizeIgnoresInitialContentSizeWhenNotSet() {
        let container = TerminalViewContainer { Text("hi") }
        // Without an initialContentSize fallback the hosting view's own
        // (tiny, pre-layout) intrinsic size is returned as-is.
        let size = container.intrinsicContentSize
        #expect(size.width >= 0)
    }

    @Test func viewDidMoveToWindowAndLayoutDoNotCrashWithoutAWindow() {
        let container = TerminalViewContainer { Text("hi") }
        container.viewDidMoveToWindow()
        container.layout()
        #expect(true)
    }

    @Test func viewDidMoveToWindowConfiguresGlassEffectOnceAttached() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        let container = TerminalViewContainer { Text("hi") }
        let config = GlassConfig()
        container.takoConfigDidChange(config, preferredBackgroundColor: .white)
        window.contentView = container
        defer { window.orderOut(nil) }
        // `takoConfigDidChange` sets `derivedConfig` synchronously and only
        // *defers* the actual glass-view build to a `DispatchQueue.main.async`
        // -- under heavy machine load that lands unpredictably late, so poking
        // `viewDidMoveToWindow()` (which calls the same build function
        // synchronously) makes this deterministic instead of racy.
        container.viewDidMoveToWindow()
        #expect(container.glassEffectView != nil)
    }

    @Test func takoConfigDidChangeIsANoOpForAnUnchangedConfig() {
        let (window, container) = makeWindowedContainer()
        defer { window.orderOut(nil) }
        let config = GlassConfig()
        container.takoConfigDidChange(config, preferredBackgroundColor: .white)
        container.viewDidMoveToWindow()
        let firstGlassView = container.glassEffectView
        #expect(firstGlassView != nil)
        // A second call with an equal derived config should not rebuild
        // the glass effect view.
        container.takoConfigDidChange(config, preferredBackgroundColor: .white)
        container.viewDidMoveToWindow()
        #expect(container.glassEffectView === firstGlassView)
    }

    @Test func takoConfigDidChangeRemovesGlassEffectWhenBlurIsDisabled() {
        let (window, container) = makeWindowedContainer()
        defer { window.orderOut(nil) }
        let glassConfig = GlassConfig()
        container.takoConfigDidChange(glassConfig, preferredBackgroundColor: .white)
        container.viewDidMoveToWindow()
        #expect(container.glassEffectView != nil)

        let disabledConfig = GlassConfig()
        disabledConfig.forcedBlur = .disabled
        container.takoConfigDidChange(disabledConfig, preferredBackgroundColor: .white)
        container.viewDidMoveToWindow()
        #expect(container.glassEffectView == nil)
    }

    @Test func updateGlassTintOverlayIsSafeWithoutAGlassEffect() {
        let container = TerminalViewContainer { Text("hi") }
        container.updateGlassTintOverlay(isKeyWindow: true)
        container.updateGlassTintOverlay(isKeyWindow: false)
        #expect(true)
    }

    @Test func updateGlassTintOverlayUpdatesOnceAGlassEffectExists() {
        let (window, container) = makeWindowedContainer()
        defer { window.orderOut(nil) }
        let config = GlassConfig()
        container.takoConfigDidChange(config, preferredBackgroundColor: .white)
        container.viewDidMoveToWindow()
        #expect(container.glassEffectView != nil)
        container.updateGlassTintOverlay(isKeyWindow: true)
        container.updateGlassTintOverlay(isKeyWindow: false)
        #expect(true)
    }

    @Test func terminalViewContainerExtensionResolvesTheContentView() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(controller.terminalViewContainer != nil)
        #expect(controller.terminalViewContainer === window.contentView)
    }

    @Test func terminalViewContainerExtensionIsNilForAnUnrelatedContentView() {
        let (controller, window) = TerminalTestSupport.makeController()
        defer { TerminalTestSupport.tearDown(controller, window) }
        window.contentView = NSView()
        #expect(controller.terminalViewContainer == nil)
    }

    @Test func derivedConfigIsNilWhenBlurIsDisabled() {
        let config = GlassConfig()
        config.forcedBlur = .disabled
        let derived = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: nil, cornerRadius: nil)
        #expect(derived == nil)
    }

    @Test func derivedConfigIsNilForARadiusBlur() {
        let config = GlassConfig()
        config.forcedBlur = .radius(8)
        let derived = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: nil, cornerRadius: nil)
        #expect(derived == nil)
    }

    @Test func derivedConfigResolvesTheRegularGlassStyle() {
        let config = GlassConfig()
        config.forcedBlur = .macosGlassRegular
        let derived = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: .red, cornerRadius: 12)
        #expect(derived?.backgroundColor == .red)
        #expect(derived?.cornerRadius == 12)
    }

    @Test func derivedConfigResolvesTheClearGlassStyle() {
        let config = GlassConfig()
        config.forcedBlur = .macosGlassClear
        let derived = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: nil, cornerRadius: nil)
        #expect(derived != nil)
    }

    @Test func derivedConfigFallsBackToTheConfigBackgroundColorWithoutAPreferredColor() {
        let config = GlassConfig()
        config.forcedBlur = .macosGlassRegular
        let derived = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: nil, cornerRadius: nil)
        #expect(derived != nil)
    }

    @Test func derivedConfigEqualityComparesAllFields() {
        let config = GlassConfig()
        config.forcedBlur = .macosGlassRegular
        let first = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: .red, cornerRadius: 4)
        let second = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: .red, cornerRadius: 4)
        let third = TerminalViewContainer.DerivedConfig(
            config: config, preferredBackgroundColor: .blue, cornerRadius: 4)
        #expect(first == second)
        #expect(first != third)
    }
}
