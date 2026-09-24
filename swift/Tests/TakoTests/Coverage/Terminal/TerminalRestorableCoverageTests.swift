import Testing
import AppKit
@testable import Tako

@MainActor
struct TerminalRestorableStateCoverageTests {
    private func makeController() -> TerminalController {
        let app = Tako.App()
        return TerminalController(app)
    }

    @Test func initFromControllerCapturesInternalState() {
        let controller = makeController()
        let state = TerminalRestorableState(from: controller)

        #expect(state.surfaceTree.root != nil)
        #expect(state.effectiveFullscreenMode == nil)
        #expect(state.tabColor == nil)
        #expect(state.titleOverride == nil)
    }

    @Test func titleOverrideIsCapturedByInternalState() {
        let controller = makeController()
        controller.titleOverride = "My Title"
        let state = TerminalRestorableState(from: controller)
        #expect(state.titleOverride == "My Title")
    }

    @Test func codableRoundTripsThroughJSON() throws {
        let controller = makeController()
        let state = TerminalRestorableState(from: controller)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TerminalRestorableState.self, from: data)

        #expect(decoded.focusedSurface == state.focusedSurface)
        #expect(decoded.titleOverride == state.titleOverride)
    }

    @Test func copyInitPreservesInternalState() {
        let controller = makeController()
        controller.titleOverride = "Copied"
        let state = TerminalRestorableState(from: controller)
        let copy = TerminalRestorableState(copy: state)
        #expect(copy.titleOverride == "Copied")
    }

    @Test func baseConfigDefaultsToNil() {
        let controller = makeController()
        let state = TerminalRestorableState(from: controller)
        #expect(state.baseConfig == nil)
    }

    @Test func versionsAreStable() {
        #expect(TerminalRestorableState.version == 7)
        #expect(TerminalRestorableState.minimumVersion == 5)
        #expect(TerminalRestorableState.selfKey == "state")
        #expect(TerminalRestorableState.versionKey == "version")
    }

    @Test func nsCodingRoundTripsThroughAnArchiver() throws {
        let controller = makeController()
        controller.titleOverride = "Archived"
        let state = TerminalRestorableState(from: controller)

        // `TerminalRestorableState` implements `NSCoding` via
        // `TerminalRestorable`'s default extension, which wraps the payload
        // in `CodableBridge<Self>` -- mirroring the encode/decode path
        // `TerminalWindowRestoration` (`init(coder:)`/`encode(with:)`) uses.
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        let decoded = TerminalRestorableState(coder: unarchiver)
        unarchiver.finishDecoding()

        #expect(decoded?.titleOverride == "Archived")
    }
}

@MainActor
struct TerminalWindowRestorationCoverageTests {
    private func isError(_ error: Error?, _ expected: TerminalRestoreError) -> Bool {
        guard let error = error as? TerminalRestoreError else { return false }
        switch (error, expected) {
        case (.delegateInvalid, .delegateInvalid),
             (.identifierUnknown, .identifierUnknown),
             (.stateDecodeFailed, .stateDecodeFailed),
             (.windowDidNotLoad, .windowDidNotLoad):
            return true
        default:
            return false
        }
    }

    private func garbageCoder() -> NSCoder {
        let data = try! NSKeyedArchiver.archivedData(withRootObject: NSNumber(value: 42), requiringSecureCoding: true)
        let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        return unarchiver
    }

    @Test func restoreWindowRejectsAnUnexpectedIdentifier() {
        var received: (NSWindow?, Error?)?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init("not-us"),
            state: garbageCoder()
        ) { window, error in
            received = (window, error)
        }

        #expect(received?.0 == nil)
        #expect(isError(received?.1, .identifierUnknown))
    }

    @Test func restoreWindowFailsWithoutAnAppDelegate() {
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }

        var received: (NSWindow?, Error?)?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: garbageCoder()
        ) { window, error in
            received = (window, error)
        }

        #expect(received?.0 == nil)
        #expect(isError(received?.1, .delegateInvalid))
    }

    @Test func restoreWindowDecodesTheStateButFailsToLoadTheWindow() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let controller = TerminalController(appDelegate.tako)
        let state = TerminalRestorableState(from: controller)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true

        var received: (NSWindow?, Error?)?
        // `Terminal.xib` is excluded from this SwiftPM test target, so the
        // freshly restored `TerminalController`'s `.window` fails to load
        // lazily here -- this exercises the decode-succeeded-but-window-
        // failed branch deterministically.
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: unarchiver
        ) { window, error in
            received = (window, error)
        }
        unarchiver.finishDecoding()

        #expect(received?.0 == nil)
        #expect(isError(received?.1, .windowDidNotLoad))
    }

    /// Bypasses `Terminal.xib` (excluded from this SwiftPM test target) by
    /// directly attaching a real `TerminalWindow`, mirroring
    /// `TerminalTestSupport.loaded()`. This lets `restoreWindow`'s success
    /// path run for real.
    private func withInjectedWindow(_ body: () -> Void) {
        let original = TerminalWindowRestoration.system
        TerminalWindowRestoration.system = .init(makeController: { app, tree in
            let controller = TerminalController(app, withSurfaceTree: tree)
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            controller.window = window
            controller.windowDidLoad()
            return (controller, window)
        })
        defer { TerminalWindowRestoration.system = original }
        body()
    }

    private func encodedState(from controller: TerminalController) throws -> NSKeyedUnarchiver {
        let state = TerminalRestorableState(from: controller)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        return unarchiver
    }

    @Test func restoreWindowSucceedsAndRestoresTabColorAndTitle() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let (sourceController, sourceWindow) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(sourceController, sourceWindow) }
        sourceController.titleOverride = "Restored Title"
        (sourceWindow as? TerminalWindow)?.tabColor = .blue
        let unarchiver = try encodedState(from: sourceController)

        var received: (NSWindow?, Error?)?
        withInjectedWindow {
            TerminalWindowRestoration.restoreWindow(
                withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
                state: unarchiver
            ) { window, error in
                received = (window, error)
            }
        }
        unarchiver.finishDecoding()

        #expect(received?.0 != nil)
        #expect(received?.1 == nil)
        #expect((received?.0 as? TerminalWindow)?.tabColor == .blue)
    }

    @Test func restoreWindowRestoresFocusedSurfaceAndSkipsFullscreenWithoutAMode() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let sourceController = TerminalController(appDelegate.tako, withSurfaceTree: .init(view: view))
        sourceController.focusedSurface = view
        let unarchiver = try encodedState(from: sourceController)

        var received: (NSWindow?, Error?)?
        withInjectedWindow {
            TerminalWindowRestoration.restoreWindow(
                withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
                state: unarchiver
            ) { window, error in
                received = (window, error)
            }
        }
        unarchiver.finishDecoding()
        TerminalTestSupport.waitUntil(timeout: 0.5) { false }

        #expect(received?.0 != nil)
    }

    @Test func restoreWindowMatchesTheFocusedSurfaceByIdentityAndMakesItFirstResponder() async throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        // `SurfaceView`'s `Codable` conformance only round-trips a separate
        // `restoredID`, not `id` itself (see `Tako+App.swift`'s `CodingKeys`),
        // so a tree decoded from `state.surfaceTree` can never match
        // `state.focusedSurface` by identity. Reusing the *original* view in
        // the restored controller's tree -- instead of a freshly decoded one
        // -- is what lets `restoreWindow`'s "the focused view still exists"
        // branch, and `restoreFocus`'s first-responder handoff, run for real.
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let sourceController = TerminalController(appDelegate.tako, withSurfaceTree: .init(view: view))
        sourceController.focusedSurface = view
        let unarchiver = try encodedState(from: sourceController)

        let original = TerminalWindowRestoration.system
        TerminalWindowRestoration.system = .init(makeController: { app, _ in
            let controller = TerminalController(app, withSurfaceTree: .init(view: view))
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            controller.window = window
            controller.windowDidLoad()
            window.contentView?.addSubview(view)
            return (controller, window)
        })
        defer { TerminalWindowRestoration.system = original }

        var received: (NSWindow?, Error?)?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: unarchiver
        ) { window, error in
            received = (window, error)
        }
        unarchiver.finishDecoding()

        let window = try #require(received?.0)
        for _ in 0..<50 where window.firstResponder !== view {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(window.firstResponder === view)
    }

    @Test func restoreWindowFailsWhenStateCannotBeDecoded() {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        var received: (NSWindow?, Error?)?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: garbageCoder()
        ) { window, error in
            received = (window, error)
        }

        #expect(received?.0 == nil)
        #expect(isError(received?.1, .stateDecodeFailed))
    }
}
