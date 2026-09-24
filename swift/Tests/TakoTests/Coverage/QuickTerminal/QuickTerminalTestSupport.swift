import AppKit
import Foundation
@testable import Tako

/// Shared helpers for the QuickTerminal / Secure Input / Global Keybinds / Services
/// behavioural coverage suites.
enum QTTestSupport {
    /// Spins the run loop, polling `condition`, until it becomes true or `timeout`
    /// elapses. Used instead of fixed `sleep`s to wait on real animations,
    /// `DispatchQueue.main.async` hops, and NSAnimationContext completion handlers.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return condition() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Builds a `QuickTerminalController` with a real window attached directly
    /// (bypassing `NSWindowController.windowNibName`'s lazy nib loading).
    ///
    /// `QuickTerminal.xib` is deliberately excluded from this SwiftPM target (see
    /// swift/Package.swift), so letting `.window` load lazily here would fail:
    /// there is no nib in the test bundle to find. Assigning `.window` directly
    /// before it is ever read short-circuits that lazy path (NSWindowController
    /// only calls `loadWindow()` when its stored window is still nil), which is
    /// exactly how this file's tests drive `windowDidLoad()` deliberately instead.
    @MainActor
    static func makeController(
        position: QuickTerminalPosition = .center
    ) -> (controller: QuickTerminalController, window: QuickTerminalWindow) {
        let app = Tako.App()
        let controller = QuickTerminalController(app, position: position)
        let window = QuickTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        controller.window = window
        return (controller, window)
    }

    /// Drives the real `windowDidLoad()` -> `animateIn()` flow (as production
    /// code would via the nib callback) and waits for the animation to finish.
    /// Always uses `.center`, the one `QuickTerminalPosition` that
    /// `conflictsWithDock(on:)` can never match, so this never toggles the
    /// real Dock's autohide preference on the host running the test.
    ///
    /// `animateWindowIn` orders the window front from inside
    /// `DispatchQueue.main.async`, but a bare `swift test` host never runs a
    /// real main-thread run loop to drain GCD's main queue (see the same
    /// documented caveat on
    /// `TakoAppAdapterCoverageTests.moveFocusWithADelayDoesNotCrash`), so that
    /// hop never fires here no matter how long this polls. Ordering the
    /// window front directly afterward reproduces what that dead hop would
    /// have done, so the rest of the flow (`isVisible`-gated `syncAppearance`,
    /// key window state, sheets) can still be exercised deterministically.
    @MainActor
    static func loadAndAnimateIn(
        position: QuickTerminalPosition = .center
    ) -> (controller: QuickTerminalController, window: QuickTerminalWindow) {
        let (controller, window) = makeController(position: position)
        controller.windowDidLoad()
        simulateDeferredAnimateInCompletion(controller: controller, window: window)
        return (controller, window)
    }

    /// See `loadAndAnimateIn`'s doc comment: call this after any production
    /// call that (re-)triggers `animateIn()` mid-test (e.g. `toggle()`,
    /// `focusSurface(_:)` while hidden), since each one schedules the same
    /// dead `DispatchQueue.main.async` hop to order the window front.
    @MainActor
    static func simulateDeferredAnimateInCompletion(
        controller: QuickTerminalController, window: NSWindow
    ) {
        guard controller.visible else { return }
        window.makeKeyAndOrderFront(nil)
        waitUntil(timeout: 2) { window.alphaValue >= 1 }
    }

    /// See `loadAndAnimateIn`'s doc comment: `animateWindowOut`'s
    /// `NSAnimationContext.runAnimationGroup` completion handler is invoked
    /// by AppKit through the same dead main-queue hop (it is never reached
    /// by directly pumping `RunLoop.current`, confirmed by `alphaValue`
    /// reaching its animated-to end state while `window.isVisible` stays
    /// `true` forever). `window.orderOut(self)` is the one real effect that
    /// completion handler has, so simulate it here once the animation
    /// portion (which *does* run synchronously against the model values)
    /// has reached its final alpha, mirroring `simulateDeferredAnimateInCompletion`.
    @MainActor
    static func simulateDeferredAnimateOutCompletion(
        controller: QuickTerminalController, window: NSWindow
    ) {
        guard !controller.visible else { return }
        waitUntil(timeout: 2) { window.alphaValue <= 0 }
        window.orderOut(nil)
    }

    /// Animates a controller back out (if visible) and orders its window out,
    /// so tests don't leak visible windows into later tests.
    @MainActor
    static func tearDown(_ controller: QuickTerminalController, _ window: NSWindow) {
        if controller.visible {
            controller.animateOut()
            waitUntil(timeout: 3) { !window.isVisible }
        }
        window.orderOut(nil)
    }

    /// A `QuickTerminalPosition` that is guaranteed to conflict with the
    /// dock's real, current orientation on this host, if one can be
    /// determined -- so `HiddenDock` tests can force the "conflicts" branch
    /// deterministically instead of guessing a fixed position.
    static func positionConflictingWithRealDock() -> QuickTerminalPosition? {
        // `hasDock` (used transitively by `conflictsWithDock`) reads
        // `NSApp.mainMenu`. `NSApp` is only assigned once something touches
        // `NSApplication.shared`; force that first so a filtered run that
        // exercises Dock logic before creating any window doesn't crash on
        // `NSApp`'s implicitly-unwrapped nil.
        _ = NSApplication.shared
        guard let orientation = Dock.orientation else { return nil }
        switch orientation {
        case .top, .bottom: return .left
        case .left, .right: return .top
        }
    }
}

/// A mock `NSScreen` for pure geometry tests that don't need a physical display.
/// Overrides everything `QuickTerminalPosition`/`QuickTerminalSize`/`hasDock`
/// read: `frame`, `visibleFrame`, `backingScaleFactor`, `safeAreaInsets`.
final class MockGeometryScreen: NSScreen {
    private let mockFrame: NSRect
    private let mockVisibleFrame: NSRect
    private let mockScale: CGFloat
    private let mockSafeAreaTop: CGFloat

    init(
        frame: NSRect,
        visibleFrame: NSRect? = nil,
        scale: CGFloat = 2,
        safeAreaTop: CGFloat = 0
    ) {
        self.mockFrame = frame
        self.mockVisibleFrame = visibleFrame ?? frame
        self.mockScale = scale
        self.mockSafeAreaTop = safeAreaTop
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var frame: NSRect { mockFrame }
    override var visibleFrame: NSRect { mockVisibleFrame }
    override var backingScaleFactor: CGFloat { mockScale }
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: mockSafeAreaTop, left: 0, bottom: 0, right: 0)
    }

    // AppKit's own description traps on a screen with no display behind it,
    // and a failed #expect describes the values it read: without these a
    // failure killed the whole test process instead of being reported.
    override var description: String { "MockGeometryScreen(\(mockFrame), visible: \(mockVisibleFrame))" }
    override var debugDescription: String { description }
}
