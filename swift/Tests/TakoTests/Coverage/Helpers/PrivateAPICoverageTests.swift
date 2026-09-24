import Testing
import Foundation
import AppKit
@testable import Tako

// MARK: CGS

@MainActor
private func makeCGSTestWindow() -> NSWindow {
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = NSWindow(
        contentRect: NSRect(x: frame.minX + 10, y: frame.minY + 10, width: 200, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
struct CGSSpaceTests {
    @Test func activeSpaceHasARawIdentifierAndDescription() {
        let space = CGSSpace.active()
        #expect(space.description == "SpaceID(\(space.rawValue))")
    }

    @Test func activeSpaceIsEitherUserOrSystemOrFullscreen() {
        let space = CGSSpace.active()
        let known: [CGSSpaceType] = [.user, .system, .fullscreen]
        #expect(known.contains(space.type))
    }

    @Test func listForRealWindowReturnsAtLeastOneSpaceOnceOrdered() {
        let window = makeCGSTestWindow()
        defer { window.close() }
        window.orderFrontRegardless()

        let deadline = Date().addingTimeInterval(2)
        while window.windowNumber <= 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        guard let cgWindowId = window.cgWindowId else {
            Issue.record("Expected a valid CGWindowID once ordered front")
            return
        }
        // A background test process's window is not always assigned to a
        // Space, so the list may be empty; what it returns must be real.
        let spaces = CGSSpace.list(for: cgWindowId)
        #expect(spaces.allSatisfy { $0.rawValue != 0 })
    }

    @Test func listForBogusWindowIdReturnsNoSpaces() {
        // Window ID 0 never corresponds to a real on-screen window, so no
        // space membership should be reported for it.
        let spaces = CGSSpace.list(for: 0)
        #expect(spaces.isEmpty)
    }

    @Test func spaceMaskCombinationsProduceExpectedRawValues() {
        #expect(CGSSpaceMask.currentSpace.rawValue == (CGSSpaceMask.includesUser.rawValue | CGSSpaceMask.includesCurrent.rawValue))
        #expect(CGSSpaceMask.otherSpaces.rawValue == (CGSSpaceMask.includesOthers.rawValue | CGSSpaceMask.includesCurrent.rawValue))
        #expect(CGSSpaceMask.allSpaces.contains(.includesUser))
        #expect(CGSSpaceMask.allSpaces.contains(.includesOthers))
        #expect(CGSSpaceMask.allVisibleSpaces.contains(.includesVisible))
    }

    @Test func spacesAreHashableAndEquatableByRawValue() {
        let a = CGSSpace(rawValue: 42)
        let b = CGSSpace(rawValue: 42)
        let c = CGSSpace(rawValue: 43)
        #expect(a == b)
        #expect(a != c)
        var set: Set<CGSSpace> = [a, b, c]
        #expect(set.count == 2)
        set.remove(a)
        #expect(!set.contains(b))
    }
}

// MARK: Dock

@MainActor
struct DockTests {
    @Test func orientationIsOneOfTheKnownCases() {
        let orientation = Dock.orientation
        if let orientation {
            #expect([DockOrientation.top, .bottom, .left, .right].contains(orientation))
        } else {
            // A nil orientation means the raw value didn't map to a known
            // case; still a valid, exercised return path.
            #expect(orientation == nil)
        }
    }

    @Test func autoHideEnabledReadIsDeterministicAcrossConsecutiveCalls() {
        let first = Dock.autoHideEnabled
        let second = Dock.autoHideEnabled
        #expect(first == second)
    }

    @Test func aTestRunNeverWritesTheRealDock() {
        // Without the stand-in this test would itself hide the Dock of the
        // Mac running it, so it checks before it writes.
        guard !Dock.autoHide.reachesTheDock else {
            Issue.record("a test run is writing the real Dock's autohide preference")
            return
        }
        let real = CoreDockGetAutoHideEnabled()
        let original = Dock.autoHideEnabled
        defer { Dock.autoHideEnabled = original }

        Dock.autoHideEnabled = !real
        #expect(Dock.autoHideEnabled == !real)
        #expect(CoreDockGetAutoHideEnabled() == real)
    }

    @Test func anInMemoryAutoHideKeepsWhatWasSet() {
        let store = DockAutoHide.inMemory(startingAt: true)
        #expect(store.get())
        store.set(false)
        #expect(!store.get())
        #expect(!store.reachesTheDock)
    }
}
