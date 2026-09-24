import Testing
import AppKit
@testable import Tako

// MARK: Cursor

@MainActor
struct CursorTests {
    private func resetCursor() {
        while Cursor.unhide() {}
    }

    @Test func hideIncrementsCounterAndIsVisibleReflectsIt() {
        resetCursor()
        defer { resetCursor() }

        #expect(Cursor.isVisible)
        Cursor.hide()
        #expect(!Cursor.isVisible)
    }

    @Test func unhideReturnsTrueWhileHiddenAndFalseWhenAlreadyVisible() {
        resetCursor()
        defer { resetCursor() }

        Cursor.hide()
        #expect(Cursor.unhide())
        #expect(Cursor.isVisible)
        #expect(!Cursor.unhide())
    }

    @Test func unhideCompletelyClearsAllOutstandingHides() {
        resetCursor()
        defer { resetCursor() }

        Cursor.hide()
        Cursor.hide()
        Cursor.hide()
        let cleared = Cursor.unhideCompletely()
        #expect(cleared == 3)
        #expect(Cursor.isVisible)
    }

    @Test func unhideCompletelyOnAlreadyVisibleReturnsZero() {
        resetCursor()
        defer { resetCursor() }
        #expect(Cursor.unhideCompletely() == 0)
    }

    @Test func everyCursorStyleResolvesToANonNilNSCursor() {
        let styles: [CursorStyle] = [
            .default, .grabIdle, .grabActive, .horizontalText, .verticalText, .link,
            .resizeLeft, .resizeRight, .resizeUp, .resizeDown, .resizeUpDown, .resizeLeftRight,
            .contextMenu, .crosshair, .operationNotAllowed,
        ]
        for style in styles {
            _ = style.cursor // Must not crash; NSCursor is always non-optional here.
        }
        #expect(CursorStyle.default.cursor == .arrow)
        #expect(CursorStyle.link.cursor == .pointingHand)
        #expect(CursorStyle.crosshair.cursor == .crosshair)
    }
}

// MARK: ExpiringUndoManager

@MainActor
struct ExpiringUndoManagerTests {
    private final class Target {}

    @Test func registeredUndoCanBeInvokedBeforeExpiry() {
        let manager = ExpiringUndoManager()
        let target = Target()
        var invoked = false

        manager.registerUndo(withTarget: target, expiresAfter: .seconds(30)) { _ in
            invoked = true
        }

        #expect(manager.canUndo)
        manager.undo()
        #expect(invoked)
    }

    @Test func zeroDurationRegistrationIsIgnored() {
        let manager = ExpiringUndoManager()
        let target = Target()
        manager.registerUndo(withTarget: target, expiresAfter: .zero) { _ in
            Issue.record("Should never run for an instantly-expiring undo")
        }
        #expect(!manager.canUndo)
    }

    @Test func disabledRegistrationDoesNotRecordAnything() {
        let manager = ExpiringUndoManager()
        let target = Target()
        manager.disableUndoRegistration()
        manager.registerUndo(withTarget: target, expiresAfter: .seconds(30)) { _ in }
        manager.enableUndoRegistration()
        #expect(!manager.canUndo)
    }

    @Test func removeAllActionsClearsExpiringTargets() {
        let manager = ExpiringUndoManager()
        let target = Target()
        manager.registerUndo(withTarget: target, expiresAfter: .seconds(30)) { _ in }
        #expect(manager.canUndo)
        manager.removeAllActions()
        #expect(!manager.canUndo)
    }

    @Test func removeAllActionsWithTargetClearsOnlyThatTargetsActions() {
        let manager = ExpiringUndoManager()
        let targetA = Target()
        let targetB = Target()
        manager.registerUndo(withTarget: targetA, expiresAfter: .seconds(30)) { _ in }
        manager.registerUndo(withTarget: targetB, expiresAfter: .seconds(30)) { _ in }
        #expect(manager.canUndo)

        manager.removeAllActions(withTarget: targetA)
        // targetB's undo should still be invocable.
        var invokedB = false
        manager.registerUndo(withTarget: targetB, expiresAfter: .seconds(30)) { _ in invokedB = true }
        manager.undo()
        #expect(invokedB)
    }

    @Test func registrationExpiresAfterDurationElapses() async throws {
        let manager = ExpiringUndoManager()
        let target = Target()
        manager.registerUndo(withTarget: target, expiresAfter: .milliseconds(50)) { _ in
            Issue.record("Should not run once expired")
        }
        #expect(manager.canUndo)

        let deadline = Date().addingTimeInterval(2)
        while manager.canUndo && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        #expect(!manager.canUndo)
    }
}

// MARK: LastWindowPosition

@MainActor
struct LastWindowPositionTests {
    private func withIsolatedDefaults<T>(_ body: () throws -> T) rethrows -> T {
        let suiteName = "com.tako-core.coverage-lastwindow-\(UUID().uuidString)"
        setenv("TAKO_USER_DEFAULTS_SUITE", suiteName, 1)
        defer {
            unsetenv("TAKO_USER_DEFAULTS_SUITE")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return try body()
    }

    private func makeWindow() -> NSWindow {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: NSRect(x: frame.minX + 20, y: frame.minY + 20, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func saveReturnsFalseWhenWindowNotVisible() {
        withIsolatedDefaults {
            let window = makeWindow()
            #expect(!window.isVisible)
            #expect(LastWindowPosition.shared.save(window) == false)
        }
    }

    @Test func saveReturnsFalseForNilWindow() {
        withIsolatedDefaults {
            #expect(LastWindowPosition.shared.save(nil) == false)
        }
    }

    @Test func saveAndRestoreRoundTripsFrame() {
        withIsolatedDefaults {
            let source = makeWindow()
            source.orderFrontRegardless()
            defer { source.close() }

            // Kept comfortably inside the screen's visible frame: restore()
            // additionally clamps to visibleFrame, and a frame that doesn't
            // fit would make that clamp (rather than the plain assignment)
            // the thing under test.
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let savedFrame = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 320, height: 220)
            source.setFrame(savedFrame, display: true)

            #expect(LastWindowPosition.shared.save(source))

            let target = makeWindow()
            defer { target.close() }
            let changed = LastWindowPosition.shared.restore(target)
            #expect(changed)
            #expect(target.frame.origin.x == savedFrame.origin.x)
            #expect(target.frame.origin.y == savedFrame.origin.y)
        }
    }

    @Test func restoreWithBothFlagsFalseIsNoOp() {
        withIsolatedDefaults {
            let target = makeWindow()
            defer { target.close() }
            #expect(LastWindowPosition.shared.restore(target, origin: false, size: false) == false)
        }
    }

    @Test func restoreWithoutSavedValueReturnsFalse() {
        withIsolatedDefaults {
            let target = makeWindow()
            defer { target.close() }
            #expect(LastWindowPosition.shared.restore(target) == false)
        }
    }

    @Test func restoreOnlyOriginKeepsExistingSize() {
        withIsolatedDefaults {
            let source = makeWindow()
            source.orderFrontRegardless()
            defer { source.close() }
            source.setFrame(NSRect(x: 50, y: 60, width: 400, height: 300), display: true)
            #expect(LastWindowPosition.shared.save(source))

            let target = makeWindow()
            defer { target.close() }
            let originalSize = target.frame.size
            _ = LastWindowPosition.shared.restore(target, origin: true, size: false)
            #expect(target.frame.size == originalSize)
        }
    }
}

// MARK: KeyboardLayout

struct KeyboardLayoutTests {
    @Test func idReturnsCurrentInputSourceIdentifier() {
        let id = KeyboardLayout.id
        #expect(id != nil)
        #expect(id?.isEmpty == false)
    }
}

// MARK: CodableBridge

struct CodableBridgeTests {
    private struct Payload: Codable, Equatable {
        let name: String
        let count: Int
    }

    @Test func encodeDecodeRoundTripsThroughNSKeyedArchiver() throws {
        let bridge = CodableBridge(Payload(name: "coverage", count: 42))
        #expect(CodableBridge<Payload>.supportsSecureCoding)

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(bridge, forKey: "root")
        let data = archiver.encodedData

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        let decoded = unarchiver.decodeObject(of: CodableBridge<Payload>.self, forKey: "root")

        #expect(decoded?.value == Payload(name: "coverage", count: 42))
    }

    @Test func decodingWithoutStoredDataKeyFailsGracefully() throws {
        struct Broken: Codable {}
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode("unrelated", forKey: "other")
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        let decoded = CodableBridge<Broken>(coder: unarchiver)
        #expect(decoded == nil)
    }
}
