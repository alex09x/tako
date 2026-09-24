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
private func makeWindow() -> HiddenTitlebarTerminalWindow {
    HiddenTitlebarTerminalWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
}

@MainActor
struct HiddenTitlebarTerminalWindowCoverageTests {
    @Test func awakeFromNibHidesTitlebarChrome() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.tabbingMode == .disallowed)
        }
    }

    @Test func settingTitleReappliesTheHiddenStyle() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.title = "New Title"
            #expect(window.titleVisibility == .hidden)
        }
    }

    @Test func contentLayoutRectFillsTheFullFrame() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let rect = window.contentLayoutRect
        #expect(rect.origin.y == 0)
        #expect(rect.size.height == window.frame.height)
    }

    @Test func fullscreenDidExitIgnoresUnrelatedNotifications() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            NotificationCenter.default.post(name: .fullscreenDidExit, object: NSObject())
            #expect(true)
        }
    }

    @Test func fullscreenDidExitIgnoresNotificationsWithoutAFullscreenObject() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            NotificationCenter.default.post(name: .fullscreenDidExit, object: nil)
            #expect(true)
        }
    }
}
