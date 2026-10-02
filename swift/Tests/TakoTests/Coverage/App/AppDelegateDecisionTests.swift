import AppKit
import Carbon
import Foundation
import Testing
import UserNotifications
@testable import Tako

/// The app delegate's decisions, taken out of the modal alerts, Apple
/// Events and notification callbacks they are made in.
@MainActor
struct AppDelegateDecisionTests {
    private func quitEvent(reason: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            event.setAttribute(NSAppleEventDescriptor(typeCode: reason), forKeyword: AppDelegate.quitReasonKeyword)
        }
        return event
    }

    /// The reason was looked up under `AEKeyword("why?")`, which parses the
    /// string as a decimal number and so was always nil: a shutdown,
    /// restart or log-out with a program running asked for confirmation and
    /// held the system up.
    @Test func aShutdownRestartOrLogOutQuitsWithoutAsking() {
        #expect(AppDelegate.quitIsForcedBySystem(quitEvent(reason: OSType(kAEShutDown))))
        #expect(AppDelegate.quitIsForcedBySystem(quitEvent(reason: OSType(kAERestart))))
        #expect(AppDelegate.quitIsForcedBySystem(quitEvent(reason: OSType(kAEReallyLogOut))))
    }

    @Test func theReasonKeywordIsWhy() {
        #expect(AppDelegate.quitReasonKeyword == 0x7768_793F)
    }

    @Test func anOrdinaryQuitStillAsks() {
        #expect(!AppDelegate.quitIsForcedBySystem(nil))
        #expect(!AppDelegate.quitIsForcedBySystem(quitEvent(reason: nil)))
        #expect(!AppDelegate.quitIsForcedBySystem(quitEvent(reason: OSType(kAEQuitApplication))))
    }

    @Test func openingADirectoryStartsAShellThere() {
        let config = AppDelegate.surfaceConfiguration(forOpening: "/tmp/project", isDirectory: true)
        #expect(config.workingDirectory == "/tmp/project")
        #expect(config.initialInput == nil)
        #expect(!config.waitAfterCommand)
    }

    @Test func openingAFileRunsItInAShellInItsDirectoryAndWaits() {
        let config = AppDelegate.surfaceConfiguration(forOpening: "/tmp/my scripts/run.sh", isDirectory: false)
        #expect(config.workingDirectory == "/tmp/my scripts")
        #expect(config.initialInput == "\(Tako.Shell.quote("/tmp/my scripts/run.sh")); exit\n")
        #expect(config.waitAfterCommand)
    }

    @Test func openingAFileTheUserDoesNotAllowOpensNothing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tako-\(UUID().uuidString).sh")
        try "echo hi\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let delegate = AppDelegate()
        var asked: String?
        delegate.runModalAlert = { alert in
            asked = alert.messageText
            return .alertSecondButtonReturn
        }

        #expect(!delegate.application(NSApplication.shared, openFile: file.path))
        #expect(asked?.contains(file.path) == true)
    }

    @Test func theDockBadgeFollowsTheNotificationSettings() {
        #expect(AppDelegate.dockBadgeStep(status: .authorized, badgeSetting: .enabled) == .set)
        #expect(AppDelegate.dockBadgeStep(status: .authorized, badgeSetting: .notSupported) == .requestAuthorization)
        #expect(AppDelegate.dockBadgeStep(status: .authorized, badgeSetting: .disabled) == .none)
        #expect(AppDelegate.dockBadgeStep(status: .notDetermined, badgeSetting: .notSupported) == .requestAuthorization)
        for status in [UNAuthorizationStatus.denied, .provisional] {
            #expect(AppDelegate.dockBadgeStep(status: status, badgeSetting: .enabled) == .none)
        }
    }
}

/// Quitting with several windows that are busy asks once, for all of them.
@MainActor
struct AppDelegateQuitConfirmationTests {
    private func busyWindows(_ count: Int, app: Tako.App) -> [TerminalController] {
        (0..<count).map { _ in
            let controller = TerminalController(app)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller.window = window
            controller.surfaceTree.forEach { $0.confirmCloseSurface = .always }
            window.orderFrontRegardless()
            return controller
        }
    }

    private func close(_ controllers: [TerminalController]) {
        for controller in controllers {
            controller.surfaceTree.forEach { $0.confirmCloseSurface = .never; $0.pty?.terminate() }
            controller.window?.close()
        }
    }

    /// Polls until a question is up in any window -- drawn in the window as
    /// the terminal UI is (`TerminalDialogView`) -- returning it. Doesn't
    /// assume which window: `terminate()`/`reviewWindows` walk
    /// `NSApplication.shared.windows`, whose front-to-back order need not
    /// match the order these helper windows were created in.
    private func waitForQuestion(timeout: TimeInterval = 3) async -> TerminalDialogView? {
        var found: TerminalDialogView?
        _ = await eventually(timeout: timeout) {
            found = NSApplication.shared.windows.lazy.compactMap { TerminalDialogView.pending(in: $0) }.first
            return found != nil
        }
        return found
    }

    /// The confirmation runs in a main-actor Task; only awaiting lets it in.
    private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Terminal windows other tests left busy change which quit path runs.
    private func onlyTheseAreBusy(_ controllers: [TerminalController]) -> Bool {
        NSApplication.shared.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .filter { !$0.windowCanBeClosedWithoutConfirmation() }
            .allSatisfy { busy in controllers.contains { $0 === busy } }
    }

    @Test func terminatingProcessesQuitsAndCancellingStays() async throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let controllers = busyWindows(2, app: delegate.tako)
        defer { close(controllers) }
        #expect(controllers.allSatisfy { !$0.windowCanBeClosedWithoutConfirmation() })
        var replied: Bool?
        delegate.replyToTermination = { replied = $0 }
        guard onlyTheseAreBusy(controllers) else { return }

        #expect(delegate.terminate() == .terminateLater)
        let question = try #require(await waitForQuestion())
        guard case .string(let text)? = question.summary["text"] else { Issue.record("no text"); return }
        #expect(text.contains("2 windows"))
        #expect(question.press("Terminate Processes"))
        #expect(await eventually { replied != nil })
        #expect(replied == true)

        replied = nil
        #expect(delegate.terminate() == .terminateLater)
        #expect(try #require(await waitForQuestion()).press("Cancel"))
        #expect(await eventually { replied != nil })
        #expect(replied == false)
    }

    /// A single busy window skips the "N windows" question and goes straight
    /// to that one controller's own confirmation.
    @Test func terminatingASingleBusyWindowShowsItsOwnQuestionAndReplies() async throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let controllers = busyWindows(1, app: delegate.tako)
        defer { close(controllers) }
        let window = try #require(controllers[0].window)

        var replied: Bool?
        delegate.replyToTermination = { replied = $0 }
        guard onlyTheseAreBusy(controllers) else { return }
        #expect(delegate.terminate() == .terminateLater)

        #expect(await eventually { TerminalDialogView.pending(in: window) != nil })
        #expect(try #require(TerminalDialogView.pending(in: window)).press("Terminate"))

        #expect(await eventually { replied != nil })
        #expect(replied == true)
    }

    @Test func terminatingASingleBusyWindowCancelledKeepsRunning() async throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let controllers = busyWindows(1, app: delegate.tako)
        defer { close(controllers) }
        let window = try #require(controllers[0].window)

        var replied: Bool?
        delegate.replyToTermination = { replied = $0 }
        guard onlyTheseAreBusy(controllers) else { return }
        #expect(delegate.terminate() == .terminateLater)

        #expect(await eventually { TerminalDialogView.pending(in: window) != nil })
        #expect(try #require(TerminalDialogView.pending(in: window)).press("Cancel"))

        #expect(await eventually { replied != nil })
        #expect(replied == false)
    }

    /// Choosing "Review Windows…" walks each busy controller's own
    /// confirmation in turn, closing every one that confirms, then replies
    /// true once they've all been handled.
    @Test func reviewingWindowsClosesEachConfirmedWindowInTurn() async throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let controllers = busyWindows(2, app: delegate.tako)
        defer { close(controllers) }

        var replied: Bool?
        delegate.replyToTermination = { replied = $0 }
        guard onlyTheseAreBusy(controllers) else { return }
        #expect(delegate.terminate() == .terminateLater)
        #expect(try #require(await waitForQuestion()).press("Review Windows…"))

        var answered = 0
        while replied == nil, answered < 4, let question = await waitForQuestion() {
            #expect(question.press("Terminate"))
            answered += 1
        }

        #expect(await eventually { replied != nil })
        #expect(replied == true)
    }

    /// Cancelling any one window's review stops the whole review early and
    /// replies false without closing the rest.
    @Test func reviewingWindowsStopsAtTheFirstCancellation() async throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let controllers = busyWindows(2, app: delegate.tako)
        defer { close(controllers) }

        var replied: Bool?
        delegate.replyToTermination = { replied = $0 }
        guard onlyTheseAreBusy(controllers) else { return }
        #expect(delegate.terminate() == .terminateLater)
        #expect(try #require(await waitForQuestion()).press("Review Windows…"))
        #expect(try #require(await waitForQuestion()).press("Cancel"))

        #expect(await eventually { replied != nil })
        #expect(replied == false)
        #expect(controllers.allSatisfy { $0.window?.isVisible == true })
    }
}
