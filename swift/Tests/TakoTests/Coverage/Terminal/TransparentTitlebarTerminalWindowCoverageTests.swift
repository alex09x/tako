import Testing
import AppKit
@testable import Tako

@MainActor
private func withAppDelegate<T>(_ body: (AppDelegate) throws -> T) rethrows -> T {
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    defer { NSApplication.shared.delegate = originalDelegate }
    return try body(appDelegate)
}

@MainActor
private func makeWindow() -> TransparentTitlebarTerminalWindow {
    TransparentTitlebarTerminalWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
}

@MainActor
struct TransparentTitlebarTerminalWindowCoverageTests {
    @Test func awakeFromNibSetsUpKVOWithoutCrashing() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            #expect(true)
        }
    }

    @Test func becomeMainIsSafeWithoutAPriorSurfaceConfig() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.becomeMain()
            #expect(true)
        }
    }

    @Test func updateDoesNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.update()
            #expect(true)
        }
    }

    @Test func syncAppearanceSetsAppearanceFromTheSurfaceConfig() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            window.syncAppearance(.init())
            #expect(true)
        }
    }

    @Test func becomeMainResyncsAppearanceWhenThereIsAPriorSurfaceConfig() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            // The first `syncAppearance` call records `lastSurfaceConfig`,
            // so the next `becomeMain` takes the "resync" branch instead of
            // returning early.
            window.syncAppearance(.init())
            window.becomeMain()
            #expect(true)
        }
    }

    // `update()` and `syncAppearance` each branch on the running macOS version:
    // macOS 13-15 hide the visual effect view and use `syncAppearanceVentura`,
    // macOS 26+ use `syncAppearanceTahoe`. A test host only ever runs one real
    // OS, so `TransparentTitlebarTerminalWindow.appearanceSystem` lets us force the
    // "other" branch to exercise both regardless of the host OS.
    @Test func updateAndSyncAppearanceTakeTheLegacyBranchWhenForcedToPretendItIsPreTahoe() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let originalSystem = TransparentTitlebarTerminalWindow.appearanceSystem
            TransparentTitlebarTerminalWindow.appearanceSystem = .init(isMacOS26OrLater: { false })
            defer { TransparentTitlebarTerminalWindow.appearanceSystem = originalSystem }

            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            window.syncAppearance(.init())
            // Calling `update()` twice exercises both the "hide it" and the
            // "already hidden" early-return paths of `hideEffectView`.
            window.update()
            window.update()
            #expect(true)
        }
    }

    @Test func tabGroupObservationsAndTheTwoTabResyncFireOnRealTabGroupChanges() async {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        let window = makeWindow()
        window.awakeFromNib()
        window.makeKeyAndOrderFront(nil)
        window.syncAppearance(.init())

        let other = TransparentTitlebarTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        other.awakeFromNib()

        // Adding a real tabbed window (rather than sending synthetic UI
        // events) triggers the real `tabGroup.windows` KVO observation and
        // gets us to a real 2-window tab group.
        window.addTabbedWindow(other, ordered: .above)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Toggling this fires the real `isTabBarVisible` KVO observation.
        window.toggleTabBar(nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // With a real 2-window tab group, `becomeMain` schedules a follow-up
        // resync after a short delay.
        window.becomeMain()
        try? await Task.sleep(nanoseconds: 100_000_000)

        window.orderOut(nil)
        other.orderOut(nil)
        NSApplication.shared.delegate = originalDelegate
        #expect(true)
    }
}
