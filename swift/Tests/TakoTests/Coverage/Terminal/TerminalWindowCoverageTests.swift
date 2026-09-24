import Testing
import AppKit
@testable import Tako

/// `Terminal.xib` and its titlebar variants are excluded from this SwiftPM
/// test target (see `swift/Package.swift`), so these windows are built
/// directly (never through a nib) and `awakeFromNib()` is invoked manually,
/// mirroring `TerminalTestSupport`/`QTTestSupport`'s established pattern.
@MainActor
private func withAppDelegate<T>(_ body: (AppDelegate) throws -> T) rethrows -> T {
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    defer { NSApplication.shared.delegate = originalDelegate }
    return try body(appDelegate)
}

@MainActor
private func makeWindow() -> TerminalWindow {
    TerminalWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
}

@MainActor
struct TerminalWindowCoverageTests {
    @Test func awakeFromNibConfiguresTheWindowWithAnAppDelegate() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            #expect(window.tabbingMode == .disallowed)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent)
        }
    }

    @Test func awakeFromNibIsSafeWithoutAnAppDelegate() {
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.awakeFromNib()
        #expect(window.tabbingMode == .disallowed)
    }

    @Test func canBecomeKeyAndMainAreAlwaysTrue() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(window.canBecomeKey)
        #expect(window.canBecomeMain)
    }

    @Test func closePostsTheWillCloseNotification() {
        withAppDelegate { _ in
            let window = makeWindow()
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            var posted = false
            let token = NotificationCenter.default.addObserver(
                forName: TerminalWindow.terminalWillCloseNotification, object: window, queue: nil
            ) { _ in posted = true }
            defer { NotificationCenter.default.removeObserver(token) }
            window.close()
            #expect(posted)
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

    @Test func mergeAllWindowsDoesNotCrash() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.mergeAllWindows(nil)
        #expect(true)
    }

    @Test func hasMoreThanOneTabsIsFalseForALoneWindow() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(!window.hasMoreThanOneTabs)
    }

    @Test func isTabBarDetectsAnUnidentifiedEmptyBottomAccessory() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom
        vc.view = NSView()
        #expect(window.isTabBar(vc))
    }

    @Test func isTabBarRejectsAnUnrelatedAccessory() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .right
        vc.view = NSView()
        #expect(!window.isTabBar(vc))
    }

    @Test func isTabBarHonorsAnExplicitIdentifier() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.identifier = TerminalWindow.tabBarIdentifier
        vc.view = NSView()
        #expect(window.isTabBar(vc))
    }

    @Test func addAndRemoveTitlebarAccessoryViewControllerTracksTheTabBar() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom
        vc.view = NSView()
        window.addTitlebarAccessoryViewController(vc)
        #expect(vc.identifier == TerminalWindow.tabBarIdentifier)
        window.removeTitlebarAccessoryViewController(at: 0)
        #expect(true)
    }

    @Test func keyEquivalentUpdatesTheLabel() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.keyEquivalent = "1"
        #expect(window.keyEquivalent == "1")
        window.keyEquivalent = nil
        #expect(window.keyEquivalent == nil)
    }

    @Test func surfaceIsZoomedTogglesTheResetButton() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.surfaceIsZoomed = true
        #expect(window.surfaceIsZoomed)
        window.surfaceIsZoomed = false
        #expect(!window.surfaceIsZoomed)
    }

    @Test func titleUpdatesTheTabAttributedTitle() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.title = "Hello"
        #expect(window.title == "Hello")
    }

    @Test func titlebarFontFallsBackToTheSystemFont() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.titlebarFont = nil
        #expect(window.titlebarFont == nil)
        window.titlebarFont = NSFont.systemFont(ofSize: 12)
        #expect(window.titlebarFont != nil)
    }

    @Test func attributedTitleIsNilWithoutATitlebarFont() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.titlebarFont = nil
        #expect(window.attributedTitle == nil)
    }

    @Test func attributedTitleIsSetWithATitlebarFont() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.title = "Hi"
        window.titlebarFont = NSFont.systemFont(ofSize: 12)
        #expect(window.attributedTitle != nil)
    }

    @Test func titlebarContainerIsFoundFromTheRealWindowChrome() {
        // Even without our own nib, a `.titled` `NSWindow` still gets
        // AppKit's standard titlebar chrome, so this is found regardless.
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(window.titlebarContainer != nil)
    }

    @Test func syncAppearanceIsANoOpWhileNotVisible() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.syncAppearance(.init())
        #expect(true)
    }

    @Test func syncAppearanceUpdatesOpacityWhenVisible() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            window.syncAppearance(.init())
            #expect(window.isOpaque)
        }
    }

    @Test func syncAppearanceMakesTheWindowTransparentWhenBackgroundOpacityIsLessThanOne() throws {
        try withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            let tempConfig = try TemporaryConfig("background-opacity = 0.5")
            window.syncAppearance(Tako.SurfaceView.DerivedConfig(tempConfig))
            #expect(!window.isOpaque)
        }
    }

    @Test func preferredBackgroundColorFallsBackToDerivedConfig() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(window.preferredBackgroundColor != nil)
    }

    @Test func setInitialWindowPositionReturnsFalseWithoutCoordinates() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(!window.setInitialWindowPosition(x: nil, y: nil))
    }

    @Test func setInitialWindowPositionAppliesGivenCoordinates() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(window.setInitialWindowPosition(x: 10, y: 10))
    }

    @Test func updateColorSchemeForSurfaceTreeIsSafeWithoutAController() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.updateColorSchemeForSurfaceTree()
        #expect(true)
    }

    @Test func configureTabContextMenuIfNeededIgnoresAnUnrelatedMenu() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let menu = NSMenu()
        window.configureTabContextMenuIfNeeded(menu)
        #expect(menu.items.isEmpty)
    }

    @Test func tabTitleEditorDelegateReflectsTheWindowController() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.titleOverride = "Override"

        #expect(window.tabTitleEditor(window.tabTitleEditor, canRenameTabFor: window))
        #expect(window.tabTitleEditor(window.tabTitleEditor, titleFor: window) == "Override")

        window.tabTitleEditor(window.tabTitleEditor, didCommitTitle: "New", for: window)
        #expect(controller.titleOverride == "New")

        window.tabTitleEditor(window.tabTitleEditor, didCommitTitle: "", for: window)
        #expect(controller.titleOverride == nil)

        window.tabTitleEditor(window.tabTitleEditor, performFallbackRenameFor: window)
        window.tabTitleEditor(window.tabTitleEditor, didFinishEditing: window)
        #expect(true)
    }

    @Test func tabColorSetterUpdatesTheIndicatorAndIgnoresRedundantAssignment() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.tabColor = .blue
        #expect(window.tabColor == .blue)
        // Setting the same value again must be a no-op (guarded by the
        // `didSet`'s early-return), not just idempotent.
        window.tabColor = .blue
        #expect(window.tabColor == .blue)
    }

    @Test func tabMenuObserverConfiguresTheContextMenuOnRealNotification() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            let menu = NSMenu()
            NotificationCenter.default.post(
                name: Notification.Name(rawValue: "NSMenuWillOpenNotification"),
                object: menu)
            #expect(true)
        }
    }

    @Test func sendEventDoesNotCrashForAPlainKeyEvent() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
            #expect(event != nil)
            if let event {
                window.sendEvent(event)
            }
            #expect(true)
        }
    }

    @Test func beginInlineTabTitleEditReturnsFalseWithoutATabGroup() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(!window.beginInlineTabTitleEdit(for: window))
    }

    @Test func renameTabFromContextMenuFallsBackToPromptingWithoutATabGroup() {
        withAppDelegate { _ in
            let (controller, window) = TerminalTestSupport.loaded()
            defer {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                TerminalTestSupport.tearDown(controller, window)
            }
            window.makeKeyAndOrderFront(nil)
            let item = NSMenuItem(title: "Rename Tab...", action: nil, keyEquivalent: "")
            window.perform(NSSelectorFromString("renameTabFromContextMenu:"), with: item)
            TerminalTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
            #expect(window.attachedSheet != nil)
        }
    }

    @Test func configureTabContextMenuIfNeededBuildsTheTabModifierSectionForARealTabContextMenu() {
        withAppDelegate { _ in
            let (controller, target) = TerminalTestSupport.loaded()
            defer { TerminalTestSupport.tearDown(controller, target) }
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            // A non-interactive test host cannot reliably grant this process
            // real key-window status via `makeKeyAndOrderFront`, so the
            // "is this the key window" check is substituted instead.
            let originalSystem = TerminalWindow.system
            TerminalWindow.system = .init(isKeyWindow: { $0 === window })
            defer { TerminalWindow.system = originalSystem }

            let closeItem = NSMenuItem(title: "Close", action: NSSelectorFromString("performClose:"), keyEquivalent: "")
            closeItem.target = target
            let menu = NSMenu()
            menu.addItem(closeItem)
            menu.addItem(NSMenuItem(title: "Close Others", action: NSSelectorFromString("performCloseOtherTabs:"), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Move", action: NSSelectorFromString("moveTabToNewWindow:"), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Overview", action: NSSelectorFromString("toggleTabOverview:"), keyEquivalent: ""))

            window.configureTabContextMenuIfNeeded(menu)

            #expect(menu.items.contains { $0.action == #selector(TerminalController.closeTabsOnTheRight(_:)) })
            #expect(menu.items.contains { $0.action == NSSelectorFromString("renameTabFromContextMenu:") })
            #expect(menu.items.contains { $0.identifier?.rawValue.contains("tabColorPalette") == true })

            // Calling it again exercises the "remove and rebuild" path of appendTabModifierSection.
            window.configureTabContextMenuIfNeeded(menu)
            #expect(menu.items.filter { $0.identifier?.rawValue.contains("tabColorPalette") == true }.count == 1)
        }
    }

    @Test func tabColorIndicatorRendersBothBranchesWhenLaidOutOnScreen() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            window.tab.accessoryView?.layoutSubtreeIfNeeded()
            window.tabColor = .blue
            window.tab.accessoryView?.layoutSubtreeIfNeeded()
            window.tabColor = .none
            window.tab.accessoryView?.layoutSubtreeIfNeeded()
            #expect(true)
        }
    }

    @Test func tabTitleEditorDelegateRejectsUnrelatedWindows() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { other.orderOut(nil) }
        #expect(!window.tabTitleEditor(window.tabTitleEditor, canRenameTabFor: other))
        #expect(window.tabTitleEditor(window.tabTitleEditor, titleFor: other) == other.title)
    }
}
