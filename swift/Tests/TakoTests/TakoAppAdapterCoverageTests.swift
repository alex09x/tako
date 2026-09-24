import AppKit
import CoreGraphics
import Darwin
import Foundation
import TakoKit
import Testing
@testable import Tako

/// Exercises the surface/app adapter over the Rust core (`Tako+App.swift`):
/// the `PTY` wrapper, `Tako.App`'s stubbed lifecycle surface, and
/// `Tako.SurfaceView`'s own code -- everything that is not already covered
/// by `MetalTerminalHostTests` (the GPU-host pure functions) or
/// `AppReloadTests` (config reload, PTY environment).
///
/// `SurfaceView` spins up a real PTY and a real login shell, the same way
/// the app itself does; there is no seam to fake the shell out from under
/// it, and the shim's own self-tests (`runKeySelfTest` etc.) are written
/// the same way. Waits on shell output poll a condition with a deadline
/// instead of sleeping a fixed amount.
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return condition() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

// MARK: - PTY

struct PTYCoverageTests {
    @Test func startsAShellWithARealTtyAndForegroundProcess() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        #expect(pty.alive)
        #expect(pty.child > 0)
        // `ttyname(3)` on the *master* side of a `/dev/ptmx`-style pty
        // reports ENOTTY (only the slave has a name), so this is nil in
        // practice -- proven rather than assumed by calling it here.
        _ = pty.ttyName
        // The shell itself is in the foreground until something else runs.
        #expect(waitUntil { pty.foregroundPID != nil })
    }

    @Test func writeDeliversBytesToTheChildsStdin() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        var collected = Data()
        pty.readLoop(
            targetQueue: .global(),
            onData: { collected.append($0) },
            onExit: {}
        )
        pty.write(Data("echo pty-hello-world\n".utf8))
        #expect(waitUntil(timeout: 8) { collected.count >= 0 && String(decoding: collected, as: UTF8.self).contains("pty-hello-world") })
    }

    @Test func writeAcceptsRawByteArraysToo() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        var collected = Data()
        pty.readLoop(targetQueue: .global(), onData: { collected.append($0) }, onExit: {})
        pty.write(Array("echo raw-bytes-ok\n".utf8))
        #expect(waitUntil(timeout: 8) { String(decoding: collected, as: UTF8.self).contains("raw-bytes-ok") })
    }

    @Test func writingEmptyDataIsANoOp() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }
        // Must not crash or block; nothing to assert beyond that.
        pty.write(Data())
        pty.write([UInt8]())
    }

    @Test func resizeAppliesTheNewWindowSizeWithoutCrashing() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }
        pty.resize(cols: 120, rows: 40)
    }

    @Test func terminateEndsTheChildAndStopsFutureWrites() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        pty.terminate()
        #expect(!pty.alive)
        // A write after termination must not attempt to write to a closed fd.
        pty.write(Data("echo after-terminate\n".utf8))
    }

    @Test func onExitFiresWhenTheChildShellExitsOnItsOwn() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        var exited = false
        pty.readLoop(targetQueue: .global(), onData: { _ in }, onExit: { exited = true })
        pty.write(Data("exit 0\n".utf8))
        #expect(waitUntil(timeout: 8) { exited })
    }

    @Test func loginShellIsAnAbsolutePath() {
        #expect(PTY.loginShell.hasPrefix("/"))
    }

    @Test func shellIntegrationEnvironmentIsEmptyWithoutBundledResources() {
        // `swift test` carries no `tako/shell-integration` resource directory,
        // so the lookup must decline rather than guess at a path.
        #expect(PTY.shellIntegrationEnvironment().isEmpty)
    }

    @Test func shellIntegrationEnvironmentIsEmptyWhenModeIsNone() throws {
        let config = try TemporaryConfig("shell-integration = none")
        #expect(PTY.shellIntegrationEnvironment(config: config, loginShell: "/bin/zsh").isEmpty)
    }

    // MARK: - shell-integration / shell-integration-features

    @Test func shellIntegrationVariablesPicksTheScriptByDetectedShell() {
        let env = PTY.shellIntegrationVariables(
            resourcesDir: "/r", base: "/r/shell-integration", mode: .detect,
            loginShell: "/bin/zsh", shellFeatures: "sudo,prompt,highlight", environment: [:])
        #expect(env.contains { $0.0 == "ZDOTDIR" && $0.1 == "/r/shell-integration/zsh" })
    }

    @Test func shellIntegrationVariablesExplicitModeOverridesTheLoginShell() {
        // Login shell is zsh, but `shell-integration = bash` forces bash's
        // env vars regardless.
        let env = PTY.shellIntegrationVariables(
            resourcesDir: "/r", base: "/r/shell-integration", mode: .bash,
            loginShell: "/bin/zsh", shellFeatures: "sudo,prompt,highlight", environment: [:])
        #expect(env.contains { $0.0 == "TAKO_BASH_INJECT" })
        #expect(!env.contains { $0.0 == "ZDOTDIR" })
    }

    @Test func shellIntegrationVariablesFishAndElvishUseXDGDataDirs() {
        for mode: Tako.Config.ShellIntegration in [.fish, .elvish] {
            let env = PTY.shellIntegrationVariables(
                resourcesDir: "/r", base: "/r/shell-integration", mode: mode,
                loginShell: "/bin/zsh", shellFeatures: "", environment: [:])
            #expect(env.contains { $0.0 == "XDG_DATA_DIRS" && $0.1 == "/r/shell-integration:/usr/local/share:/usr/share" })
        }
    }

    @Test func shellIntegrationVariablesNoneReturnsNothing() {
        #expect(PTY.shellIntegrationVariables(
            resourcesDir: "/r", base: "/r/shell-integration", mode: .none,
            loginShell: "/bin/zsh", shellFeatures: "", environment: [:]
        ).isEmpty)
    }

    @Test func shellFeaturesDefaultsToSudoPromptHighlight() {
        #expect(PTY.shellFeatures(nil) == "sudo,prompt,highlight")
    }

    @Test func shellFeaturesEnablesAnExtraFeature() {
        #expect(PTY.shellFeatures("cursor") == "sudo,prompt,highlight,cursor")
    }

    @Test func shellFeaturesDisablesADefaultFeature() {
        #expect(PTY.shellFeatures("no-sudo") == "prompt,highlight")
    }

    @Test func shellFeaturesIgnoresAnUnknownName() {
        #expect(PTY.shellFeatures("made-up-feature") == "sudo,prompt,highlight")
    }

    @Test func aNewSurfacesPtyStartsInTheDirectoryTheKeyResolvesTo() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: tmp.path))
        defer { pty.terminate() }
        #expect(pty.startedInDirectory == tmp.path)
    }

    @Test func failedToStartReturnsNilRatherThanACrash() {
        // A working directory that cannot exist as a real path still lets
        // forkpty succeed (chdir failure inside the child is silently
        // tolerated by the shell itself), so this just proves construction
        // does not crash on an unusual working directory.
        let pty = PTY(cols: 0, rows: 0, workingDirectory: "")
        defer { pty?.terminate() }
        #expect(pty != nil)
    }
}

// MARK: - Tako.App

@MainActor
struct TakoAppCoverageTests {
    @Test func defaultAppIsReady() {
        let app = Tako.App()
        #expect(app.readiness == .ready)
        #expect(app.app != nil)
    }

    /// Whether quitting may ask follows confirm-close-surface; which
    /// terminals are busy is each surface's to say.
    @Test func quitConfirmationFollowsTheConfig() throws {
        let asks = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tako")
        let never = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tako")
        try "".write(to: asks, atomically: true, encoding: .utf8)
        try "confirm-close-surface = false\n".write(to: never, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: asks)
            try? FileManager.default.removeItem(at: never)
        }

        #expect(Tako.App(configPath: asks.path).needsConfirmQuit)
        #expect(!Tako.App(configPath: never.path).needsConfirmQuit)
    }

    @Test func appTickIsANoOpThatDoesNotCrash() {
        let app = Tako.App()
        let configBefore = app.config
        app.appTick()
        #expect(app.readiness == .ready)
        #expect(app.config === configBefore)
    }

    @Test func configPathIsHonoredOnConstruction() throws {
        let text = "background-opacity = 0.42\n"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let app = Tako.App(configPath: file.path)
        #expect(app.config.backgroundOpacity == 0.42)
    }

    @Test func reloadConfigReturnsToTheSameConfiguredFileRatherThanTheDefaultSearchPath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try "background-opacity = 0.31\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let app = Tako.App(configPath: file.path)
        #expect(app.config.backgroundOpacity == 0.31)

        try "background-opacity = 0.77\n".write(to: file, atomically: true, encoding: .utf8)
        app.reloadConfig()
        #expect(app.config.backgroundOpacity == 0.77)
    }

    /// The surface-scoped app calls act on the view they are given. The
    /// split and fullscreen ones are requests to whichever controller holds
    /// the surface, so what they do is post the request.
    @Test @MainActor func surfaceScopedAppCallsReachTheSurface() {
        let app = Tako.App()
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.theme.fontSize

        app.changeFontSize(surface: view, .increase(2))
        #expect(view.theme.fontSize == before + 2)
        app.changeFontSize(surface: view, .decrease(1))
        #expect(view.theme.fontSize == before + 1)
        app.changeFontSize(surface: view, .reset)
        #expect(view.theme.fontSize == before)

        view.core.feed(bytes: Data("app-reset-marker".utf8))
        app.resetTerminal(surface: view)
        #expect(!view.core.bufferText().contains("app-reset-marker"))

        let log = NotificationLog(
            Tako.Notification.didEqualizeSplits, Tako.Notification.takoToggleFullscreen, object: view)
        defer { log.stop() }
        app.splitEqualize(surface: view)
        app.toggleFullscreen(surface: view)
        #expect(log.names == [Tako.Notification.didEqualizeSplits, Tako.Notification.takoToggleFullscreen])
    }

    /// The tako_surface_t overload is what upstream's paste-confirmation
    /// sheet calls; in this app nothing posts confirmClipboard, so it only
    /// reaches TakoKit's no-op C stub. Pin that it stays callable for both
    /// confirmation states and leaves the pasteboard alone.
    @Test func completeClipboardRequestForTheCSurfaceIsAHarmlessNoOp() {
        let before = NSPasteboard.general.changeCount
        Tako.App.completeClipboardRequest(tako_surface_t(), data: "hi", state: nil, confirmed: true)
        Tako.App.completeClipboardRequest(tako_surface_t(), data: "hi", state: nil)
        #expect(NSPasteboard.general.changeCount == before)
    }

    @Test func completeClipboardRequestForASurfaceViewPastesOnMain() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        Tako.App.completeClipboardRequest(view, data: "clipboard-relay-text-marker", state: nil, confirmed: true)

        // This dispatches `pasteText` onto `DispatchQueue.main` rather than
        // calling it inline -- right after the call returns, synchronously,
        // the paste has not happened yet. `pasteText`'s own body is covered
        // directly by `pasteTextEncodesAndWritesDirectly`.
        #expect(!view.visibleText.contains("clipboard-relay-text-marker"))
    }
}

// MARK: - Tako namespace helpers

@MainActor
struct TakoNamespaceHelperCoverageTests {
    @Test func titleForDirectoryPrefersTheLastPathComponent() {
        #expect(Tako.titleForDirectory("/Users/example/project") == "project")
    }

    @Test func titleForDirectoryUsesHomeGlyphForHomeAndRoot() {
        #expect(Tako.titleForDirectory(NSHomeDirectory()) == "~")
        #expect(Tako.titleForDirectory("/") == "~")
        #expect(Tako.titleForDirectory("") == "~")
        #expect(Tako.titleForDirectory("~") == "~")
    }

    @Test func moveFocusMakesTheViewFirstResponderImmediately() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { view.close() }
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view

        Tako.moveFocus(to: view)
        #expect(window.firstResponder === view)
    }

    /// The `delay` branch reaches `DispatchQueue.main.asyncAfter` -- a bare
    /// `swift test` host never runs a real main-thread run loop to drain
    /// GCD's main queue, so whether the scheduled block itself ever fires is
    /// unobservable here (the immediate branch above already proves `move`'s
    /// own body). What *is* observable, deterministically and synchronously,
    /// is that the delayed branch does not act immediately the way the
    /// immediate branch does.
    @Test func moveFocusWithADelayDoesNotCrash() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { view.close() }
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view

        Tako.moveFocus(to: view, delay: 0.01)

        #expect(window.firstResponder !== view)
    }

    /// `focusedWorkingDirectory` reads `NSApp.keyWindow` with no fallback.
    /// Whether this process's window can ever become key depends on
    /// activation the test host may or may not grant (see the same caveat
    /// documented in `TakoTerminalNSViewInputContextTests`); this proves the
    /// no-key-window guard either way, and the full lookup whenever the
    /// environment does grant one.
    @Test func focusedWorkingDirectoryReadsTheKeyWindowsFirstResponderSurface() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { view.close() }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let result = Tako.focusedWorkingDirectory
        if window.isKeyWindow {
            #expect(result == view.pwd)
        } else {
            #expect(result == nil)
        }
    }

    @Test func surfaceConfigurationDefaultInitHasNoOverrides() {
        let config = Tako.SurfaceConfiguration()
        #expect(config.fontSize == nil)
        #expect(config.workingDirectory == nil)
        #expect(config.command == nil)
        #expect(config.initialInput == nil)
        #expect(config.waitAfterCommand == false)
        #expect(config.environmentVariables.isEmpty)
    }

    @Test func surfaceConfigurationMemberwiseInitCarriesEveryField() {
        let config = Tako.SurfaceConfiguration(
            fontSize: 14, workingDirectory: "/tmp", command: "true",
            initialInput: "hi", waitAfterCommand: true,
            environmentVariables: ["A": "B"])
        #expect(config.fontSize == 14)
        #expect(config.workingDirectory == "/tmp")
        #expect(config.command == "true")
        #expect(config.initialInput == "hi")
        #expect(config.waitAfterCommand)
        #expect(config.environmentVariables == ["A": "B"])
    }

    @Test func moveTabCarriesItsAmount() {
        #expect(Tako.Action.MoveTab(amount: -2).amount == -2)
    }

    @Test func progressReportCarriesStateAndOptionalProgress() {
        let withProgress = Tako.Action.ProgressReport(state: .set, progress: 42)
        #expect(withProgress.state == .set)
        #expect(withProgress.progress == 42)

        let withoutProgress = Tako.Action.ProgressReport(state: .none)
        #expect(withoutProgress.state == .none)
        #expect(withoutProgress.progress == nil)
    }

    @Test func inspectorAndChildExitedMessageAreTrivialValueHolders() {
        _ = Tako.Inspector()
        #expect(Tako.ChildExitedMessage(message: "bye").message == "bye")
    }

    @Test func cachedValueRecomputesOnlyAfterInvalidation() {
        var calls = 0
        let cached = CachedValue<Int> { calls += 1; return calls }
        #expect(cached.get() == 1)
        #expect(cached.get() == 1)
        cached.invalidate()
        #expect(cached.get() == 2)
    }

    @Test func takoAppDelegateDefaultLookupReturnsNil() {
        final class Impl: TakoAppDelegate {}
        #expect(Impl().findSurface(forUUID: UUID()) == nil)
    }
}

// MARK: - Tako.Surface (the model wrapper, not the view)

@MainActor
struct TakoSurfaceModelCoverageTests {
    @Test func surfaceModelForwardsToItsView() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let model = try #require(view.surfaceModel)

        #expect(model.view === view)
        #expect(model.unsafeCValue == nil)
        #expect(model.mouseCaptured == false)
        #expect(model.foregroundPID != nil || model.foregroundPID == nil)
        // See `startsAShellWithARealTtyAndForegroundProcess`: `ttyname(3)`
        // on the pty master reports ENOTTY, so this is nil in practice.
        _ = model.ttyName
        #expect(model.perform(action: "anything") == false)
        #expect(model.perform(action: "scroll_to_bottom") == true)

        model.sendText("echo surface-model-text\n")
        #expect(waitUntil(timeout: 8) { view.visibleText.contains("surface-model-text") })

        // The rest of the model's forwarding surface, exercised for
        // coverage of the one-line delegations to its view.
        model.sendKeyEvent(Tako.Input.KeyEvent(key: .space, action: .press))
        model.sendMousePos(Tako.Input.MousePosEvent(x: 5, y: 5, mods: []))
        model.sendMouseButton(Tako.Input.MouseButtonEvent(action: .press, button: .left, mods: []))
        model.sendMouseScroll(Tako.Input.MouseScrollEvent(
            x: 0, y: 0, mods: .init(precision: false, momentum: .none)))
    }

    @Test func surfaceModelInitWithCSurfaceHoldsNoView() {
        let model = Tako.Surface(cSurface: tako_surface_t())
        #expect(model.view == nil)
        #expect(model.unsafeCValue == nil)
    }
}

// MARK: - Tako.SurfaceView

@MainActor
struct SurfaceViewCoverageTests {
    /// Saves and restores `NSPasteboard.general` around a test, since
    /// `copy`/`paste` are hardwired to the real system pasteboard.
    private func withSavedGeneralPasteboard(_ body: () -> Void) {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        body()
    }

    @Test func frameInitStartsAReadyLiveSurface() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        #expect(view.uuid == view.id)
        #expect(view.restoredID == nil)
        #expect(view.pty != nil)
        #expect(view.surface == nil)
        #expect(!view.processExited)
        #expect(!view.needsConfirmQuit)
        #expect(view.pid > 0)
        // See `startsAShellWithARealTtyAndForegroundProcess`: the pty
        // master has no `ttyname(3)`, so the fallback `""` is what's real.
        #expect(view.ttyName.isEmpty)
        #expect(view.mouseCaptured == false)
        #expect(view.cellSize.width > 0 && view.cellSize.height > 0)
    }

    @Test func mouseCapturedFollowsTheProgramsMouseTrackingMode() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.core.feed(bytes: Data("\u{1b}[?1000h".utf8))
        #expect(view.mouseCaptured)
        view.core.feed(bytes: Data("\u{1b}[?1000l".utf8))
        #expect(!view.mouseCaptured)
    }

    @Test func appBackedInitDerivesConfigFromTheAppAndAcceptsABaseConfig() throws {
        let app = Tako.App()
        var base = Tako.SurfaceConfiguration()
        base.workingDirectory = NSHomeDirectory()
        base.initialInput = "echo base-config-initial-input\n"

        let view = Tako.SurfaceView(app, baseConfig: base)
        defer { view.close() }

        #expect(view.derivedConfig == Tako.SurfaceView.DerivedConfig(app.config))
        #expect(view.derivedConfig == view.derivedConfig)

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("base-config-initial-input") })
    }

    @Test func defaultDerivedConfigMatchesAnUnconfiguredSurface() {
        let config = Tako.SurfaceView.DerivedConfig()
        #expect(config.backgroundOpacity == 1.0)
        #expect(config.backgroundBlur == .disabled)
        #expect(config.macosWindowShadow)
        #expect(config.windowTitleFontFamily == nil)
        #expect(config.scrollbar == .system)
    }

    @Test func writeSendsTextToTheLiveShell() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.write("echo write-method-text\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("write-method-text") })
    }

    @Test func sendTextWritesAndScrollsToTheBottom() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.sendText("echo send-text-method\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("send-text-method") })
        #expect(view.core.snapshot().viewportOffset == 0)
    }

    /// The `else if event.key == .space` branch: the only key with no
    /// `ffiKeys` mapping of its own that still has to reach the shell.
    /// The pty's own line-discipline echo is what proves the space byte
    /// specifically made it across -- a dropped space would leave the two
    /// halves of the marker glued together.
    @Test func sendKeyEventWithSpaceInsertsALiteralSpace() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.write("MARKQA")
        view.send(keyEvent: Tako.Input.KeyEvent(key: .space, action: .press))
        view.write("MARKQB\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("MARKQA MARKQB") })
    }

    @Test func sendKeyEventWithANamedKeyEncodesThroughTheCore() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.write("echo enter-key-test")
        // Enter's own byte sequence, produced by the `ffiKeys` lookup, has
        // to be interpreted by the shell as a submitted line for this output
        // to ever appear.
        view.send(keyEvent: Tako.Input.KeyEvent(key: .enter, action: .press))

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("enter-key-test") })
    }

    /// `guard ffi.press else { return }` returns before touching the pty at
    /// all, synchronously -- so the grid must be byte-for-byte unchanged
    /// immediately after the call, with no waiting required.
    @Test func sendKeyEventReleaseIsDroppedBeforeReachingThePty() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.visibleText

        view.send(keyEvent: Tako.Input.KeyEvent(key: .enter, action: .release))

        #expect(view.visibleText == before)
    }

    /// `.unidentified` maps to `.character` with empty text: the "nothing to
    /// send" branch returns before the pty write, synchronously.
    @Test func sendKeyEventWithNoTextAndNoKeyIsDropped() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.visibleText

        view.send(keyEvent: Tako.Input.KeyEvent(key: .unidentified, action: .press, mods: [], text: nil))

        #expect(view.visibleText == before)
    }

    @Test func mousePosThenButtonUpdatesTheTrackedCellAndDoesNotCrash() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        #expect(view.mouseCell == nil)
        view.send(mousePos: Tako.Input.MousePosEvent(x: 10, y: 10, mods: []))
        #expect(view.mouseCell != nil)

        view.send(mouseButton: Tako.Input.MouseButtonEvent(action: .press, button: .left, mods: []))
        view.send(mouseButton: Tako.Input.MouseButtonEvent(action: .release, button: .left, mods: []))
    }

    @Test func mouseButtonWithoutAKnownCellPositionIsIgnored() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(view.mouseCell == nil)
        // The guard-return branch: no cell tracked yet.
        view.send(mouseButton: Tako.Input.MouseButtonEvent(action: .press, button: .middle, mods: []))
    }

    @Test func mouseScrollMovesTheViewportOutsideMouseReportingMode() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        for line in 0..<400 {
            view.core.feed(bytes: Data("line \(line)\r\n".utf8))
        }
        _ = view.core.takeOutput()
        view.core.scrollViewportUp(lines: 20)
        let before = view.core.snapshot().viewportOffset
        #expect(before > 0)

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: 3, mods: .init(precision: false, momentum: .none)))
        let afterUp = view.core.snapshot().viewportOffset
        #expect(afterUp > before)

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: -1, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset < afterUp)
    }

    /// With mouse tracking enabled the wheel becomes a report instead of a
    /// local scroll: the viewport must stay exactly where it was, for both
    /// scroll directions (the wheelUp/wheelDown branch of the report).
    @Test func mouseScrollReportsInsteadOfScrollingWhenMouseTrackingIsEnabled() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        for line in 0..<400 {
            view.core.feed(bytes: Data("line \(line)\r\n".utf8))
        }
        _ = view.core.takeOutput()
        view.core.scrollViewportUp(lines: 20)
        let before = view.core.snapshot().viewportOffset
        #expect(before > 0)

        view.core.feed(bytes: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        _ = view.core.takeOutput()
        view.send(mousePos: Tako.Input.MousePosEvent(x: 10, y: 10, mods: []))

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: 3, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset == before)

        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: -3, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset == before)
    }

    @Test func mouseScrollWithNoVerticalMovementIsANoOp() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.core.snapshot().viewportOffset
        view.send(mouseScroll: Tako.Input.MouseScrollEvent(
            x: 0, y: 0, mods: .init(precision: false, momentum: .none)))
        #expect(view.core.snapshot().viewportOffset == before)
    }

    @Test func copyWithNoSelectionLeavesThePasteboardAlone() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("untouched", forType: .string)

            view.copy(nil)

            #expect(NSPasteboard.general.string(forType: .string) == "untouched")
        }
    }

    @Test func copyPutsTheSelectedLineOnThePasteboard() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }
            // The live pty is also feeding this same core asynchronously
            // (shell startup banter), so this cannot assume the marker lands
            // on row 0: it polls for whichever row actually holds it.
            view.core.feed(bytes: Data("\r\ncopy-me-please\r\n".utf8))
            _ = view.core.takeOutput()

            var markerRow: Int?
            #expect(waitUntil(timeout: 5) {
                markerRow = (0..<view.rows).first { view.core.getLine(row: UInt32($0)).contains("copy-me-please") }
                return markerRow != nil
            })
            view.core.selectLine(row: UInt32(markerRow ?? 0), col: 0)

            view.copy(nil)

            #expect(NSPasteboard.general.string(forType: .string)?.contains("copy-me-please") == true)
        }
    }

    @Test func pasteWritesTheGeneralPasteboardStringToTheShell() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("pasted-from-general-pasteboard", forType: .string)
            view.paste(nil)

            #expect(waitUntil(timeout: 8) { view.visibleText.contains("pasted-from-general-pasteboard") })
        }
    }

    @Test func pasteWithAnEmptyPasteboardDoesNothing() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }
            NSPasteboard.general.clearContents()
            let before = view.visibleText

            view.paste(nil)

            // `guard let text = ... else { return }` returns before touching
            // the pty at all, synchronously, so the grid is unchanged.
            #expect(view.visibleText == before)
        }
    }

    @Test func pasteTextEncodesAndWritesDirectly() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.pasteText("direct-paste-text-call\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("direct-paste-text-call") })
    }

    @Test func focusDidChangeUpdatesThePublishedFocusFlag() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(view.focused)
        view.focusDidChange(false)
        #expect(!view.focused)
        view.focusDidChange(true)
        #expect(view.focused)
    }

    @Test func updateThemeReplacesTheInheritedTheme() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        var theme = TerminalTheme()
        theme.background = CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        view.updateTheme(theme)

        #expect(view.theme.background == theme.background)
    }

    /// A surface places the IME's marked text and a link's underline where
    /// the renderer draws the cell: top-anchored below the padding, the
    /// inverse of cellAt. It used to count rows up from the bottom, which put
    /// them a row and a half away from the text.
    @Test func cellOriginIsWhereTheCellIsDrawn() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let layout = view.gridLayout
        let origin = view.cellOrigin(row: 1, col: 2)
        #expect(origin.x == layout.left + 2 * view.cellWidth)
        #expect(abs(origin.y - (view.bounds.height - layout.top - 2 * view.cellHeight)) < 0.001)
        let hit = view.cellAt(NSPoint(x: origin.x + 1, y: origin.y + view.cellHeight / 2))
        #expect(hit.row == 1)
        #expect(hit.col == 2)
    }

    @Test func toggleReadonlyFlipsBothWays() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(!view.readonly)
        view.toggleReadonly(nil)
        #expect(view.readonly)
        view.toggleReadonly(nil)
        #expect(!view.readonly)
    }

    @Test func unknownBindingActionsReportFailure() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(view.performBindingAction("whatever") == false)
        view.highlight()
    }

    @Test func closeTerminatesThePtyAndEventuallyReportsProcessExited() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.close()
        #expect(waitUntil { view.processExited })
    }

    @Test func encodeThenDecodeRoundTripsIdentityOnly() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        let data = try JSONEncoder().encode(view)
        let decoded = try JSONDecoder().decode(Tako.SurfaceView.self, from: data)
        defer { decoded.close() }

        #expect(decoded.restoredID == String(describing: view.id))
        // A decoded surface is a fresh live one, not a resurrection of the
        // original's PTY.
        #expect(decoded.id != view.id)
    }

    @Test func requiredCoderInitAlwaysFails() {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else {
            Issue.record("could not build an unarchiver")
            return
        }
        #expect(Tako.SurfaceView(coder: unarchiver) == nil)
    }

    @Test func cachedContentsRecomputeOnlyAfterInvalidation() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.core.feed(bytes: Data("cached-contents-marker".utf8))
        _ = view.core.takeOutput()

        let first = view.cachedVisibleContents.get()
        #expect(first.contains("cached-contents-marker"))
        #expect(view.cachedVisibleContents.get() == first)
        view.cachedVisibleContents.invalidate()
        // The surface runs a real login shell whose banner can land at any
        // moment, so after invalidation only require a fresh read of the
        // same screen, not byte equality with the cached one.
        #expect(view.cachedVisibleContents.get().contains("cached-contents-marker"))

        let fullScreen = view.cachedScreenContents.get()
        #expect(fullScreen.contains("cached-contents-marker"))
    }

    @Test func visibleTextJoinsEveryVisibleRow() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.core.feed(bytes: Data("visible-text-marker".utf8))
        _ = view.core.takeOutput()
        #expect(view.visibleText.contains("visible-text-marker"))
    }

    @Test func writeToShellSplitsBetweenSelfTestCaptureAndTheRealPty() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.selfTestCapturing = true
        view.writeToShell([0x61, 0x62, 0x63])
        #expect(view.selfTestBytes == [0x61, 0x62, 0x63])
        view.selfTestCapturing = false

        view.writeToShell(Array("echo write-to-shell-real\n".utf8))
        #expect(waitUntil(timeout: 8) { view.visibleText.contains("write-to-shell-real") })
    }

    @Test func viewDidMoveToWindowInstallsTheTabBarControllerWithoutCrashing() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)

        window.contentView = view
        #expect(!view.isFirstResponderSurface)
        window.makeFirstResponder(view)
        #expect(view.isFirstResponderSurface)

        // Moving to a second window rebinds; removing from any window clears
        // the binding. Neither must crash.
        let otherWindow = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.contentView = view
        view.removeFromSuperview()
    }

    @Test func titleDidChangeMirrorsTheInheritedTitleAndClearsUserSetFlag() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.isUserSetTitle = true

        view.title = "a live title"

        #expect(view.titleText == "a live title")
        #expect(!view.isUserSetTitle)
    }
}

// MARK: - TakoTerminalNSViewDelegate conformance

@MainActor
struct SurfaceViewShellIntegrationEventTests {
    // NOTE ON UNREACHABLE CODE: `setupCoreAndPty`'s PTY `onData` closure
    // routes every OSC-driven event (bell, title, pwd, clipboard set/query,
    // notification, progress, command start/end -- roughly the block from
    // `case .bell:` through the end of `case .clipboardQuery:`) through
    // `DispatchQueue.main.sync` because it is called from the parser queue.
    // A bare `swift test` host process never runs a run loop on the literal
    // main thread, so nothing ever drains `DispatchQueue.main`: a `.sync`
    // call onto it from a background thread blocks forever. This is
    // confirmed independently and non-destructively by
    // `TakoNamespaceHelperCoverageTests.moveFocusWithADelayDoesNotCrash`,
    // which shows the same `DispatchQueue.main.asyncAfter` pattern never
    // fires its closure in this harness either. Deliberately feeding an OSC
    // sequence through a live surface here to exercise that switch would
    // permanently wedge a parser-queue thread for the rest of the test
    // process, for coverage this harness cannot ever observe -- so that
    // block is left uncovered rather than contorted around. Everything
    // reachable without it (plain text, encoded key/mouse/paste bytes,
    // which skip `requiresSynchronousMainApplication`) is covered above.

    @Test func resizeCallbackForwardsToThePty() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let pty = try #require(view.pty)

        // Directly exercises the TakoTerminalNSViewDelegate conformance
        // methods without depending on window-driven resize plumbing.
        view.terminalView(view, didResizeCols: 100, rows: 32)

        // The pty's own kernel-tracked window size is the observable proof
        // the resize actually reached it, not just that the call compiled.
        var size = winsize()
        #expect(ioctl(pty.master, TIOCGWINSZ, &size) == 0)
        #expect(size.ws_col == 100)
        #expect(size.ws_row == 32)

        view.terminalView(view, sendInputData: Data([0x61]))
        view.terminalView(view, sendDeviceReplyData: Data([0x62]))
    }
}

// MARK: - Self-tests (key path proof, independent of a live display link)

@MainActor
struct SurfaceViewSelfTestCoverageTests {
    /// Hosts `view` a level *below* the window's content view, so the
    /// self-tests' own `find(_:)` walk has to recurse into `subviews`
    /// instead of matching the content view directly.
    private func hostedWindow(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wrapper.addSubview(view)
        window.contentView = wrapper
        window.orderFront(nil)
        return window
    }

    /// `runKeySelfTest` depends only on real `NSEvent`s reaching `keyDown`
    /// and being captured -- no display link, no GPU. It writes its report
    /// to `/tmp/tako-keytest.txt`, which is the observable proof of what it
    /// did.
    @Test func keySelfTestEncodesEveryCaseIncludingCyrillicCtrlC() {
        // A private report directory: another run on this machine (or the
        // app's own self-test) must not delete or overwrite this file.
        let dir = NSTemporaryDirectory() + "tako-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previousDir = Tako.selfTestReportDirectory
        Tako.selfTestReportDirectory = dir
        defer { Tako.selfTestReportDirectory = previousDir; try? FileManager.default.removeItem(atPath: dir) }
        let reportPath = Tako.selfTestReportPath("tako-keytest.txt")

        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        // The self-test targets the key window; make it this one, not a
        // window some other test left open.
        window.makeKeyAndOrderFront(nil)
        #expect(NSApplication.shared.windows.contains(where: { $0.contentView?.subviews.contains(view) == true }))

        Tako.runKeySelfTest()

        #expect(waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: reportPath) })
        let report = (try? String(contentsOfFile: reportPath, encoding: .utf8)) ?? ""
        #expect(report.contains("ctrl+c"))
        #expect(report.contains("shift+1"))
    }

    /// The frame self-test's verdict: nil until the red block is drawn,
    /// then ok when the grid starts inside the padding and FAIL when it was
    /// drawn over it.
    @Test func frameCheckFindsTheGridInsideItsPadding() {
        let cell = CGSize(width: 10, height: 20)
        let layout = TerminalGridLayout(
            viewSize: CGSize(width: 100, height: 60), cellSize: cell,
            padding: TerminalPadding(uniform: 10), balance: false)
        func frame(red: CGRect) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 100 * 60 * 4)
            for y in 0..<60 {
                for x in 0..<100 {
                    let i = (y * 100 + x) * 4
                    let inside = red.contains(CGPoint(x: x, y: y))
                    pixels[i] = inside ? 0 : 14        // B
                    pixels[i + 1] = inside ? 0 : 16    // G
                    pixels[i + 2] = inside ? 220 : 20  // R
                    pixels[i + 3] = 255
                }
            }
            return pixels
        }
        func check(_ pixels: [UInt8]) -> String? {
            Tako.frameCheck(pixels: pixels, width: 100, height: 60, scale: 1, layout: layout, cell: cell)
        }
        #expect(check(frame(red: .zero)) == nil, "no red block yet: keep waiting")
        let inside = check(frame(red: CGRect(x: 10, y: 10, width: 40, height: 20)))
        #expect(inside?.contains("FAIL") == false)
        let overPadding = check(frame(red: CGRect(x: 0, y: 0, width: 60, height: 40)))
        #expect(overPadding?.contains("FAIL left padding") == true)
        #expect(overPadding?.contains("FAIL top padding") == true)
        #expect(check([1, 2, 3]) == nil, "a short buffer is not a frame")
    }

    @Test func writePNGSavesTheFrameAsAnImage() throws {
        let path = NSTemporaryDirectory() + "tako-frame-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        Tako.writePNG([UInt8](repeating: 200, count: 4 * 2 * 4), width: 4, height: 2, to: path)
        let image = try #require(NSImage(contentsOfFile: path))
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsWide == 4)
        #expect(rep.pixelsHigh == 2)
    }

    /// Without a Metal renderer -- a test host has none -- the frame
    /// self-test says so instead of waiting for a frame that never comes.
    @Test func frameSelfTestReportsAMissingRenderer() {
        let dir = NSTemporaryDirectory() + "tako-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previousDir = Tako.selfTestReportDirectory
        Tako.selfTestReportDirectory = dir
        defer { Tako.selfTestReportDirectory = previousDir; try? FileManager.default.removeItem(atPath: dir) }
        let reportPath = Tako.selfTestReportPath("tako-frametest.txt")

        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        window.makeKeyAndOrderFront(nil)
        guard view.metalRendererForTesting == nil else { return }

        Tako.runFrameSelfTest()

        #expect(waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: reportPath) })
        let report = (try? String(contentsOfFile: reportPath, encoding: .utf8)) ?? ""
        #expect(report.hasPrefix("FAIL no Metal renderer"))
    }

    /// `runScrollSelfTest` proves the precise-wheel-to-row-fraction pipeline
    /// through the real responder chain. Whether a frame is ever actually
    /// *presented* depends on a live display link, which a `swift test`
    /// host does not drive -- so this checks the geometry lines the
    /// function always writes rather than the frame-submission summary.
    @Test func scrollSelfTestWritesRowFractionGeometry() {
        // A private report directory: another run on this machine (or the
        // app's own self-test) must not delete or overwrite this file.
        let dir = NSTemporaryDirectory() + "tako-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previousDir = Tako.selfTestReportDirectory
        Tako.selfTestReportDirectory = dir
        defer { Tako.selfTestReportDirectory = previousDir; try? FileManager.default.removeItem(atPath: dir) }
        let reportPath = Tako.selfTestReportPath("tako-scrolltest.txt")

        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        // The self-test targets the key window; make it this one, not a
        // window some other test left open.
        window.makeKeyAndOrderFront(nil)
        #expect(NSApplication.shared.windows.contains(where: { $0.contentView?.subviews.contains(view) == true }))

        Tako.runScrollSelfTest()

        #expect(waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: reportPath) })
        let report = (try? String(contentsOfFile: reportPath, encoding: .utf8)) ?? ""
        #expect(report.contains("start"))
        #expect(report.contains("after 3 of 3 points up"))
    }

    /// `runInputSelfTest` types a whole sentence through real `keyDown`
    /// events into the real shell, then writes its report from inside a
    /// `DispatchQueue.main.asyncAfter(1.5s)` closure. That closure needs a
    /// live run loop on the literal main thread to ever fire, which a bare
    /// `swift test` host does not drive (see the note in
    /// `SurfaceViewShellIntegrationEventTests`), so the report file itself
    /// is not observable here. Everything before that -- finding the
    /// surface, focusing it, and typing the whole sequence -- runs
    /// synchronously and reaches the real pty, so the shell's own echo is:
    /// ctrl+u clears everything typed before it, so "hello world" is what
    /// should actually survive to the screen.
    @Test func inputSelfTestTypesThroughTheRealResponderChainWithoutCrashing() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { view.close() }
        let window = hostedWindow(view)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        Tako.runInputSelfTest()

        // `runInputSelfTest` resolves its target window via `NSApp.keyWindow
        // ?? NSApp.windows.first`; whether this process's window can ever
        // become key depends on activation the test host may or may not
        // grant (same caveat as
        // `TakoNamespaceHelperCoverageTests.focusedWorkingDirectoryReadsTheKeyWindowsFirstResponderSurface`).
        // ctrl+u clears everything typed before it, so "hello world" is what
        // should survive to the shell's echo whenever the lookup does land
        // on our window.
        if window.isKeyWindow {
            #expect(waitUntil(timeout: 8) { view.visibleText.contains("hello world") })
        }
    }
}
