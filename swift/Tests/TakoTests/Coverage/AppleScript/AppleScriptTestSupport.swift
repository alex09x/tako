import AppKit
@testable import Tako

/// Shared helpers for the AppleScript feature's behavioural coverage suites
/// (`Features/AppleScript`).
@MainActor
enum ASTestSupport {
    /// Builds a real `TerminalController` with its window assigned directly,
    /// short-circuiting `NSWindowController.windowNibName`'s lazy nib load.
    ///
    /// `Terminal.xib` is deliberately excluded from this SwiftPM test target
    /// (see `swift/Package.swift`), so letting `.window` load lazily would
    /// fail to find a nib. Assigning `.window` directly before it is ever
    /// read short-circuits that path (`NSWindowController` only calls
    /// `loadWindow()` when its stored window is still nil) -- the same
    /// technique `QTTestSupport.makeController` uses for `QuickTerminalController`.
    ///
    /// A plain `NSWindow` (not `TerminalWindow`) is enough: every AppleScript
    /// wrapper this feature exposes (`ScriptWindow`, `ScriptTab`) only needs
    /// `window.windowController` to resolve to a `BaseTerminalController` and
    /// `Tako.CustomTabGroup.group(for:)` to work, neither of which requires
    /// the concrete window subclass.
    static func makeTerminalController(
        _ tako: Tako.App,
        baseConfig: Tako.SurfaceConfiguration? = nil
    ) -> (controller: TerminalController, window: NSWindow) {
        let controller = TerminalController(tako, withBaseConfig: baseConfig)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        // `Terminal.xib` normally wires the window's delegate outlet to the
        // controller and triggers `windowDidLoad()` (which seeds
        // `focusedSurface` and the content view) the first time `.window` is
        // read. Bypassing the nib skips both, so both are replicated by hand
        // here -- the same technique `QTTestSupport.loadAndAnimateIn` uses for
        // `QuickTerminalController`.
        window.delegate = controller
        controller.windowDidLoad()
        return (controller, window)
    }

    /// A real, offscreen `SurfaceView` closed immediately -- exercising
    /// AppleScript's terminal/input commands never needs a live shell
    /// process, and closing right away keeps prompts and process timing
    /// from making the tests flaky (mirrors `SurfaceActionsTests.hostedSurface`).
    static func hostedSurface(theme: TerminalTheme = TerminalTheme()) -> (view: Tako.SurfaceView, window: NSWindow) {
        let view = Tako.SurfaceView(theme: theme)
        view.close()
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.flushPendingResizeForTesting()
        return (view, window)
    }

    /// Installs a real `AppDelegate` as `NSApp.delegate` for the duration of
    /// a test. Callers must invoke the returned closure (e.g. via `defer`)
    /// to restore the previous delegate and reset the AppleScript
    /// availability seam.
    static func withAppDelegateHandle(appleScriptEnabled: Bool = true) -> (AppDelegate, () -> Void) {
        // `NSApp` is `NSApplication!` -- nil until something touches
        // `NSApplication.shared` at least once. If this suite happens to run
        // before any other test does, reading `NSApp.delegate` first would
        // crash on the implicitly-unwrapped nil (see
        // `QTTestSupport.positionConflictingWithRealDock`'s identical note).
        _ = NSApplication.shared
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        setAppleScriptEnabled(appleScriptEnabled)
        return (appDelegate, {
            NSApplication.shared.delegate = originalDelegate
            resetAppleScriptEnabled()
        })
    }

    /// Overrides `NSApp.isAppleScriptEnabled` for every scripting object and
    /// command in the feature. `macosAppleScript` is hardcoded to `true`, so
    /// this seam (`AppDelegate+AppleScript.swift`) is the only way to reach
    /// the "AppleScript disabled" branches those guard.
    static func setAppleScriptEnabled(_ enabled: Bool) {
        NSApplication.appleScriptAvailability = .init(isEnabled: { enabled })
    }

    static func resetAppleScriptEnabled() {
        NSApplication.appleScriptAvailability = .init()
    }

    /// A bare `NSScriptCommandDescription` for direct
    /// `performDefaultImplementation()` testing, without going through the
    /// real AppleScript/Apple Event runtime (which needs a bundled `.sdef`
    /// this test target doesn't have).
    ///
    /// `NSScriptCommandDescription(suiteName:commandName:dictionary:)`
    /// returns `nil` unless a suite by that name is already registered in
    /// `NSScriptSuiteRegistry` -- which nothing does automatically here,
    /// since this test target's process has no `Info.plist` pointing at
    /// `Tako.sdef`. Registering a minimal one-command suite by hand once,
    /// the same shape Xcode derives from a real `.scriptSuite` plist, makes
    /// the lookup succeed. The description's actual identity doesn't matter
    /// for these tests: arguments are seeded directly via
    /// `apply(_:to:)`/`directParameter`, not resolved from the description's
    /// declared arguments.
    private static let registerTestSuite: Void = {
        NSScriptSuiteRegistry.shared().loadSuite(
            with: [
                "Name": "TakoAppleScriptTestSuite",
                "AppleEventCode": "tSut",
                "Commands": [
                    "testCommand": [
                        "Name": "testCommand",
                        "AppleEventCode": "tCmd",
                        "AppleEventClassCode": "tSut",
                        "CommandClass": "NSScriptCommand",
                    ],
                ],
            ],
            from: Bundle(for: AppDelegate.self)
        )
    }()

    private static func commandDescription() -> NSScriptCommandDescription {
        _ = registerTestSuite
        if let byName = NSScriptCommandDescription(
            suiteName: "TakoAppleScriptTestSuite",
            commandName: "testCommand",
            dictionary: nil
        ) {
            return byName
        }
        if let byCode = NSScriptSuiteRegistry.shared().commandDescription(
            withAppleEventClass: "tSut".fourCharCode,
            andAppleEventCode: "tCmd".fourCharCode
        ) {
            return byCode
        }
        fatalError("could not register a test NSScriptCommandDescription")
    }

    static func nsScriptCommand() -> StubbedNSScriptCommand {
        StubbedNSScriptCommand(commandDescription: commandDescription())
    }

    static func inputTextCommand() -> StubbedInputTextCommand {
        StubbedInputTextCommand(commandDescription: commandDescription())
    }

    static func mousePosCommand() -> StubbedMousePosCommand {
        StubbedMousePosCommand(commandDescription: commandDescription())
    }

    static func mouseButtonCommand() -> StubbedMouseButtonCommand {
        StubbedMouseButtonCommand(commandDescription: commandDescription())
    }

    static func mouseScrollCommand() -> StubbedMouseScrollCommand {
        StubbedMouseScrollCommand(commandDescription: commandDescription())
    }

    static func keyEventCommand() -> StubbedKeyEventCommand {
        StubbedKeyEventCommand(commandDescription: commandDescription())
    }

    /// `NSScriptCommand.evaluatedArguments` is a fully computed property the
    /// real AppleScript runtime derives from resolving an actual Apple
    /// Event's parameters -- there is no backing ivar key-value coding can
    /// reach, so a hand-built command with no real event behind it can never
    /// have it seeded directly. `Stubbed*Command` below override it to
    /// return a value this helper sets instead.
    static func apply(_ arguments: [String: Any], to command: some EvaluatedArgumentsStub) {
        command.stubEvaluatedArguments = arguments
    }
}

/// Conformers store the evaluated-arguments dictionary a real Apple Event
/// would otherwise populate, so `NSScriptCommand.performDefaultImplementation()`
/// can be exercised directly in tests. See `ASTestSupport.apply(_:to:)`.
@MainActor
protocol EvaluatedArgumentsStub: AnyObject {
    var stubEvaluatedArguments: [String: Any]? { get set }
}

final class StubbedNSScriptCommand: NSScriptCommand, EvaluatedArgumentsStub {
    var stubEvaluatedArguments: [String: Any]?
    override var evaluatedArguments: [String: Any]? { stubEvaluatedArguments }
}

final class StubbedInputTextCommand: ScriptInputTextCommand, EvaluatedArgumentsStub {
    var stubEvaluatedArguments: [String: Any]?
    override var evaluatedArguments: [String: Any]? { stubEvaluatedArguments }
}

final class StubbedMousePosCommand: ScriptMousePosCommand, EvaluatedArgumentsStub {
    var stubEvaluatedArguments: [String: Any]?
    override var evaluatedArguments: [String: Any]? { stubEvaluatedArguments }
}

final class StubbedMouseButtonCommand: ScriptMouseButtonCommand, EvaluatedArgumentsStub {
    var stubEvaluatedArguments: [String: Any]?
    override var evaluatedArguments: [String: Any]? { stubEvaluatedArguments }
}

final class StubbedMouseScrollCommand: ScriptMouseScrollCommand, EvaluatedArgumentsStub {
    var stubEvaluatedArguments: [String: Any]?
    override var evaluatedArguments: [String: Any]? { stubEvaluatedArguments }
}

final class StubbedKeyEventCommand: ScriptKeyEventCommand, EvaluatedArgumentsStub {
    var stubEvaluatedArguments: [String: Any]?
    override var evaluatedArguments: [String: Any]? { stubEvaluatedArguments }
}
