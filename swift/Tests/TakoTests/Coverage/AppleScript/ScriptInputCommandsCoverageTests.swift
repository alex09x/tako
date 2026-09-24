import Testing
import AppKit
@testable import Tako

// The five low-level AppleScript input commands: `input text`, `send key`,
// `send mouse position`, `send mouse button`, `send mouse scroll`. Each
// validates its arguments, resolves the target terminal, then forwards to
// the surface's input model.

@Suite(.serialized)
@MainActor
struct ScriptInputTextCommandCoverageTests {
    @Test func failsWithoutText() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.inputTextCommand()
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEParamMissed)
    }

    @Test func failsWithoutATerminal() {
        let command = ASTestSupport.inputTextCommand()
        command.directParameter = "hello"
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEParamMissed)
    }


    @Test func sendsTheExactTextToTheShell() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        view.selfTestCapturing = true

        let command = ASTestSupport.inputTextCommand()
        command.directParameter = "echo hello\n"
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)

        #expect(String(decoding: view.selfTestBytes, as: UTF8.self) == "echo hello\n")
    }

    @Test func bailsWhenAppleScriptIsDisabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        ASTestSupport.setAppleScriptEnabled(false)
        defer { ASTestSupport.resetAppleScriptEnabled() }

        let command = ASTestSupport.inputTextCommand()
        command.directParameter = "hello"
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEEventNotPermitted)
    }
}

@Suite(.serialized)
@MainActor
struct ScriptMousePosCommandCoverageTests {
    @Test func failsWithoutX() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mousePosCommand()
        ASTestSupport.apply(["y": 1.0, "terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing x position.")
    }

    @Test func failsWithoutY() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mousePosCommand()
        ASTestSupport.apply(["x": 1.0, "terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing y position.")
    }

    @Test func failsWithoutATerminal() {
        let command = ASTestSupport.mousePosCommand()
        ASTestSupport.apply(["x": 1.0, "y": 1.0], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing terminal target.")
    }


    @Test func failsForUnknownModifiers() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mousePosCommand()
        ASTestSupport.apply([
            "x": 1.0, "y": 1.0,
            "terminal": ScriptTerminal(surfaceView: view),
            "modifiers": "nonsense",
        ], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAECoercionFail)
    }

    @Test func movesTheReportedMouseCellWithoutModifiers() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mousePosCommand()
        ASTestSupport.apply([
            "x": 5.0, "y": 5.0,
            "terminal": ScriptTerminal(surfaceView: view),
        ], to: command)
        #expect(command.performDefaultImplementation() == nil)
        let expectedCell = view.cellAt(NSPoint(x: 5, y: 5))
        #expect(view.mouseCell?.row == expectedCell.row && view.mouseCell?.col == expectedCell.col)
    }

    @Test func movesTheReportedMouseCellWithModifiers() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mousePosCommand()
        ASTestSupport.apply([
            "x": 10.0, "y": 10.0,
            "terminal": ScriptTerminal(surfaceView: view),
            "modifiers": "shift, command",
        ], to: command)
        #expect(command.performDefaultImplementation() == nil)
        let expectedCell = view.cellAt(NSPoint(x: 10, y: 10))
        #expect(view.mouseCell?.row == expectedCell.row && view.mouseCell?.col == expectedCell.col)
    }

    @Test func bailsWhenAppleScriptIsDisabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        ASTestSupport.setAppleScriptEnabled(false)
        defer { ASTestSupport.resetAppleScriptEnabled() }

        let command = ASTestSupport.mousePosCommand()
        ASTestSupport.apply(["x": 1.0, "y": 1.0, "terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEEventNotPermitted)
    }
}

@Suite(.serialized)
@MainActor
struct ScriptMouseButtonCommandCoverageTests {
    @Test func failsWithoutAKnownButton() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mouseButtonCommand()
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEParamMissed)

        command.directParameter = "GMxx".fourCharCode
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEParamMissed)
    }

    @Test func failsWithoutATerminal() {
        let command = ASTestSupport.mouseButtonCommand()
        command.directParameter = "GMlf".fourCharCode
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing terminal target.")
    }


    @Test func failsForUnknownModifiers() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mouseButtonCommand()
        command.directParameter = "GMlf".fourCharCode
        ASTestSupport.apply([
            "terminal": ScriptTerminal(surfaceView: view),
            "modifiers": "nonsense",
        ], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAECoercionFail)
    }

    @Test func succeedsForEveryButtonAndAction() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        for buttonCode in ["GMlf", "GMrt", "GMmd"] {
            for actionCode in ["GIpr", "GIrl"] {
                let command = ASTestSupport.mouseButtonCommand()
                command.directParameter = buttonCode.fourCharCode
                ASTestSupport.apply([
                    "terminal": terminal,
                    "action": actionCode.fourCharCode,
                    "modifiers": "shift",
                ], to: command)
                #expect(command.performDefaultImplementation() == nil)
                #expect(command.scriptErrorNumber == 0)
            }
        }

        // No action/modifiers supplied at all: defaults to `.press` and `[]`.
        let bareDefaults = ASTestSupport.mouseButtonCommand()
        bareDefaults.directParameter = "GMlf".fourCharCode
        ASTestSupport.apply(["terminal": terminal], to: bareDefaults)
        #expect(bareDefaults.performDefaultImplementation() == nil)

        // An action code that isn't press/release falls back to `.press`.
        let unknownAction = ASTestSupport.mouseButtonCommand()
        unknownAction.directParameter = "GMlf".fourCharCode
        ASTestSupport.apply(["terminal": terminal, "action": "ZZZZ".fourCharCode], to: unknownAction)
        #expect(unknownAction.performDefaultImplementation() == nil)
    }

    @Test func bailsWhenAppleScriptIsDisabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        ASTestSupport.setAppleScriptEnabled(false)
        defer { ASTestSupport.resetAppleScriptEnabled() }

        let command = ASTestSupport.mouseButtonCommand()
        command.directParameter = "GMlf".fourCharCode
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEEventNotPermitted)
    }
}

@Suite(.serialized)
@MainActor
struct ScriptMouseScrollCommandCoverageTests {
    @Test func failsWithoutX() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mouseScrollCommand()
        ASTestSupport.apply(["y": 1.0, "terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing x scroll delta.")
    }

    @Test func failsWithoutY() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.mouseScrollCommand()
        ASTestSupport.apply(["x": 1.0, "terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing y scroll delta.")
    }

    @Test func failsWithoutATerminal() {
        let command = ASTestSupport.mouseScrollCommand()
        ASTestSupport.apply(["x": 1.0, "y": 1.0], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing terminal target.")
    }


    @Test func succeedsForEveryMomentumValueAndPrecisionSetting() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        let momentumCodes = ["SMno", "SMbg", "SMch", "SMen", "SMcn", "SMmb", "SMst"]
        for code in momentumCodes {
            for precision in [true, false] {
                let command = ASTestSupport.mouseScrollCommand()
                ASTestSupport.apply([
                    "x": 0.0, "y": 1.0,
                    "terminal": terminal,
                    "momentum": code.fourCharCode,
                    "precision": precision,
                ], to: command)
                #expect(command.performDefaultImplementation() == nil)
            }
        }

        // No momentum supplied: defaults to `.none`.
        let bareDefaults = ASTestSupport.mouseScrollCommand()
        ASTestSupport.apply(["x": 0.0, "y": 1.0, "terminal": terminal], to: bareDefaults)
        #expect(bareDefaults.performDefaultImplementation() == nil)

        // A momentum code that isn't recognized falls back to `.none`.
        let unknownMomentum = ASTestSupport.mouseScrollCommand()
        ASTestSupport.apply(["x": 0.0, "y": 1.0, "terminal": terminal, "momentum": "ZZZZ".fourCharCode], to: unknownMomentum)
        #expect(unknownMomentum.performDefaultImplementation() == nil)

        // y == 0 exercises the "nothing to scroll" early return.
        let noScroll = ASTestSupport.mouseScrollCommand()
        ASTestSupport.apply(["x": 0.0, "y": 0.0, "terminal": terminal], to: noScroll)
        #expect(noScroll.performDefaultImplementation() == nil)
    }

    @Test func bailsWhenAppleScriptIsDisabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        ASTestSupport.setAppleScriptEnabled(false)
        defer { ASTestSupport.resetAppleScriptEnabled() }

        let command = ASTestSupport.mouseScrollCommand()
        ASTestSupport.apply(["x": 0.0, "y": 1.0, "terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEEventNotPermitted)
    }
}

@Suite(.serialized)
@MainActor
struct ScriptKeyEventCommandCoverageTests {
    @Test func failsWithoutAKeyName() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.keyEventCommand()
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing key name.")
    }

    @Test func failsWithoutATerminal() {
        let command = ASTestSupport.keyEventCommand()
        command.directParameter = "enter"
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorString == "Missing terminal target.")
    }


    @Test func failsForAnUnknownKeyName() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.keyEventCommand()
        command.directParameter = "not-a-real-key"
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAECoercionFail)
    }

    @Test func failsForUnknownModifiers() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let command = ASTestSupport.keyEventCommand()
        command.directParameter = "enter"
        ASTestSupport.apply([
            "terminal": ScriptTerminal(surfaceView: view),
            "modifiers": "nonsense",
        ], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAECoercionFail)
    }

    @Test func succeedsForEveryActionValueAndAKnownKey() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        let terminal = ScriptTerminal(surfaceView: view)

        for actionCode in ["GIpr", "GIrl"] {
            let command = ASTestSupport.keyEventCommand()
            command.directParameter = "enter"
            ASTestSupport.apply([
                "terminal": terminal,
                "action": actionCode.fourCharCode,
                "modifiers": "control,option",
            ], to: command)
            #expect(command.performDefaultImplementation() == nil)
            #expect(command.scriptErrorNumber == 0)
        }

        // No action supplied: defaults to `.press`.
        let bareDefaults = ASTestSupport.keyEventCommand()
        bareDefaults.directParameter = "space"
        ASTestSupport.apply(["terminal": terminal], to: bareDefaults)
        #expect(bareDefaults.performDefaultImplementation() == nil)

        // An action code that isn't press/release falls back to `.press`.
        let unknownAction = ASTestSupport.keyEventCommand()
        unknownAction.directParameter = "tab"
        ASTestSupport.apply(["terminal": terminal, "action": "ZZZZ".fourCharCode], to: unknownAction)
        #expect(unknownAction.performDefaultImplementation() == nil)
    }

    @Test func bailsWhenAppleScriptIsDisabled() {
        let (view, window) = ASTestSupport.hostedSurface()
        defer { window.close() }
        ASTestSupport.setAppleScriptEnabled(false)
        defer { ASTestSupport.resetAppleScriptEnabled() }

        let command = ASTestSupport.keyEventCommand()
        command.directParameter = "enter"
        ASTestSupport.apply(["terminal": ScriptTerminal(surfaceView: view)], to: command)
        #expect(command.performDefaultImplementation() == nil)
        #expect(command.scriptErrorNumber == errAEEventNotPermitted)
    }
}
