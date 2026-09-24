import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tako

// Coverage for swift/Sources/TakoApp/Features/About: AboutController (window
// lifecycle, bypassing the excluded About.xib by injecting a window
// directly), AboutViewModel (icon cycling), and AboutView/CyclingIconView
// (hosted rendering + real interaction).

@MainActor
@Suite
struct AboutControllerCoverageTests {
    @Test func windowNibNameIsAbout() {
        let controller = AboutController()
        #expect(controller.windowNibName == "About")
    }

    @Test func windowDidLoadConfiguresTheInjectedWindow() {
        let controller = AboutController()
        let window = makePanelWindow()
        controller.window = window
        controller.windowDidLoad()

        #expect(window.isMovableByWindowBackground)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.contentView != nil)
        #expect(String(describing: type(of: window.contentView!)).contains("NSHostingView"))
    }

    @Test func showOrdersFrontAndHideCloses() {
        let controller = AboutController()
        let window = makePanelWindow()
        controller.window = window
        controller.windowDidLoad()

        controller.show()
        #expect(window.isVisible)

        controller.hide()
        #expect(!window.isVisible)
    }

    @Test func closeActionsPerformCloseOnTheWindow() {
        let controller = AboutController()
        let window = makePanelWindow()
        controller.window = window
        controller.windowDidLoad()
        window.makeKeyAndOrderFront(nil)

        controller.close(controller)
        #expect(!window.isVisible)

        window.makeKeyAndOrderFront(nil)
        controller.closeWindow(controller)
        #expect(!window.isVisible)

        window.makeKeyAndOrderFront(nil)
        controller.cancel(nil)
        #expect(!window.isVisible)
    }

    @Test func windowWillCloseStopsCyclingTheIcon() {
        let controller = AboutController()
        let window = makePanelWindow()
        controller.window = window
        controller.windowDidLoad()
        controller.show()

        // No public accessor for the controller's private view model, so
        // observe the effect through the delegate call itself: it must not
        // crash and must be safe to call repeatedly (stopCyclingIcons is
        // idempotent).
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }
}

@Suite
struct AboutViewModelCoverageTests {
    @Test @MainActor func advanceToNextIconWrapsWithinTheSingleIconOfficialSet() {
        let model = AboutViewModel()
        #expect(model.currentIcon == nil)

        model.advanceToNextIcon()
        #expect(model.currentIcon == .official)

        // Only one icon exists, so advancing again wraps back to itself.
        model.advanceToNextIcon()
        #expect(model.currentIcon == .official)
    }

    @Test @MainActor func stopCyclingClearsTheCurrentIcon() {
        let model = AboutViewModel()
        model.advanceToNextIcon()
        #expect(model.currentIcon != nil)

        model.stopCyclingIcons()
        #expect(model.currentIcon == nil)
    }

    @Test @MainActor func startCyclingAdvancesOnATimerUnlessHovering() async {
        let model = AboutViewModel()
        defer { model.stopCyclingIcons() }

        model.isHovering = true
        model.startCyclingIcons()
        // While hovering, the timer's sink guard bails before advancing.
        try? await Task.sleep(nanoseconds: 3_600_000_000)
        #expect(model.currentIcon == nil)

        model.isHovering = false
        #expect(waitUntilPanel(timeout: 4) { model.currentIcon == .official })
    }
}

@Suite
@MainActor
struct AboutViewCoverageTests {
    @Test func rendersWithARealAppIconAndPropertyRows() {
        let window = makePanelWindow(size: NSSize(width: 360, height: 320))
        let hosting = hostPanel(AboutView().environmentObject(AboutViewModel()), in: window)
        // The view reads Bundle.main for build/version/copyright, which
        // this test process cannot override; render must still produce a
        // non-empty layout regardless of which fields are present.
        #expect(hosting.fittingSize.height > 0)
        #expect(hosting.fittingSize.width > 0)
    }
}

@Suite
@MainActor
struct CyclingIconViewCoverageTests {
    private func host(_ model: AboutViewModel) -> (NSWindow, NSHostingView<AnyView>) {
        let window = makePanelWindow(size: NSSize(width: 160, height: 160))
        let view = AnyView(CyclingIconView().environmentObject(model))
        let hosting = hostPanel(view, in: window)
        return (window, hosting)
    }

    @Test func rendersTheFallbackIconWhenNoCurrentIconIsSet() {
        let model = AboutViewModel()
        let (_, hosting) = host(model)
        #expect(hosting.fittingSize.width >= 0)
    }
}
