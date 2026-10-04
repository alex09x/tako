import Foundation
import Testing
@testable import Tako

@Suite
@MainActor
struct PaneStatusTests {
    @Test func allNineStatusesParseAndPrioritiesAreConsistent() {
        let expectedOrder: [Tako.PaneStatus] = [
            .disconnected,
            .error,
            .needsApproval,
            .waitingForInput,
            .working,
            .running,
            .done,
            .idle,
            .unknown,
        ]

        // Check priorities are strictly descending
        for i in 0..<(expectedOrder.count - 1) {
            #expect(expectedOrder[i].priority > expectedOrder[i + 1].priority,
                    "Expected \(expectedOrder[i]) to have higher priority than \(expectedOrder[i + 1])")
        }

        // Parsing
        #expect(Tako.PaneStatus.parse("idle") == .idle)
        #expect(Tako.PaneStatus.parse("running") == .running)
        #expect(Tako.PaneStatus.parse("working") == .working)
        #expect(Tako.PaneStatus.parse("thinking") == .working, "thinking must be an alias for working")
        #expect(Tako.PaneStatus.parse("waiting_for_input") == .waitingForInput)
        #expect(Tako.PaneStatus.parse("needs_approval") == .needsApproval)
        #expect(Tako.PaneStatus.parse("done") == .done)
        #expect(Tako.PaneStatus.parse("error") == .error)
        #expect(Tako.PaneStatus.parse("disconnected") == .disconnected)
        #expect(Tako.PaneStatus.parse("unknown") == .unknown)
        #expect(Tako.PaneStatus.parse("invalid_status") == nil)
    }

    @Test func statusTextSanitizationStripsControlCharactersAndLimitsLength() {
        let dirty = " \u{0007}\u{001B} building   \t project \u{0000} "
        let clean = Tako.sanitizeStatusText(dirty)
        #expect(clean == "building    project")

        let longText = String(repeating: "x", count: 200)
        let limited = Tako.sanitizeStatusText(longText)
        #expect(limited?.count == 128)
    }

    @Test func durationParsingSupportsUnits() {
        #expect(Tako.parseStatusDuration("10s") == 10.0)
        #expect(Tako.parseStatusDuration("30m") == 1800.0)
        #expect(Tako.parseStatusDuration("1h") == 3600.0)
        #expect(Tako.parseStatusDuration("500ms") == 0.5)
        #expect(Tako.parseStatusDuration("2d") == 172800.0)
        #expect(Tako.parseStatusDuration("45") == 45.0)
        #expect(Tako.parseStatusDuration("-1s") == nil)
        #expect(Tako.parseStatusDuration("abc") == nil)
    }

    @Test func signalStatusTransitionsAndBackgroundUnread() {
        var clock = Date(timeIntervalSince1970: 1000)
        let tracker = Tako.CrabTracker(clock: { clock })

        // Initially idle
        #expect(tracker.paneStatus == .idle)
        #expect(tracker.unread == false)

        // Command starts while unfocused (background tab)
        tracker.isFocused = false
        tracker.commandStarted()
        #expect(tracker.signalStatus == .running)
        #expect(tracker.paneStatus == .running)

        // Command ends with exit code 0
        tracker.commandEnded(exitCode: 0)
        #expect(tracker.signalStatus == .done)
        #expect(tracker.paneStatus == .done)
        #expect(tracker.unread == true, "Unfocused pane should be marked unread")

        // Shell prompt mark arrives (OSC 133;A) before user looks at tab
        tracker.promptMark()
        #expect(tracker.signalStatus == .done, "Unread done must not be cleared by prompt mark")
        #expect(tracker.paneStatus == .done)
        #expect(tracker.unread == true)

        // User focuses the tab
        tracker.focused()
        #expect(tracker.unread == false, "Focusing tab must clear unread")
        #expect(tracker.signalStatus == .idle, "Focusing tab must revert done to idle")
        #expect(tracker.paneStatus == .idle)
    }

    @Test func focusedCommandSuccessShowsSucceededState() {
        var clock = Date(timeIntervalSince1970: 1000)
        let tracker = Tako.CrabTracker(clock: { clock })
        tracker.isFocused = true

        tracker.commandStarted()
        #expect(tracker.signalStatus == .running)
        #expect(tracker.paneStatus == .running)

        // Advance clock beyond minimumVisibleDuration (3s)
        clock = clock.addingTimeInterval(5)
        tracker.commandEnded(exitCode: 0)

        // Focused tab should be idle in paneStatus, unread false, but state is succeeded
        #expect(tracker.signalStatus == .idle)
        #expect(tracker.paneStatus == .idle)
        #expect(tracker.unread == false)
        #expect(tracker.state == .succeeded)
    }

    @Test func signalStatusErrorTransitionsAndFocus() {
        var clock = Date(timeIntervalSince1970: 1000)
        let tracker = Tako.CrabTracker(clock: { clock })

        // Command ends with non-zero exit code while in background
        tracker.isFocused = false
        tracker.commandStarted()
        tracker.commandEnded(exitCode: 1)
        #expect(tracker.signalStatus == .error)
        #expect(tracker.paneStatus == .error)
        #expect(tracker.unread == true)

        // Prompt mark arrives while still unfocused
        tracker.promptMark()
        #expect(tracker.signalStatus == .error)
        #expect(tracker.unread == true)

        // Focus clears error and unread
        tracker.focused()
        #expect(tracker.unread == false)
        #expect(tracker.signalStatus == .idle)
        #expect(tracker.paneStatus == .idle)
    }

    @Test func connectionLostTransitionsToDisconnected() {
        let tracker = Tako.CrabTracker()
        tracker.connectionLost()
        #expect(tracker.signalStatus == .disconnected)
        #expect(tracker.paneStatus == .disconnected)
        #expect(tracker.unread == true)
    }

    @Test func explicitStatusOverridesSignalAndClears() {
        let tracker = Tako.CrabTracker()
        #expect(tracker.paneStatus == .idle)

        // Set explicit status
        tracker.setStatus(.working, text: "compiling Tako", ttl: nil)
        #expect(tracker.paneStatus == .working)
        #expect(tracker.statusText == "compiling Tako")

        // Command starts in background - explicit status still dominates
        tracker.commandStarted()
        #expect(tracker.paneStatus == .working)

        // Clear explicit status reverts to signal status (running)
        tracker.clearStatus()
        #expect(tracker.paneStatus == .running)
        #expect(tracker.statusText == nil)
    }

    @Test func ttlExpiryRevertsStatusToUnknown() async throws {
        let tracker = Tako.CrabTracker()
        tracker.setStatus(.working, text: "running task", ttl: 0.05)
        #expect(tracker.paneStatus == .working)
        #expect(tracker.statusText == "running task")
        #expect(tracker.remainingTTL != nil)

        // Wait for TTL timer to fire
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        #expect(tracker.paneStatus == .unknown, "Status should expire to unknown after TTL")
        #expect(tracker.statusText == nil)
        #expect(tracker.remainingTTL == nil)
    }

    @Test func multiPanePriorityAggregation() {
        let t1 = Tako.CrabTracker()
        t1.signalStatus = .idle

        let t2 = Tako.CrabTracker()
        t2.signalStatus = .running

        let t3 = Tako.CrabTracker()
        t3.signalStatus = .waitingForInput

        let trackers = [t1, t2, t3]
        let dominant = trackers.max(by: { $0.paneStatus.priority < $1.paneStatus.priority })
        #expect(dominant === t3, "waiting_for_input (priority 5) must dominate running (3) and idle (1)")

        // Add needs_approval
        t1.setStatus(.needsApproval, text: "confirm commit")
        let dominant2 = trackers.max(by: { $0.paneStatus.priority < $1.paneStatus.priority })
        #expect(dominant2 === t1, "needs_approval (priority 6) must dominate waiting_for_input (5)")

        // Disconnect t2
        t2.connectionLost()
        let dominant3 = trackers.max(by: { $0.paneStatus.priority < $1.paneStatus.priority })
        #expect(dominant3 === t2, "disconnected (priority 8) must dominate all other statuses")
    }
}
