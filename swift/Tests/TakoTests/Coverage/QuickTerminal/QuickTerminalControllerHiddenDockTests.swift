import Testing
import AppKit
@testable import Tako

/// Covers `QuickTerminalController`'s private `HiddenDock` helper, which
/// toggles the system Dock autohide preference when the quick terminal's
/// position would otherwise overlap it. In a test run `Dock` keeps that
/// preference in memory (`Dock.autoHide`), so nothing here reaches the
/// real Dock; every path still restores the value it found.
@MainActor
struct QuickTerminalControllerHiddenDockTests {
    @Test func hidingAndRestoringTheDockRoundTripsThroughAnimateInAndOut() {
        let originalAutoHide = Dock.autoHideEnabled
        defer { Dock.autoHideEnabled = originalAutoHide }

        guard let position = QTTestSupport.positionConflictingWithRealDock(),
              let screen = NSScreen.main,
              position.conflictsWithDock(on: screen) else {
            // No dock could be located (or it currently autohides, which
            // makes `hasDock` false for every position) on this host: the
            // conflict branch can't be forced without a real, visible dock.
            // Assert the well-defined alternative instead: state stays put.
            #expect(Dock.autoHideEnabled == originalAutoHide)
            return
        }

        let (controller, window) = QTTestSupport.makeController(position: position)
        controller.windowDidLoad()
        QTTestSupport.waitUntil(timeout: 3) { window.isVisible }

        // HiddenDock.hide() runs synchronously inside animateWindowIn, before
        // the animation group even starts.
        #expect(Dock.autoHideEnabled == true)

        controller.animateOut()
        // HiddenDock is niled out (which restores it) synchronously at the
        // top of animateWindowOut, before that animation group starts either.
        #expect(Dock.autoHideEnabled == originalAutoHide)

        QTTestSupport.waitUntil(timeout: 3) { !window.isVisible }
        QTTestSupport.tearDown(controller, window)
    }

    @Test func applicationWillTerminateAlsoRestoresAHiddenDock() {
        let originalAutoHide = Dock.autoHideEnabled
        defer { Dock.autoHideEnabled = originalAutoHide }

        guard let position = QTTestSupport.positionConflictingWithRealDock(),
              let screen = NSScreen.main,
              position.conflictsWithDock(on: screen) else {
            #expect(Dock.autoHideEnabled == originalAutoHide)
            return
        }

        let (controller, window) = QTTestSupport.makeController(position: position)
        controller.windowDidLoad()
        QTTestSupport.waitUntil(timeout: 3) { window.isVisible }
        #expect(Dock.autoHideEnabled == true)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(Dock.autoHideEnabled == originalAutoHide)

        // hiddenDock is already nil at this point; animateOut just hides the window.
        controller.animateOut()
        QTTestSupport.tearDown(controller, window)
    }
}
