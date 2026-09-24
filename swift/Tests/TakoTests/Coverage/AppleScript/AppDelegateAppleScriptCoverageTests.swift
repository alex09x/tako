import Testing
import AppKit
@testable import Tako

// The `NSApplication` scripting surface Cocoa scripting resolves through:
// `scriptWindows`/`frontWindow`/`terminals` for enumeration, `valueIn...`
// for unique-ID lookup, and the `handle...ScriptCommand:` selectors for
// application-level commands (`perform action`, `new window`, `new tab`,
// `new surface configuration`, `quit`).
//
// These tests never assert exact counts on the app-wide collections
// (`NSApp.scriptWindows`, `NSApp.terminals`): other coverage suites in this
// process create `BaseTerminalController`-backed windows of their own and
// only order them out (not close them), so they remain in `NSApp.windows`
// for the rest of the run. Every assertion here instead checks for the
// presence of specific, freshly created windows/terminals by their stable
// ID.

@MainActor
private func makeAppDelegate() -> (AppDelegate, () -> Void) {
    // `NSApp` is `NSApplication!` -- nil until something touches
    // `NSApplication.shared` at least once, which would crash the very
    // first read of `NSApp.delegate` below if this suite happens to run
    // before any other test does.
    _ = NSApplication.shared
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    return (appDelegate, { NSApplication.shared.delegate = originalDelegate })
}

@Suite(.serialized)
@MainActor
struct AppleScriptDisabledCoverageTests {
    @Test func everyEnumerationEntryPointGoesEmptyOrNilWhenDisabled() {
        let (_, restore) = makeAppDelegate()
        ASTestSupport.setAppleScriptEnabled(false)
        defer {
            restore()
            ASTestSupport.resetAppleScriptEnabled()
        }

        #expect(NSApplication.shared.scriptWindows.isEmpty)
        #expect(NSApplication.shared.frontWindow == nil)
        #expect(NSApplication.shared.valueInScriptWindows(uniqueID: "anything") == nil)
        #expect(NSApplication.shared.terminals.isEmpty)
        #expect(NSApplication.shared.valueInTerminals(uniqueID: "anything") == nil)
    }

    @Test func validateScriptRecordsTheDisabledError() {
        let (_, restore) = makeAppDelegate()
        ASTestSupport.setAppleScriptEnabled(false)
        defer {
            restore()
            ASTestSupport.resetAppleScriptEnabled()
        }

        let command = ASTestSupport.inputTextCommand()
        #expect(!NSApplication.shared.validateScript(command: command))
        #expect(command.scriptErrorNumber == errAEEventNotPermitted)
        #expect(command.scriptErrorString == "AppleScript is disabled by the macos-applescript configuration.")
    }

    @Test func everyCommandHandlerBailsBeforeDoingAnythingWhenDisabled() {
        let (_, restore) = makeAppDelegate()
        ASTestSupport.setAppleScriptEnabled(false)
        defer {
            restore()
            ASTestSupport.resetAppleScriptEnabled()
        }

        let performAction = ASTestSupport.nsScriptCommand()
        #expect(NSApplication.shared.handlePerformActionScriptCommand(performAction) == nil)

        let newConfig = ASTestSupport.nsScriptCommand()
        #expect(NSApplication.shared.handleNewSurfaceConfigurationScriptCommand(newConfig) == nil)

        let newWindow = ASTestSupport.nsScriptCommand()
        #expect(NSApplication.shared.handleNewWindowScriptCommand(newWindow) == nil)

        let newTab = ASTestSupport.nsScriptCommand()
        #expect(NSApplication.shared.handleNewTabScriptCommand(newTab) == nil)

        // Disabled scripting bails out of `handleQuitScriptCommand` before
        // it ever reaches `terminate(nil)`, so this is safe to call from a
        // test process.
        let quit = ASTestSupport.nsScriptCommand()
        NSApplication.shared.handleQuitScriptCommand(quit)
        #expect(quit.scriptErrorNumber == errAEEventNotPermitted)
    }

    @Test func isAppleScriptEnabledFallsBackToTrueWithoutAnAppDelegate() {
        _ = NSApplication.shared
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        ASTestSupport.resetAppleScriptEnabled()
        defer { NSApplication.shared.delegate = originalDelegate }

        #expect(NSApplication.shared.isAppleScriptEnabled)
    }
}

@Suite(.serialized)
@MainActor
struct AppleScriptEnabledEnumerationCoverageTests {
    @Test func scriptWindowsListsEachDistinctWindowAndCollapsesTabSiblings() throws {
        let (appDelegate, restore) = makeAppDelegate()
        defer { restore() }

        let (_, windowA) = ASTestSupport.makeTerminalController(appDelegate.tako)
        let (_, windowB) = ASTestSupport.makeTerminalController(appDelegate.tako)
        let (_, windowC) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            windowA.close()
            windowB.close()
            windowC.close()
        }

        // B joins A's tab group; C stays standalone.
        Tako.CustomTabGroup.join(windowB, to: windowA, select: true)
        windowA.orderFrontRegardless()
        windowB.orderFrontRegardless()
        windowC.orderFrontRegardless()

        let groupID = ScriptWindow.stableID(tabGroup: Tako.CustomTabGroup.group(for: windowA))
        let standaloneID = ScriptWindow.stableID(tabGroup: Tako.CustomTabGroup.group(for: windowC))

        let ids = NSApplication.shared.scriptWindows.map(\.stableID)
        #expect(ids.contains(groupID))
        #expect(ids.contains(standaloneID))

        // The grouped pair produced exactly one scripting window, not two.
        #expect(ids.filter { $0 == groupID }.count == 1)

        let groupedWindow = try #require(NSApplication.shared.scriptWindows.first(where: { $0.stableID == groupID }))
        #expect(groupedWindow.tabs.count == 2)
    }

    @Test func frontWindowIsWhicheverWindowWasOrderedFrontMostRecently() {
        let (appDelegate, restore) = makeAppDelegate()
        defer { restore() }

        let (_, windowA) = ASTestSupport.makeTerminalController(appDelegate.tako)
        let (controllerB, windowB) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer {
            windowA.close()
            windowB.close()
        }

        windowA.orderFrontRegardless()
        windowB.makeKeyAndOrderFront(nil)

        let expectedID = ScriptWindow.stableID(primaryController: controllerB)
        #expect(NSApplication.shared.frontWindow?.stableID == expectedID)
    }

    @Test func valueInScriptWindowsResolvesByIDAndFailsForUnknownIDs() {
        let (appDelegate, restore) = makeAppDelegate()
        defer { restore() }

        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer { window.close() }
        window.orderFrontRegardless()

        let id = ScriptWindow.stableID(primaryController: controller)
        #expect(NSApplication.shared.valueInScriptWindows(uniqueID: id)?.stableID == id)
        #expect(NSApplication.shared.valueInScriptWindows(uniqueID: "not-a-real-id") == nil)
    }

    @Test func terminalsListsLiveSurfacesAndResolvesByUniqueID() {
        let (appDelegate, restore) = makeAppDelegate()
        defer { restore() }

        let (controller, window) = ASTestSupport.makeTerminalController(appDelegate.tako)
        defer { window.close() }
        window.orderFrontRegardless()

        guard let surface = controller.surfaceTree.root?.leaves().first else {
            Issue.record("expected an initial surface")
            return
        }

        let terminalIDs = NSApplication.shared.terminals.map(\.stableID)
        #expect(terminalIDs.contains(surface.id.uuidString))
        #expect(NSApplication.shared.valueInTerminals(uniqueID: surface.id.uuidString)?.stableID == surface.id.uuidString)
        #expect(NSApplication.shared.valueInTerminals(uniqueID: "not-a-real-id") == nil)
    }
}

@Suite(.serialized)
@MainActor
struct AppleScriptCommandHandlerCoverageTests {
    @Test func performActionRequiresAnActionStringAndATerminal() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let missingAction = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply([:], to: missingAction)
        #expect(NSApplication.shared.handlePerformActionScriptCommand(missingAction) == nil)
        #expect(missingAction.scriptErrorNumber == errAEParamMissed)

        let missingTerminal = ASTestSupport.nsScriptCommand()
        missingTerminal.directParameter = "reset_font_size"
        #expect(NSApplication.shared.handlePerformActionScriptCommand(missingTerminal) == nil)
        #expect(missingTerminal.scriptErrorNumber == errAEParamMissed)
    }

    @Test func performActionRoutesToTheTerminalAndReportsSuccess() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let command = ASTestSupport.nsScriptCommand()
        command.directParameter = "increase_font_size:6"
        ASTestSupport.apply(["on": terminal], to: command)

        let result = NSApplication.shared.handlePerformActionScriptCommand(command)
        #expect(result?.boolValue == true)
        #expect(view.theme.fontSize == 19)
    }

    @Test func performActionReportsFailureForAnUnknownAction() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let command = ASTestSupport.nsScriptCommand()
        command.directParameter = "this_action_does_not_exist"
        ASTestSupport.apply(["on": terminal], to: command)

        #expect(NSApplication.shared.handlePerformActionScriptCommand(command)?.boolValue == false)
    }

    @Test func newSurfaceConfigurationReturnsARecordForAValidConfigurationAndAnErrorOtherwise() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let good = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["configuration": ["command": "top"] as NSDictionary], to: good)
        let dict = NSApplication.shared.handleNewSurfaceConfigurationScriptCommand(good)
        #expect(dict?["command"] as? String == "top")

        let bad = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["configuration": ["fontSize": "not a number"] as NSDictionary], to: bad)
        #expect(NSApplication.shared.handleNewSurfaceConfigurationScriptCommand(bad) == nil)
        #expect(bad.scriptErrorNumber == errAECoercionFail)
    }

    @Test func newWindowFailsWhenTheAppDelegateIsMissing() {
        _ = NSApplication.shared
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        ASTestSupport.setAppleScriptEnabled(true)
        defer {
            NSApplication.shared.delegate = originalDelegate
            ASTestSupport.resetAppleScriptEnabled()
        }

        let command = ASTestSupport.nsScriptCommand()
        #expect(NSApplication.shared.handleNewWindowScriptCommand(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
    }

    @Test func newWindowFailsForAnInvalidConfiguration() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["configuration": ["fontSize": "nope"] as NSDictionary], to: command)
        #expect(NSApplication.shared.handleNewWindowScriptCommand(command) == nil)
        #expect(command.scriptErrorNumber == errAECoercionFail)
    }

    @Test func newWindowSucceedsAndReturnsAScriptWindow() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["configuration": ["command": "top"] as NSDictionary], to: command)
        let scriptWindow = NSApplication.shared.handleNewWindowScriptCommand(command)
        #expect(scriptWindow != nil)
    }

    @Test func newTabFailsWhenTheAppDelegateIsMissing() {
        _ = NSApplication.shared
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        ASTestSupport.setAppleScriptEnabled(true)
        defer {
            NSApplication.shared.delegate = originalDelegate
            ASTestSupport.resetAppleScriptEnabled()
        }

        let command = ASTestSupport.nsScriptCommand()
        #expect(NSApplication.shared.handleNewTabScriptCommand(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
    }

    @Test func newTabFailsForAnInvalidConfiguration() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["configuration": ["fontSize": "nope"] as NSDictionary], to: command)
        #expect(NSApplication.shared.handleNewTabScriptCommand(command) == nil)
        #expect(command.scriptErrorNumber == errAECoercionFail)
    }

    @Test func newTabFailsWhenTheTargetWindowIsNoLongerAvailable() {
        let (appDelegate, restore) = makeAppDelegate()
        defer { restore() }

        // A controller whose window was never assigned: `preferredParentWindow`
        // resolves to `nil`, matching a window that closed between a script
        // resolving it and this command running.
        let danglingController = TerminalController(appDelegate.tako, withBaseConfig: nil)
        let danglingWindow = ScriptWindow(primaryController: danglingController)

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["window": danglingWindow], to: command)
        #expect(NSApplication.shared.handleNewTabScriptCommand(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
        #expect(command.scriptErrorString == "Target window is no longer available.")
    }

    @Test func newTabSucceedsWithoutAnExplicitTargetWindow() {
        let (_, restore) = makeAppDelegate()
        defer { restore() }

        let command = ASTestSupport.nsScriptCommand()
        let scriptTab = NSApplication.shared.handleNewTabScriptCommand(command)
        #expect(scriptTab != nil)
    }
}
