/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
import UserNotifications
@testable import Tako

@Suite
@MainActor
struct NotificationTests {
    init() {
        AppDelegate.notificationCenterProvider = { nil }
    }

    @Test func textSanitizationStripsControlAndEscapeSequences() {
        // ANSI CSI color sequences
        let csiText = "\u{1b}[31;1mError:\u{1b}[0m Something failed"
        #expect(Tako.sanitizeNotificationText(csiText) == "Error: Something failed")

        // ANSI OSC sequence
        let oscText = "\u{1b}]0;Title\u{07}Hello World"
        #expect(Tako.sanitizeNotificationText(oscText) == "Hello World")

        // C0 control characters (preserves newline and tab)
        let c0Text = "\u{01}\u{02}Alert:\tSystem ready\nNext line\u{03}\u{04}"
        #expect(Tako.sanitizeNotificationText(c0Text) == "Alert:\tSystem ready\nNext line")

        // C1 control characters
        let c1Text = "Clean\u{80}\u{85}\u{9f}Text"
        #expect(Tako.sanitizeNotificationText(c1Text) == "CleanText")

        // Max length capping
        let longText = String(repeating: "a", count: 2000)
        let capped = Tako.sanitizeNotificationText(longText, maxLength: 50)
        #expect(capped.count == 50)
    }

    @Test func projectFromWorkingDirectoryDerivation() {
        #expect(Tako.projectFromWorkingDirectory("/Users/alex/projects/my-project") == "my-project")
        #expect(Tako.projectFromWorkingDirectory("/var/log") == "log")
        #expect(Tako.projectFromWorkingDirectory("", fallbackTitle: "Shell") == "Shell")
        #expect(Tako.projectFromWorkingDirectory("/", fallbackTitle: "Terminal") == "Terminal")
        #expect(Tako.projectFromWorkingDirectory(nil, fallbackTitle: "Workspace") == "Workspace")
    }

    @Test func coalescerRateLimitingAndBurstWindow() {
        let coalescer = NotificationCoalescer.shared
        coalescer.reset()
        coalescer.burstLimit = 3
        coalescer.burstWindow = 1.0
        coalescer.deduplicationWindow = 0.0 // disable dedup for this burst test

        let surfaceId = UUID()
        let t0 = Date(timeIntervalSince1970: 1000.0)

        // 1st to 3rd: within limit -> postNormal
        #expect(coalescer.process(surfaceId: surfaceId, title: "T1", body: "B1", now: t0) == .postNormal)
        #expect(coalescer.process(surfaceId: surfaceId, title: "T2", body: "B2", now: t0.addingTimeInterval(0.1)) == .postNormal)
        #expect(coalescer.process(surfaceId: surfaceId, title: "T3", body: "B3", now: t0.addingTimeInterval(0.2)) == .postNormal)

        // 4th and 5th: exceeds limit (burstCount > 3) -> coalesce
        #expect(coalescer.process(surfaceId: surfaceId, title: "T4", body: "B4", now: t0.addingTimeInterval(0.3)) == .coalesce(count: 4))
        #expect(coalescer.process(surfaceId: surfaceId, title: "T5", body: "B5", now: t0.addingTimeInterval(0.4)) == .coalesce(count: 5))

        // After window expires (1.5s later) -> reset to postNormal
        let t1 = t0.addingTimeInterval(1.5)
        #expect(coalescer.process(surfaceId: surfaceId, title: "T6", body: "B6", now: t1) == .postNormal)
    }

    @Test func coalescerDeduplicationWithinWindow() {
        let coalescer = NotificationCoalescer.shared
        coalescer.reset()
        coalescer.burstLimit = 10
        coalescer.burstWindow = 5.0
        coalescer.deduplicationWindow = 2.0

        let surfaceId = UUID()
        let t0 = Date(timeIntervalSince1970: 1000.0)

        // Initial notification
        #expect(coalescer.process(surfaceId: surfaceId, title: "Same", body: "Body", now: t0) == .postNormal)

        // Duplicate 0.5s later -> duplicateSuppressed
        #expect(coalescer.process(surfaceId: surfaceId, title: "Same", body: "Body", now: t0.addingTimeInterval(0.5)) == .duplicateSuppressed)

        // Duplicate 1.5s later (still within 2.0s dedup window) -> duplicateSuppressed
        #expect(coalescer.process(surfaceId: surfaceId, title: "Same", body: "Body", now: t0.addingTimeInterval(1.5)) == .duplicateSuppressed)

        // Different title or body within window -> postNormal
        #expect(coalescer.process(surfaceId: surfaceId, title: "Different", body: "Body", now: t0.addingTimeInterval(1.6)) == .postNormal)

        // Same as original but after dedup window has elapsed from last seen -> postNormal
        let t2 = t0.addingTimeInterval(4.0)
        #expect(coalescer.process(surfaceId: surfaceId, title: "Same", body: "Body", now: t2) == .postNormal)
    }

    @Test func buildNotificationContentContextEnrichment() {
        let surfaceId = UUID()
        let content = Tako.buildNotificationContent(
            title: "Build Succeeded",
            body: "Finished in 42s",
            appName: "cargo",
            surfaceId: surfaceId,
            paneTitle: "debug: terminal",
            pwd: "/Users/alex/dev/tako",
            command: "cargo build --release",
            id: "job-42",
            urgency: 2,
            actions: ["View", "Dismiss"],
            reportActivation: true,
            focus: true,
            reportClose: true,
            onlyWhenUnfocused: true,
            coalescedCount: 5
        )

        #expect(content.title == "cargo")
        #expect(content.subtitle == "Build Succeeded")
        #expect(content.body == "Finished in 42s")
        #expect(content.sound == .defaultCritical)
        #expect(content.categoryIdentifier.hasPrefix("tako-cat-job-42"))

        let userInfo = content.userInfo
        #expect(userInfo[Tako.notificationSurfaceKey] as? String == surfaceId.uuidString)
        #expect(userInfo[Tako.notificationPaneTitleKey] as? String == "debug: terminal")
        #expect(userInfo[Tako.notificationProjectKey] as? String == "tako")
        #expect(userInfo[Tako.notificationPwdKey] as? String == "/Users/alex/dev/tako")
        #expect(userInfo[Tako.notificationCommandKey] as? String == "cargo build --release")
        #expect(userInfo[Tako.notificationIdKey] as? String == "job-42")
        #expect(userInfo[Tako.notificationUrgencyKey] as? UInt8 == 2)
        #expect(userInfo[Tako.notificationReportActivationKey] as? Bool == true)
        #expect(userInfo[Tako.notificationFocusKey] as? Bool == true)
        #expect(userInfo[Tako.notificationReportCloseKey] as? Bool == true)
        #expect(userInfo[Tako.notificationOnlyWhenUnfocusedKey] as? Bool == true)
        #expect(userInfo[Tako.notificationCoalescedCountKey] as? Int == 5)
    }

    @Test func shouldPresentRespectsControlKeyAndFocusModeAndUrgency() {
        // Control key always presents
        #expect(Tako.shouldPresent(userInfo: [Tako.notificationFromControlKey: true], surfaceLookedAt: true))

        // macOS Focus mode active: suppresses normal urgency (1) and low (0), permits critical (2)
        let originalFocusHook = Tako.isFocusModeActive
        defer { Tako.isFocusModeActive = originalFocusHook }
        Tako.isFocusModeActive = { true }

        let normalUserInfo: [AnyHashable: Any] = [
            Tako.notificationIdKey: "1",
            Tako.notificationUrgencyKey: UInt8(1)
        ]
        #expect(!Tako.shouldPresent(userInfo: normalUserInfo, surfaceLookedAt: false))

        let criticalUserInfo: [AnyHashable: Any] = [
            Tako.notificationIdKey: "2",
            Tako.notificationUrgencyKey: UInt8(2)
        ]
        #expect(Tako.shouldPresent(userInfo: criticalUserInfo, surfaceLookedAt: false))

        // Focus mode off:
        Tako.isFocusModeActive = { false }

        // onlyWhenUnfocused: suppressed when looked at, shown when not looked at
        let unfocusedOnly: [AnyHashable: Any] = [
            Tako.notificationIdKey: "3",
            Tako.notificationUrgencyKey: UInt8(1),
            Tako.notificationOnlyWhenUnfocusedKey: true
        ]
        #expect(!Tako.shouldPresent(userInfo: unfocusedOnly, surfaceLookedAt: true))
        #expect(Tako.shouldPresent(userInfo: unfocusedOnly, surfaceLookedAt: false))

        // Low urgency (0): suppressed when looked at, shown when not looked at
        let lowUrgency: [AnyHashable: Any] = [
            Tako.notificationIdKey: "4",
            Tako.notificationUrgencyKey: UInt8(0)
        ]
        #expect(!Tako.shouldPresent(userInfo: lowUrgency, surfaceLookedAt: true))
        #expect(Tako.shouldPresent(userInfo: lowUrgency, surfaceLookedAt: false))
    }

    @Test func notificationResponseDispatchReportsActivationAndButtons() {
        let view = Tako.SurfaceView(theme: TerminalTheme())
        view.close()

        var replied: [String] = []
        view.onPtyReply = { replied.append($0) }

        let userInfo: [AnyHashable: Any] = [
            Tako.notificationIdKey: "my-task",
            Tako.notificationReportActivationKey: true,
            Tako.notificationFocusKey: false
        ]

        // 1. Default action (notification clicked directly)
        Tako.dispatchNotificationResponse(
            surface: view,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: userInfo
        )
        #expect(replied == ["\u{1b}]99;i=my-task;\u{1b}\\"])

        // 2. Button 1 clicked (btn_1)
        replied.removeAll()
        Tako.dispatchNotificationResponse(
            surface: view,
            actionIdentifier: "btn_1",
            userInfo: userInfo
        )
        #expect(replied == ["\u{1b}]99;i=my-task;1\u{1b}\\"])

        // 3. Button 2 clicked (btn_2)
        replied.removeAll()
        Tako.dispatchNotificationResponse(
            surface: view,
            actionIdentifier: "btn_2",
            userInfo: userInfo
        )
        #expect(replied == ["\u{1b}]99;i=my-task;2\u{1b}\\"])

        // 4. Default anonymous notification id (nil -> "0")
        replied.removeAll()
        let anonUserInfo: [AnyHashable: Any] = [
            Tako.notificationReportActivationKey: true,
            Tako.notificationFocusKey: false
        ]
        Tako.dispatchNotificationResponse(
            surface: view,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: anonUserInfo
        )
        #expect(replied == ["\u{1b}]99;i=0;\u{1b}\\"])
    }

    @Test func notificationResponseDispatchReportsClose() {
        let view = Tako.SurfaceView(theme: TerminalTheme())
        view.close()

        var replied: [String] = []
        view.onPtyReply = { replied.append($0) }

        // User dismiss with reportClose == true
        let closeUserInfo: [AnyHashable: Any] = [
            Tako.notificationIdKey: "alert-1",
            Tako.notificationReportCloseKey: true
        ]
        Tako.dispatchNotificationResponse(
            surface: view,
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: closeUserInfo
        )
        #expect(replied == ["\u{1b}]99;i=alert-1:p=close;\u{1b}\\"])

        // User dismiss with reportClose == false -> no reply
        replied.removeAll()
        let noReportUserInfo: [AnyHashable: Any] = [
            Tako.notificationIdKey: "alert-1",
            Tako.notificationReportCloseKey: false
        ]
        Tako.dispatchNotificationResponse(
            surface: view,
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: noReportUserInfo
        )
        #expect(replied.isEmpty)
    }

    @Test func surfaceViewPostAndCloseStructuredNotificationFlow() {
        let view = Tako.SurfaceView(theme: TerminalTheme())
        view.close()

        var postedRequests: [UNNotificationRequest] = []
        var removedIds: [[String]] = []
        var ptyReplies: [String] = []

        let origPosted = Tako.onNotificationPosted
        let origRemoved = Tako.onNotificationRemoved
        defer {
            Tako.onNotificationPosted = origPosted
            Tako.onNotificationRemoved = origRemoved
        }

        Tako.onNotificationPosted = { postedRequests.append($0) }
        Tako.onNotificationRemoved = { removedIds.append($0) }
        view.onPtyReply = { ptyReplies.append($0) }

        NotificationCoalescer.shared.reset()

        // Post structured notification with explicit id
        view.postStructuredNotification(
            id: "step-1",
            title: "Step 1",
            body: "Running test",
            appName: "TestRunner",
            urgency: 1,
            actions: ["Stop"],
            reportActivation: true,
            focus: true,
            reportClose: true,
            timeoutMs: nil,
            onlyWhenUnfocused: false
        )

        #expect(postedRequests.count == 1)
        let expectedReqId = "tako-notif-\(view.id.uuidString)-step-1"
        #expect(postedRequests[0].identifier == expectedReqId)
        #expect(postedRequests[0].content.title == "TestRunner")
        #expect(postedRequests[0].content.subtitle == "Step 1")

        // Close structured notification
        view.closeStructuredNotification(id: "step-1", reportClose: true)
        #expect(removedIds.count == 1)
        #expect(removedIds[0] == [expectedReqId])
        #expect(ptyReplies == ["\u{1b}]99;i=step-1:p=close;\u{1b}\\"])
    }

    @Test func feedOsc99GeneratesStructuredNotificationAndCloseEvents() {
        let view = Tako.SurfaceView(theme: TerminalTheme())
        view.close()
        let terminal = view.core

        // Capability query: \e]99;i=q1:p=?;\e\
        let capOutcome = terminal.feedWithOutcome(bytes: Data("\u{1b}]99;i=q1:p=?;\u{1b}\\".utf8))
        let capOutput = String(data: capOutcome.output, encoding: .utf8) ?? ""
        #expect(capOutput == "\u{1b}]99;i=q1:p=?;a=focus,report:c=1:o=always,unfocused,invisible:p=title,body,buttons,close:u=0,1,2\u{1b}\\")

        // Chunk 1: Title (d=0 not done)
        let chunk1 = "\u{1b}]99;i=job-1:d=0;Compiling project\u{1b}\\"
        let out1 = terminal.feedWithOutcome(bytes: Data(chunk1.utf8))
        #expect(out1.events.isEmpty)

        // Chunk 2: Body (d=0 not done)
        let chunk2 = "\u{1b}]99;i=job-1:d=0:p=body;24 packages built\u{1b}\\"
        let out2 = terminal.feedWithOutcome(bytes: Data(chunk2.utf8))
        #expect(out2.events.isEmpty)

        // Chunk 3: Buttons and activation, done (default d=1)
        let chunk3 = "\u{1b}]99;i=job-1:a=report:c=1:p=buttons;Cancel\u{2028}Details\u{1b}\\"
        let out3 = terminal.feedWithOutcome(bytes: Data(chunk3.utf8))
        #expect(out3.events.count == 1)
        if case let .structuredNotification(
            id, title, body, _, _, actions,
            reportActivation, _, reportClose, _, _
        ) = out3.events[0] {
            #expect(id == "job-1")
            #expect(title == "Compiling project")
            #expect(body == "24 packages built")
            #expect(reportActivation == true)
            #expect(reportClose == true)
            #expect(actions == ["Cancel", "Details"])
        } else {
            Issue.record("Expected structuredNotification event")
        }

        // Alive query: \e]99;i=job-1:p=alive;\e\
        let aliveOutcome = terminal.feedWithOutcome(bytes: Data("\u{1b}]99;i=job-1:p=alive;\u{1b}\\".utf8))
        let aliveOutput = String(data: aliveOutcome.output, encoding: .utf8) ?? ""
        #expect(aliveOutput == "\u{1b}]99;i=job-1:p=alive;\u{1b}\\")

        // Close notification: \e]99;i=job-1:p=close:c=1;\e\
        let closeOutcome = terminal.feedWithOutcome(bytes: Data("\u{1b}]99;i=job-1:p=close:c=1;\u{1b}\\".utf8))
        #expect(closeOutcome.events.count == 1)
        if case let .notificationClose(closeId, closeReport) = closeOutcome.events[0] {
            #expect(closeId == "job-1")
            #expect(closeReport == true)
        } else {
            Issue.record("Expected notificationClose event")
        }
    }
}
