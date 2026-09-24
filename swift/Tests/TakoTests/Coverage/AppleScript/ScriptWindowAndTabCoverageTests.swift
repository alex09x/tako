import Testing
import AppKit
@testable import Tako

// `ScriptWindow`/`ScriptTab`: the AppleScript-facing wrappers around a
// logical window (one per native tab group) and the tabs inside it.

@Suite(.serialized)
@MainActor
struct ScriptWindowCoverageTests {
    @Test func propertiesAreBlankWhenAppleScriptIsDisabled() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        ASTestSupport.setAppleScriptEnabled(false)
        let scriptWindow = ScriptWindow(primaryController: controller)

        #expect(scriptWindow.idValue == "")
        #expect(scriptWindow.title == "")
        #expect(scriptWindow.tabs.isEmpty)
        #expect(scriptWindow.selectedTab == nil)
        #expect(scriptWindow.valueInTabs(uniqueID: "anything") == nil)
        #expect(scriptWindow.terminals.isEmpty)
        #expect(scriptWindow.valueInTerminals(uniqueID: "anything") == nil)
        #expect(scriptWindow.tabIndex(for: controller) == nil)
        #expect(scriptWindow.tabIsSelected(controller) == false)
        #expect(scriptWindow.preferredParentWindow == nil)
        #expect(scriptWindow.preferredController == nil)
        #expect(scriptWindow.objectSpecifier == nil)
    }

    @Test func aStandaloneWindowHasOneTabMatchingItsOwnController() throws {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        let scriptWindow = ScriptWindow(primaryController: controller)
        #expect(scriptWindow.idValue == scriptWindow.stableID)
        #expect(scriptWindow.title == window.title)
        #expect(scriptWindow.tabs.count == 1)
        #expect(scriptWindow.tabIndex(for: controller) == 1)
        #expect(scriptWindow.tabIsSelected(controller))
        #expect(scriptWindow.preferredParentWindow === window)
        #expect(scriptWindow.preferredController === controller)

        let selected = try #require(scriptWindow.selectedTab)
        #expect(selected.parentController === controller)

        let tabID = ScriptTab.stableID(controller: controller)
        #expect(scriptWindow.valueInTabs(uniqueID: tabID)?.parentController === controller)
        #expect(scriptWindow.valueInTabs(uniqueID: "not-a-real-id") == nil)
    }

    @Test func joinedWindowsExposeAllTabsAndTerminalsInGroupOrder() throws {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controllerA, windowA) = ASTestSupport.makeTerminalController(appDelegate.tako)
        let (controllerB, windowB) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            windowA.close()
            windowB.close()
            restore()
        }

        Tako.CustomTabGroup.join(windowB, to: windowA, select: true)
        let scriptWindow = ScriptWindow(primaryController: controllerA)

        #expect(scriptWindow.tabs.count == 2)
        #expect(scriptWindow.tabIndex(for: controllerA) == 1)
        #expect(scriptWindow.tabIndex(for: controllerB) == 2)
        #expect(scriptWindow.tabIsSelected(controllerB))
        #expect(!scriptWindow.tabIsSelected(controllerA))

        let terminalIDs = Set(scriptWindow.terminals.map(\.stableID))
        let surfaceAIDs = Set(controllerA.surfaceTree.root!.leaves().map { $0.id.uuidString })
        let surfaceBIDs = Set(controllerB.surfaceTree.root!.leaves().map { $0.id.uuidString })
        #expect(terminalIDs == surfaceAIDs.union(surfaceBIDs))

        let surfaceB = try #require(controllerB.surfaceTree.root?.leaves().first)
        #expect(scriptWindow.valueInTerminals(uniqueID: surfaceB.id.uuidString)?.stableID == surfaceB.id.uuidString)
        #expect(scriptWindow.valueInTerminals(uniqueID: "not-a-real-id") == nil)
    }

    @Test func objectSpecifierIsEitherNilOrAUniqueIDSpecifier() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        let specifier = ScriptWindow(primaryController: controller).objectSpecifier
        #expect(specifier == nil || specifier is NSUniqueIDSpecifier)
    }

    @Test func stableIDFallsBackToControllerIdentityWhenThereIsNoWindow() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }

        let controller = TerminalController(appDelegate.tako, withBaseConfig: nil)
        let id = ScriptWindow.stableID(primaryController: controller)
        #expect(id.hasPrefix("controller-"))
    }

    @Test func activateWindowFailsWhenTheWindowIsNoLongerAvailable() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }

        let controller = TerminalController(appDelegate.tako, withBaseConfig: nil)
        let scriptWindow = ScriptWindow(primaryController: controller)

        let command = ASTestSupport.nsScriptCommand()
        #expect(scriptWindow.handleActivateWindow(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
        #expect(command.scriptErrorString == "Window is no longer available.")
    }

    @Test func activateWindowSelectsItsPreferredWindowInsideItsTabGroup() {
        // `ScriptWindow` represents a whole tab group, so "activate window"
        // brings forward whichever tab is currently selected in that group
        // (`preferredParentWindow`) -- per-tab activation is `ScriptTab`'s
        // job (`handleSelectTab`, covered below).
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controllerA, windowA) = ASTestSupport.makeTerminalController(appDelegate.tako)
        let (_, windowB) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            windowA.close()
            windowB.close()
            restore()
        }

        // B joins and becomes selected, so the group's selection moves off A.
        Tako.CustomTabGroup.join(windowB, to: windowA, select: true)
        #expect(Tako.CustomTabGroup.group(for: windowA).selectedWindow === windowB)

        // Deselect B by selecting A directly, then ask the group's
        // `ScriptWindow` to activate: it should reassert whatever is
        // currently preferred (A, since it's `preferredController`'s window
        // when nothing else is selected) without erroring.
        Tako.CustomTabGroup.group(for: windowA).select(windowA)
        let scriptWindowA = ScriptWindow(primaryController: controllerA)
        let command = ASTestSupport.nsScriptCommand()
        #expect(scriptWindowA.handleActivateWindow(command) == nil)
        #expect(command.scriptErrorNumber == 0)
        #expect(Tako.CustomTabGroup.group(for: windowA).selectedWindow === windowA)
    }

    @Test func closeWindowFailsWhenTheWindowIsNoLongerAvailable() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }

        // `ScriptWindow.primaryController` is weak: a `TerminalController`
        // with no window still resolves to itself as `preferredController`
        // (see `ScriptWindow.controllers`), so `handleCloseWindow` would take
        // its "managed controller" shortcut and no-op instead of failing.
        // Letting the controller itself deallocate is what actually drives
        // `preferredController` to `nil` and reaches the error path.
        let scriptWindow: ScriptWindow = autoreleasepool {
            let controller = TerminalController(appDelegate.tako, withBaseConfig: nil)
            return ScriptWindow(primaryController: controller)
        }

        let command = ASTestSupport.nsScriptCommand()
        #expect(scriptWindow.handleCloseWindow(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
        #expect(command.scriptErrorString == "Window is no longer available.")
    }

    @Test func closeWindowClosesATerminalControllerImmediately() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer { restore() }

        let scriptWindow = ScriptWindow(primaryController: controller)
        let command = ASTestSupport.nsScriptCommand()
        #expect(scriptWindow.handleCloseWindow(command) == nil)
        #expect(!window.isVisible)
    }

    @Test func closeWindowClosesANonTerminalControllerDirectly() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }

        let scriptWindow = ScriptWindow(primaryController: controller)
        let command = ASTestSupport.nsScriptCommand()
        #expect(scriptWindow.handleCloseWindow(command) == nil)
        #expect(!window.isVisible)
    }

    @Test func everyCommandBailsWhenAppleScriptIsDisabled() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        ASTestSupport.setAppleScriptEnabled(false)
        let scriptWindow = ScriptWindow(primaryController: controller)
        #expect(scriptWindow.handleActivateWindow(ASTestSupport.nsScriptCommand()) == nil)
        #expect(scriptWindow.handleCloseWindow(ASTestSupport.nsScriptCommand()) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct ScriptTabCoverageTests {
    @Test func propertiesAreBlankWhenAppleScriptIsDisabled() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        let scriptWindow = ScriptWindow(primaryController: controller)
        ASTestSupport.setAppleScriptEnabled(false)
        let tab = ScriptTab(window: scriptWindow, controller: controller)

        #expect(tab.idValue == "")
        #expect(tab.title == "")
        #expect(tab.index == 0)
        #expect(!tab.selected)
        #expect(tab.focusedTerminal == nil)
        #expect(tab.parentWindow == nil)
        #expect(tab.parentController == nil)
        #expect(tab.terminals.isEmpty)
        #expect(tab.valueInTerminals(uniqueID: "anything") == nil)
        #expect(tab.objectSpecifier == nil)
    }

    @Test func propertiesReflectTheLiveControllerWhenEnabled() throws {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        let scriptWindow = ScriptWindow(primaryController: controller)
        let tab = ScriptTab(window: scriptWindow, controller: controller)

        #expect(tab.idValue == ScriptTab.stableID(controller: controller))
        #expect(tab.title == window.title)
        #expect(tab.index == 1)
        #expect(tab.selected)
        #expect(tab.parentWindow === window)
        #expect(tab.parentController === controller)

        // A window's single initial surface is already `focusedSurface` the
        // moment the window loads (`TerminalController.windowDidLoad` forces
        // focus onto the first leaf), so `tab.focusedTerminal` reflects it
        // immediately -- no separate focus call is needed to observe this.
        let surface = try #require(controller.surfaceTree.root?.leaves().first)
        #expect(tab.focusedTerminal?.stableID == surface.id.uuidString)

        let terminalIDs = tab.terminals.map(\.stableID)
        #expect(terminalIDs.contains(surface.id.uuidString))
        #expect(tab.valueInTerminals(uniqueID: surface.id.uuidString)?.stableID == surface.id.uuidString)
        #expect(tab.valueInTerminals(uniqueID: "not-a-real-id") == nil)
    }

    @Test func objectSpecifierIsEitherNilOrAUniqueIDSpecifier() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        let scriptWindow = ScriptWindow(primaryController: controller)
        let tab = ScriptTab(window: scriptWindow, controller: controller)
        let specifier = tab.objectSpecifier
        #expect(specifier == nil || specifier is NSUniqueIDSpecifier)
    }

    @Test func selectTabFailsWhenTheTabIsNoLongerAvailable() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }

        let controller = TerminalController(appDelegate.tako, withBaseConfig: nil)
        let scriptWindow = ScriptWindow(primaryController: controller)
        let tab = ScriptTab(window: scriptWindow, controller: controller)

        let command = ASTestSupport.nsScriptCommand()
        #expect(tab.handleSelectTab(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
        #expect(command.scriptErrorString == "Tab is no longer available.")
    }

    @Test func selectTabSelectsItInsideItsTabGroup() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controllerA, windowA) = ASTestSupport.makeTerminalController(appDelegate.tako)
        let (controllerB, windowB) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            windowA.close()
            windowB.close()
            restore()
        }

        Tako.CustomTabGroup.join(windowB, to: windowA, select: false)
        let scriptWindow = ScriptWindow(primaryController: controllerA)
        let tabB = ScriptTab(window: scriptWindow, controller: controllerB)

        let command = ASTestSupport.nsScriptCommand()
        #expect(tabB.handleSelectTab(command) == nil)
        #expect(command.scriptErrorNumber == 0)
        #expect(Tako.CustomTabGroup.group(for: windowA).selectedWindow === windowB)
    }

    @Test func closeTabFailsWhenTheTabIsNoLongerAvailable() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }

        // `ScriptTab.controller` is weak: a `TerminalController` with no
        // window still resolves as `parentController`, so `handleCloseTab`
        // would take its "managed controller" shortcut and no-op instead of
        // failing. Letting the controller deallocate is what actually drives
        // `parentController` to `nil` and reaches the error path.
        let tab: ScriptTab = autoreleasepool {
            let controller = TerminalController(appDelegate.tako, withBaseConfig: nil)
            let scriptWindow = ScriptWindow(primaryController: controller)
            return ScriptTab(window: scriptWindow, controller: controller)
        }

        let command = ASTestSupport.nsScriptCommand()
        #expect(tab.handleCloseTab(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
        #expect(command.scriptErrorString == "Tab is no longer available.")
    }

    @Test func closeTabClosesATerminalControllerImmediately() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer { restore() }

        let scriptWindow = ScriptWindow(primaryController: controller)
        let tab = ScriptTab(window: scriptWindow, controller: controller)

        let command = ASTestSupport.nsScriptCommand()
        #expect(tab.handleCloseTab(command) == nil)
        #expect(!window.isVisible)
    }

    @Test func closeTabClosesANonTerminalControllerDirectly() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }

        let scriptWindow = ScriptWindow(primaryController: controller)
        let tab = ScriptTab(window: scriptWindow, controller: controller)

        let command = ASTestSupport.nsScriptCommand()
        #expect(tab.handleCloseTab(command) == nil)
        #expect(!window.isVisible)
    }

    @Test func everyCommandBailsWhenAppleScriptIsDisabled() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            window.close()
            restore()
        }

        let scriptWindow = ScriptWindow(primaryController: controller)
        let tab = ScriptTab(window: scriptWindow, controller: controller)
        ASTestSupport.setAppleScriptEnabled(false)

        #expect(tab.handleSelectTab(ASTestSupport.nsScriptCommand()) == nil)
        #expect(tab.handleCloseTab(ASTestSupport.nsScriptCommand()) == nil)
    }
}
