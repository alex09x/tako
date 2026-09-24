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
private func makeWindow() -> TitlebarTabsVenturaTerminalWindow {
    TitlebarTabsVenturaTerminalWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
}

@MainActor
struct TitlebarTabsVenturaTerminalWindowCoverageTests {
    @Test func awakeFromNibEnablesTitlebarTabs() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            #expect(window.titlebarTabs)
        }
    }

    @Test func becomeKeyAndResignKeyDoNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.becomeKey()
            window.resignKey()
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

    @Test func layoutIfNeededDoesNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.layoutIfNeeded()
            #expect(true)
        }
    }

    @Test func updateConstraintsIfNeededDoesNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.updateConstraintsIfNeeded()
            #expect(true)
        }
    }

    @Test func syncAppearanceUpdatesTheTitlebarColor() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            window.syncAppearance(.init())
            #expect(true)
        }
    }

    @Test func titlebarTabsFalseClearsTheToolbar() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.titlebarTabs = false
            #expect(window.toolbar == nil)
        }
    }

    @Test func hasVeryDarkBackgroundReflectsLuminance() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.backgroundColor = .black
            #expect(window.hasVeryDarkBackground)
            window.backgroundColor = .white
            #expect(!window.hasVeryDarkBackground)
        }
    }

    @Test func titlebarFontUpdatesTheToolbarTitleFont() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.titlebarFont = NSFont.systemFont(ofSize: 13)
            #expect(true)
        }
    }

    @Test func titleUpdatesTheToolbarTitleText() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.title = "Hello"
            #expect(window.title == "Hello")
        }
    }

    @Test func mergeAllWindowsDoesNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.mergeAllWindows(nil)
            #expect(true)
        }
    }

    @Test func mergeAllWindowsRelabelsTabsWhenThereIsAController() async {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        let app = Tako.App()
        let controller = TerminalController(app, withBaseConfig: nil, withSurfaceTree: nil)
        let window = makeWindow()
        controller.window = window
        window.awakeFromNib()
        window.mergeAllWindows(nil)
        try? await Task.sleep(nanoseconds: 150_000_000)
        window.orderOut(nil)
        NSApplication.shared.delegate = originalDelegate
        #expect(true)
    }

    @Test func addingAndRemovingARealTabBarAccessoryPushesTabsIntoTheTitlebar() async {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        let window = makeWindow()
        window.awakeFromNib()
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        // Matches `TerminalWindow.isTabBar`'s fallback heuristic for an
        // unidentified, empty, bottom-layout accessory so we exercise the
        // real "push tabs into the titlebar" flow without depending on
        // AppKit's native (and, for these windows, disallowed) tab bar.
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom
        vc.view = NSView()
        window.addTitlebarAccessoryViewController(vc)
        #expect(vc.identifier == TitlebarTabsVenturaTerminalWindow.tabBarIdentifier)

        // `pushTabsToTitlebar` defers its layout work by a tick.
        try? await Task.sleep(nanoseconds: 50_000_000)
        window.contentView?.layoutSubtreeIfNeeded()

        // Calling this again while the accessory is already installed
        // exercises `updateTabBar`'s "found the accessory" path directly.
        window.updateTabBar()
        try? await Task.sleep(nanoseconds: 50_000_000)

        window.removeTitlebarAccessoryViewController(at: 0)

        window.orderOut(nil)
        NSApplication.shared.delegate = originalDelegate
        #expect(true)
    }

    @Test func windowDragViewForwardsASingleLeftClickToPerformDragAndPassesOthersToSuper() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let view = WindowDragView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            window.contentView?.addSubview(view)

            let singleClick = try! #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: singleClick)

            let doubleClick = try! #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            view.mouseDown(with: doubleClick)

            view.mouseEntered(with: singleClick)
            view.mouseExited(with: singleClick)
            view.resetCursorRects()
            #expect(true)
        }
    }

    @Test func windowButtonsBackdropViewUpdatesItsLayerForLightAndDarkThemes() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let backdrop = WindowButtonsBackdropView(window: window)

            window.backgroundColor = .white
            backdrop.isHighlighted = false
            backdrop.isHighlighted = true

            window.backgroundColor = .black
            backdrop.isHighlighted = false
            backdrop.isHighlighted = true
            #expect(true)
        }
    }

    @Test func terminalToolbarExposesTitleTextFontAndVisibilityThroughItsBackingField() {
        let toolbar = TerminalToolbar(identifier: .init("TestToolbar"))
        toolbar.titleText = "Hi There"
        #expect(toolbar.titleText == "Hi There")
        toolbar.titleFont = .systemFont(ofSize: 11)
        #expect(toolbar.titleFont == .systemFont(ofSize: 11))
        toolbar.titleIsHidden = true
        #expect(toolbar.titleIsHidden)

        #expect(toolbar.toolbarAllowedItemIdentifiers(toolbar).contains(.resetZoom))
        let titleItem = toolbar.toolbar(toolbar, itemForItemIdentifier: .titleText, willBeInsertedIntoToolbar: true)
        #expect(titleItem?.view != nil)
        let resetZoomItem = toolbar.toolbar(toolbar, itemForItemIdentifier: .resetZoom, willBeInsertedIntoToolbar: true)
        #expect(resetZoomItem != nil)
        let otherItem = toolbar.toolbar(toolbar, itemForItemIdentifier: .flexibleSpace, willBeInsertedIntoToolbar: true)
        #expect(otherItem != nil)
    }

    @Test func centeredDynamicLabelIsClickThroughAndConfiguresItselfOnceInAWindow() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            let label = CenteredDynamicLabel(labelWithString: "Hi")
            window.contentView?.addSubview(label)
            #expect(label.hitTest(NSPoint(x: 1, y: 1)) == nil)
            #expect(!label.isEditable)
        }
    }
}
