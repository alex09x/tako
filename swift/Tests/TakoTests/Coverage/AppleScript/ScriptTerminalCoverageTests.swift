import Testing
import AppKit
@testable import Tako

// `ScriptTerminal`: the AppleScript-facing wrapper around a live terminal
// surface, and its commands (`split`, `focus`, `close`, `perform action`).

@Suite(.serialized)
@MainActor
struct ScriptTerminalPropertyCoverageTests {
    @Test func propertiesAreBlankWhenAppleScriptIsDisabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        ASTestSupport.setAppleScriptEnabled(false)
        defer { ASTestSupport.resetAppleScriptEnabled() }

        let terminal = ScriptTerminal(surfaceView: view)
        #expect(terminal.stableID == "")
        #expect(terminal.title == "")
        #expect(terminal.workingDirectory == "")
        #expect(terminal.pid == 0)
        #expect(terminal.tty == "")
        #expect(terminal.perform(action: "reset_font_size") == false)
        #expect(terminal.objectSpecifier == nil)
    }

    @Test func propertiesReflectTheLiveSurfaceWhenEnabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }

        let terminal = ScriptTerminal(surfaceView: view)
        #expect(terminal.stableID == view.id.uuidString)
        #expect(terminal.title == view.title)
        // The surface is closed immediately after creation, before it ever
        // reports a working directory, pid or tty.
        #expect(terminal.workingDirectory == "")
        #expect(terminal.pid == 0)
        #expect(terminal.tty == "")
    }

    @Test func objectSpecifierIsEitherNilOrAUniqueIDSpecifier() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }

        let terminal = ScriptTerminal(surfaceView: view)
        let specifier = terminal.objectSpecifier
        #expect(specifier == nil || specifier is NSUniqueIDSpecifier)
    }

    @Test func performActionRoutesToTheSurfaceModel() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }

        let terminal = ScriptTerminal(surfaceView: view)
        #expect(terminal.perform(action: "increase_font_size:4") == true)
        #expect(view.theme.fontSize == 17)
        #expect(terminal.perform(action: "this_is_not_a_real_action") == false)
    }
}

@Suite(.serialized)
@MainActor
struct ScriptTerminalCommandCoverageTests {
    /// A live surface hosted inside a real `TerminalController`'s window, so
    /// `surfaceView.window?.windowController as? BaseTerminalController`
    /// resolves -- required for `split`/`focus`/`close` to reach their
    /// success paths.
    private func makeAttachedTerminal(_ tako: Tako.App) -> (
        terminal: ScriptTerminal, view: Tako.SurfaceView, controller: TerminalController, window: NSWindow
    ) {
        let (controller, window) = ASTestSupport.makeTerminalController(tako)
        let view = controller.surfaceTree.root!.leaves().first!
        window.contentView = view
        return (ScriptTerminal(surfaceView: view), view, controller, window)
    }

    @Test func splitFailsWithoutADirection() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let command = ASTestSupport.nsScriptCommand()
        #expect(terminal.handleSplit(command) == nil)
        #expect(command.scriptErrorNumber == errAEParamMissed)
    }

    @Test func splitFailsForAnUnknownDirectionCode() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["direction": "ZZZZ".fourCharCode], to: command)
        #expect(terminal.handleSplit(command) == nil)
        #expect(command.scriptErrorNumber == errAEParamMissed)
    }

    @Test func splitFailsWhenTheSurfaceIsNotInAWindow() {
        // `hostedSurface` never attaches to a `TerminalController`-owned
        // window, so the surface has no splittable window controller.
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply(["direction": "GSrt".fourCharCode], to: command)
        #expect(terminal.handleSplit(command) == nil)
        #expect(command.scriptErrorNumber == errAEEventFailed)
        #expect(command.scriptErrorString == "Terminal is not in a splittable window.")
    }


    @Test func splitSucceedsWithAValidConfigurationAndDirection() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }
        let (terminal, _, controller, window) = makeAttachedTerminal(appDelegate.tako)
        defer { window.close() }

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply([
            "direction": "GSrt".fourCharCode,
            "configuration": ["command": "top"] as NSDictionary,
        ], to: command)
        let created = terminal.handleSplit(command)
        #expect(created is ScriptTerminal)
        #expect(controller.surfaceTree.isSplit)
    }

    @Test func splitFailsForAnInvalidConfiguration() {
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }
        let (terminal, _, _, window) = makeAttachedTerminal(appDelegate.tako)
        defer { window.close() }

        let command = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply([
            "direction": "GSrt".fourCharCode,
            "configuration": ["fontSize": "nope"] as NSDictionary,
        ], to: command)
        #expect(terminal.handleSplit(command) == nil)
        #expect(command.scriptErrorNumber == errAECoercionFail)
    }


    @Test func focusFailsWhenTheSurfaceIsNotInAWindow() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let command = ASTestSupport.nsScriptCommand()
        #expect(terminal.handleFocus(command) == nil)
        #expect(command.scriptErrorString == "Terminal is not in a window.")
    }

    @Test func focusSucceedsAndMovesFocusToTheSurface() {
        // `focusSurface`'s real work (`Tako.moveFocus`, tab-group selection)
        // runs inside `DispatchQueue.main.async`, which a bare `swift test`
        // host never drains -- there is no real main-thread run loop pumping
        // GCD's main queue here (see `QTTestSupport.loadAndAnimateIn`'s doc
        // comment for the same caveat). So the only effect this test can
        // observe is that the command itself succeeds without error.
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }
        let (terminal, _, _, window) = makeAttachedTerminal(appDelegate.tako)
        defer { window.close() }

        let command = ASTestSupport.nsScriptCommand()
        #expect(terminal.handleFocus(command) == nil)
        #expect(command.scriptErrorNumber == 0)
    }


    @Test func closeFailsWhenTheSurfaceIsNotInAWindow() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let command = ASTestSupport.nsScriptCommand()
        #expect(terminal.handleClose(command) == nil)
        #expect(command.scriptErrorString == "Terminal is not in a window.")
    }

    @Test func closeSucceedsAndRemovesTheSurfaceFromTheTree() throws {
        // Closing the *root* surface of a single-tab window closes the whole
        // window instead of editing the tree in place (see
        // `TerminalController.closeSurface`), so this exercises the direct
        // tree-editing path (`removeSurfaceNode`) with a split: closing one
        // side of the split removes only that side from the tree.
        let (appDelegate, restore) = ASTestSupport.withAppDelegateHandle()
        defer { restore() }
        let (terminal, rootView, controller, window) = makeAttachedTerminal(appDelegate.tako)
        defer { window.close() }

        let splitCommand = ASTestSupport.nsScriptCommand()
        ASTestSupport.apply([
            "direction": "GSrt".fourCharCode,
            "configuration": ["command": "top"] as NSDictionary,
        ], to: splitCommand)
        let created = try #require(terminal.handleSplit(splitCommand) as? ScriptTerminal)
        let newView = try #require(created.surfaceView)
        // `newSplit` only edits the model tree -- placing the new surface
        // into the window's real view hierarchy (SwiftUI's job in the real
        // app, which this headless test target can't render) is required for
        // `surfaceView.window` to resolve, which `close`'s window-controller
        // lookup depends on.
        rootView.addSubview(newView)
        #expect(controller.surfaceTree.contains(newView))

        let command = ASTestSupport.nsScriptCommand()
        _ = created.handleClose(command)
        #expect(!controller.surfaceTree.contains(newView))
    }

    @Test func everyCommandBailsWhenAppleScriptIsDisabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        ASTestSupport.setAppleScriptEnabled(false)
        defer { ASTestSupport.resetAppleScriptEnabled() }

        let terminal = ScriptTerminal(surfaceView: view)
        #expect(terminal.handleSplit(ASTestSupport.nsScriptCommand()) == nil)
        #expect(terminal.handleFocus(ASTestSupport.nsScriptCommand()) == nil)
        #expect(terminal.handleClose(ASTestSupport.nsScriptCommand()) == nil)
    }
}
