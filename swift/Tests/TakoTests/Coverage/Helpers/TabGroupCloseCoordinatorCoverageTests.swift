import Testing
import Foundation
import AppKit
@testable import Tako

@MainActor
private func makeWindow(at offset: CGFloat = 0) -> NSWindow {
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
    let window = NSWindow(
        contentRect: NSRect(x: frame.minX + 20 + offset, y: frame.minY + 20, width: 200, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func waitUntilCoordinator(timeout: TimeInterval = 1, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

@MainActor
struct TabGroupCloseCoordinatorTests {
    @Test func singleWindowCloseTriggersTabScopeImmediately() {
        let coordinator = TabGroupCloseCoordinator()
        let window = makeWindow()
        defer { window.close() }

        var receivedScope: TabGroupCloseCoordinator.CloseScope?
        coordinator.windowShouldClose(window) { scope in
            receivedScope = scope
        }

        // The group Tako.CustomTabGroup.group(for:) creates for a fresh
        // window has exactly one member, so closeRequests immediately
        // matches every window in the group and fires synchronously.
        #expect(receivedScope == .window)
    }

    @Test func allWindowsRequestingCloseTriggersWindowScope() {
        let coordinator = TabGroupCloseCoordinator()
        let first = makeWindow(at: 0)
        let second = makeWindow(at: 250)
        defer {
            first.close()
            second.close()
        }

        Tako.CustomTabGroup.join(second, to: first, select: false)

        var firstScope: TabGroupCloseCoordinator.CloseScope?
        var secondScope: TabGroupCloseCoordinator.CloseScope?

        coordinator.windowShouldClose(first) { firstScope = $0 }
        #expect(firstScope == nil, "Should wait for the sibling before firing")

        coordinator.windowShouldClose(second) { secondScope = $0 }

        #expect(firstScope == .window)
        #expect(secondScope == .window)
    }

    @Test func singlePendingRequestDebouncesToTabScope() {
        let coordinator = TabGroupCloseCoordinator()
        let first = makeWindow(at: 0)
        let second = makeWindow(at: 250)
        defer {
            first.close()
            second.close()
        }

        Tako.CustomTabGroup.join(second, to: first, select: false)

        var scope: TabGroupCloseCoordinator.CloseScope?
        coordinator.windowShouldClose(first) { scope = $0 }
        #expect(scope == nil)

        // Only one of the two tab group members requested a close, so the
        // debounce timer should eventually fire a tab-scoped close.
        waitUntilCoordinator(timeout: 2) { scope != nil }
        #expect(scope == .tab)
    }

    @Test func repeatedRequestForSameWindowReplacesPreviousCallback() {
        let coordinator = TabGroupCloseCoordinator()
        let first = makeWindow(at: 0)
        let second = makeWindow(at: 250)
        defer {
            first.close()
            second.close()
        }
        Tako.CustomTabGroup.join(second, to: first, select: false)

        var staleCallbackFired = false
        var latestScope: TabGroupCloseCoordinator.CloseScope?

        coordinator.windowShouldClose(first) { _ in staleCallbackFired = true }
        // Registering again for the same window before the sibling responds
        // must replace the stale callback in closeRequests, not add a second entry.
        coordinator.windowShouldClose(first) { latestScope = $0 }

        waitUntilCoordinator(timeout: 2) { latestScope != nil }

        #expect(!staleCallbackFired)
        #expect(latestScope == .tab)
    }

    @Test func deinitTriggersAnyOutstandingCallbacksAsTabClose() {
        let first = makeWindow(at: 0)
        let second = makeWindow(at: 250)
        defer {
            first.close()
            second.close()
        }
        Tako.CustomTabGroup.join(second, to: first, select: false)

        var scope: TabGroupCloseCoordinator.CloseScope?
        do {
            let coordinator = TabGroupCloseCoordinator()
            coordinator.windowShouldClose(first) { scope = $0 }
            #expect(scope == nil)
        }
        // Coordinator deallocates here, which must flush pending callbacks.
        #expect(scope == .tab)
    }
}
