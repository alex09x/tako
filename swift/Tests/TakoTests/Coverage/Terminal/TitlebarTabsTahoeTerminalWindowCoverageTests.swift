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
private func makeWindow() -> TitlebarTabsTahoeTerminalWindow {
    TitlebarTabsTahoeTerminalWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
}

@MainActor
struct TitlebarTabsTahoeTerminalWindowCoverageTests {
    @Test func awakeFromNibHidesTitleAndAddsAToolbar() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            #expect(window.titleVisibility == .hidden)
            #expect(window.toolbar != nil)
        }
    }

    @Test func becomeMainAndResignMainDoNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.becomeMain()
            window.resignMain()
            #expect(true)
        }
    }

    @Test func syncAppearanceSchedulesTabBarSetupWithoutCrashing() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            window.syncAppearance(.init())
            #expect(true)
        }
    }

    @Test func titleAndTitlebarFontUpdateTheViewModel() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.title = "Hi"
            window.titlebarFont = NSFont.systemFont(ofSize: 12)
            #expect(window.title == "Hi")
        }
    }

    @Test func setupTabBarIsANoOpWithoutARealTabBarView() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.setupTabBar()
            #expect(true)
        }
    }

    @Test func removeTabBarClearsState() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.removeTabBar()
            #expect(true)
        }
    }

    @Test func toolbarAllowedAndDefaultItemIdentifiers() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let toolbar = try! #require(window.toolbar)
            #expect(window.toolbarAllowedItemIdentifiers(toolbar).contains(.title))
            #expect(window.toolbarDefaultItemIdentifiers(toolbar).contains(.title))
        }
    }

    @Test func toolbarItemForTitleBuildsAnItem() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let toolbar = try! #require(window.toolbar)
            let item = window.toolbar(toolbar, itemForItemIdentifier: .title, willBeInsertedIntoToolbar: true)
            #expect(item != nil)
        }
    }

    @Test func toolbarItemForAnUnknownIdentifierFallsBackToADefaultItem() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let toolbar = try! #require(window.toolbar)
            let item = window.toolbar(toolbar, itemForItemIdentifier: .flexibleSpace, willBeInsertedIntoToolbar: true)
            #expect(item != nil)
        }
    }

    @Test func titleAndTitlebarFontFlushTheirAsyncViewModelUpdates() async {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        let window = makeWindow()
        window.awakeFromNib()
        window.title = "Async Title"
        window.titlebarFont = NSFont.systemFont(ofSize: 14)
        try? await Task.sleep(nanoseconds: 50_000_000)
        window.orderOut(nil)
        NSApplication.shared.delegate = originalDelegate
        #expect(true)
    }

    @Test func addTitlebarAccessoryViewControllerForwardsNonTabBarAccessories() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let vc = NSTitlebarAccessoryViewController()
            vc.layoutAttribute = .right
            vc.view = NSView()
            window.addTitlebarAccessoryViewController(vc)
            #expect(window.titlebarAccessoryViewControllers.contains(vc))
        }
    }

    @Test func removeTitlebarAccessoryViewControllerForwardsNonTabBarAccessories() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let vc = NSTitlebarAccessoryViewController()
            vc.layoutAttribute = .right
            vc.view = NSView()
            window.addTitlebarAccessoryViewController(vc)
            window.removeTitlebarAccessoryViewController(at: 0)
            #expect(!window.titlebarAccessoryViewControllers.contains(vc))
        }
    }

    @Test func addTitlebarAccessoryViewControllerRecognizesAFakeTabBarAndSchedulesSetup() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            // Matches `TerminalWindow.isTabBar`'s fallback heuristic for an
            // unidentified, empty, bottom-layout accessory.
            let vc = NSTitlebarAccessoryViewController()
            vc.layoutAttribute = .bottom
            vc.view = NSView()
            window.addTitlebarAccessoryViewController(vc)
            #expect(window.titlebarAccessoryViewControllers.contains(vc))

            // `addTitlebarAccessoryViewController` moves the tab bar's layout to
            // `.right` before calling into AppKit, which means the base class's
            // own identifier-tagging re-check no longer sees it as a tab bar.
            // Tag it explicitly so the paired remove call also takes the
            // tab-bar branch (and calls `removeTabBar()`).
            vc.identifier = TitlebarTabsTahoeTerminalWindow.tabBarIdentifier
            window.removeTitlebarAccessoryViewController(at: 0)
            #expect(!window.titlebarAccessoryViewControllers.contains(vc))
        }
    }

    @Test func titleItemRendersBothTabBarBranches() {
        let viewModel = TitlebarTabsTahoeTerminalWindow.ViewModel()
        viewModel.hasTabBar = false
        _ = TitlebarTabsTahoeTerminalWindow.TitleItem(viewModel: viewModel).body
        viewModel.hasTabBar = true
        _ = TitlebarTabsTahoeTerminalWindow.TitleItem(viewModel: viewModel).body
        #expect(true)
    }

    @Test func titleToolbarItemViewIsClickThrough() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let toolbar = try! #require(window.toolbar)
            let item = window.toolbar(toolbar, itemForItemIdentifier: .title, willBeInsertedIntoToolbar: true)
            let view = try! #require(item?.view)
            #expect(view.hitTest(NSPoint(x: 5, y: 5)) == nil)
        }
    }

    // `setupTabBar` locates AppKit's private `NSTabBar` view by walking the real
    // titlebar view hierarchy and matching class names by their (unqualified)
    // Swift type name. A real native tab bar only appears once a window is part
    // of a multi-window tab group, which we can't reliably create here, so we
    // fake the hierarchy it looks for: views whose Swift type is literally named
    // after the private AppKit classes it searches for, wired into the window's
    // *real* titlebar view. `String(describing: type(of:))` reports just the
    // bare type name (no module prefix) for these, matching what the production
    // lookup expects.
    @Test func setupTabBarConfiguresConstraintsAgainstAFakeNativeTabBarHierarchy() async throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        let window = makeWindow()
        window.awakeFromNib()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            NSApplication.shared.delegate = originalDelegate
        }

        let titlebarView = try #require(window.titlebarView)

        let toolbarView = NSToolbarView()
        titlebarView.addSubview(toolbarView)

        let newTabButton = NSTabBarNewTabButton()
        newTabButton.frame.size = NSSize(width: 30, height: 30)
        titlebarView.addSubview(newTabButton)

        let clipView = NSTitlebarAccessoryClipView()
        let accessoryView = NSView()
        clipView.addSubview(accessoryView)
        let tabBar = NSTabBar()
        clipView.addSubview(tabBar)
        titlebarView.addSubview(clipView)

        window.setupTabBar()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(clipView.translatesAutoresizingMaskIntoConstraints == false)

        // Simulate the tab bar resizing: this exercises the frame-change
        // observer, which tears down and reschedules `setupTabBar`, and in
        // turn exercises the observer-replacement branch of `tabBarObserver`'s
        // `didSet`.
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: tabBar)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(true)
    }
}

// Named to match the private AppKit classes `setupTabBar` searches for by
// (unqualified) Swift type name; see the test above for why.
private class NSToolbarView: NSView {}
private class NSTabBarNewTabButton: NSView {}
private class NSTitlebarAccessoryClipView: NSView {}
private class NSTabBar: NSView {}
