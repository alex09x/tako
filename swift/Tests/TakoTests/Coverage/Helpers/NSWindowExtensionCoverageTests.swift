import Testing
import Foundation
import AppKit
@testable import Tako

@MainActor
private func makeTitledWindow(at offset: CGFloat = 0) -> NSWindow {
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
    let window = NSWindow(
        contentRect: NSRect(x: frame.minX + 20 + offset, y: frame.minY + 20, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .preferred
    return window
}

@MainActor
private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

@MainActor
struct NSWindowExtensionTests {
    @Test func cgWindowIdMatchesTheWindowNumberOnceItHasOne() {
        let window = makeTitledWindow()
        defer { window.close() }

        // A non-deferred window may already have a number before it is
        // ordered (macOS 26 assigns one at creation), so only the value is
        // pinned, not when it appears.
        window.orderFrontRegardless()
        waitUntil { window.windowNumber > 0 }
        #expect(window.cgWindowId == CGWindowID(window.windowNumber))
    }

    @Test func constrainToScreenShrinksOversizedFrame() {
        let window = makeTitledWindow()
        defer { window.close() }
        guard let screen = window.screen ?? NSScreen.main else {
            Issue.record("Expected a screen")
            return
        }
        let oversized = NSRect(
            x: screen.visibleFrame.minX - 500,
            y: screen.visibleFrame.minY - 500,
            width: screen.visibleFrame.width * 3,
            height: screen.visibleFrame.height * 3)
        window.setFrame(oversized, display: false)

        window.constrainToScreen()

        #expect(window.frame.width <= screen.visibleFrame.width)
        #expect(window.frame.height <= screen.visibleFrame.height)
        #expect(window.frame.minX >= screen.visibleFrame.minX)
        #expect(window.frame.minY >= screen.visibleFrame.minY)
    }

    @Test func constrainToScreenIsNoOpWhenAlreadyInBounds() {
        let window = makeTitledWindow()
        defer { window.close() }
        let before = window.frame
        window.constrainToScreen()
        #expect(window.frame == before)
    }

    @Test func isFirstWindowInTabGroupIsTrueForUntabbedWindow() {
        let window = makeTitledWindow()
        defer { window.close() }
        #expect(window.isFirstWindowInTabGroup)
    }

    @Test func addTabbedWindowSafelyJoinsRealTabGroupAndExposesTabButtons() {
        let first = makeTitledWindow(at: 0)
        let second = makeTitledWindow(at: 450)
        defer {
            first.close()
            second.close()
        }

        first.orderFrontRegardless()
        waitUntil { first.windowNumber > 0 }

        let joined = first.addTabbedWindowSafely(second, ordered: .above)
        #expect(joined)

        waitUntil { first.tabbedWindows?.count == 2 }
        #expect(first.tabbedWindows?.count == 2)
        #expect(second.isFirstWindowInTabGroup == (first.tabGroup?.windows.first === second))

        // Force layout so AppKit actually builds the private NSTabBar view.
        first.tabGroup?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        first.contentView?.layoutSubtreeIfNeeded()
        first.displayIfNeeded()
        waitUntil(timeout: 4) { first.tabButtonsInVisualOrder().count == 2 }

        let buttons = first.tabButtonsInVisualOrder()
        #expect(buttons.count == 2)

        guard let button = buttons.first, let buttonWindow = button.window else {
            Issue.record("Expected a tab button hosted in a window")
            return
        }

        let pointInWindow = button.convert(button.bounds.insetBy(dx: button.bounds.width / 2 - 1, dy: button.bounds.height / 2 - 1).origin, to: nil)
        let screenPoint = buttonWindow.convertPoint(toScreen: pointInWindow)

        let hitIndex = first.tabIndex(atScreenPoint: screenPoint)
        #expect(hitIndex != nil)

        let hit = first.tabButtonHit(atScreenPoint: screenPoint)
        #expect(hit?.tabButton === button)

        // A point far outside any window on screen should miss entirely.
        let missPoint = NSPoint(x: -100000, y: -100000)
        #expect(first.tabIndex(atScreenPoint: missPoint) == nil)
        #expect(first.tabButtonHit(atScreenPoint: missPoint) == nil)
    }

    @Test func titlebarViewAndTabBarViewAreAccessibleOnceOrdered() {
        let window = makeTitledWindow()
        defer { window.close() }
        window.orderFrontRegardless()
        waitUntil { window.contentView?.rootView.responds(to: Selector(("titlebarView"))) == true }

        #expect(window.titlebarView != nil)
        // With a single, non-tabbed window there is no visible NSTabBar yet.
        #expect(window.tabBarView == nil)
        #expect(window.tabButtonsInVisualOrder().isEmpty)
    }
}
