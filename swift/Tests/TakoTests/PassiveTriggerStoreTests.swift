/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
import UserNotifications
@testable import Tako

@Suite
@MainActor
struct PassiveTriggerStoreTests {
    init() {
        AppDelegate.notificationCenterProvider = { nil }
        PassiveTriggerStore.shared.resetForTesting()
    }

    @Test func testPassiveTriggerStoreRegistrationAndLifecycle() {
        let store = PassiveTriggerStore.shared
        store.resetForTesting()

        let configTrigger = TerminalRegexTrigger(pattern: "config_pattern", action: .highlight)!
        store.setConfigTriggers([configTrigger])
        #expect(store.allTriggers.count == 1)

        let dynamicTrigger = TerminalRegexTrigger(pattern: "dynamic_pattern", action: .notify, isDynamic: true)!
        store.addDynamicTrigger(dynamicTrigger)
        #expect(store.allTriggers.count == 2)

        // Clear dynamic preserves config
        store.clearDynamicTriggers()
        #expect(store.allTriggers.count == 1)
        #expect(store.allTriggers.first?.pattern == "config_pattern")

        // Remove by ID removes config trigger too
        store.removeTrigger(id: configTrigger.id)
        #expect(store.allTriggers.isEmpty)
    }

    @Test func testPassiveTriggerNotificationsWhenUnfocused() {
        let store = PassiveTriggerStore.shared
        store.resetForTesting()

        let surfaceId = UUID()
        let trigger = TerminalRegexTrigger(
            pattern: "BUILD FAILED",
            action: .notify,
            colorName: "red",
            notificationTitle: "Build Failure",
            onlyUnfocused: true
        )!

        var postedNotifications: [UNNotificationRequest] = []
        Tako.onNotificationPosted = { request in
            postedNotifications.append(request)
        }
        defer { Tako.onNotificationPosted = nil }

        let now = Date()

        // 1. Focused surface does NOT post notification when onlyUnfocused == true
        store.handleMatch(
            surfaceId: surfaceId,
            paneTitle: "zsh",
            pwd: "/Users/alex09x/tako",
            trigger: trigger,
            matchedText: "BUILD FAILED in 4.2s",
            isUnfocused: false,
            now: now
        )
        #expect(postedNotifications.isEmpty)

        // 2. Unfocused surface POSTS notification
        store.handleMatch(
            surfaceId: surfaceId,
            paneTitle: "zsh",
            pwd: "/Users/alex09x/tako",
            trigger: trigger,
            matchedText: "BUILD FAILED in 4.2s",
            isUnfocused: true,
            now: now
        )
        #expect(postedNotifications.count == 1)
        let request = postedNotifications[0]
        #expect(request.content.title == "Build Failure")
        #expect(request.content.subtitle == "tako")
        #expect(request.content.body.contains("BUILD FAILED in 4.2s"))
        #expect(request.content.userInfo["trigger_pattern"] as? String == "BUILD FAILED")
    }

    @Test func testCooldownRateLimitingPerSurfaceAndTrigger() {
        let store = PassiveTriggerStore.shared
        store.resetForTesting()

        let surfaceId = UUID()
        let trigger = TerminalRegexTrigger(
            pattern: "warning:.*",
            action: .notify,
            onlyUnfocused: false
        )!

        var postedCount = 0
        Tako.onNotificationPosted = { _ in
            postedCount += 1
        }
        defer { Tako.onNotificationPosted = nil }

        let start = Date(timeIntervalSince1970: 1000)

        // First notification fires
        store.handleMatch(
            surfaceId: surfaceId,
            paneTitle: "cargo",
            pwd: nil,
            trigger: trigger,
            matchedText: "warning: unused variable",
            isUnfocused: true,
            now: start
        )
        #expect(postedCount == 1)

        // Within 3-second cooldown window: suppressed
        store.handleMatch(
            surfaceId: surfaceId,
            paneTitle: "cargo",
            pwd: nil,
            trigger: trigger,
            matchedText: "warning: unused mut",
            isUnfocused: true,
            now: start.addingTimeInterval(1.5)
        )
        #expect(postedCount == 1)

        // After cooldown window (3.5s later): fires
        store.handleMatch(
            surfaceId: surfaceId,
            paneTitle: "cargo",
            pwd: nil,
            trigger: trigger,
            matchedText: "warning: dead code",
            isUnfocused: true,
            now: start.addingTimeInterval(3.5)
        )
        #expect(postedCount == 2)
    }

    @Test func testControlCommandsTriggersDispatch() throws {
        let oldMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = oldMode }

        PassiveTriggerStore.shared.resetForTesting()

        // 1. Add dynamic trigger via ControlCommands
        let addRequest = ControlRequest(
            cmd: "triggers",
            args: [
                "subcommand": .string("add"),
                "pattern": .string(#"error: \[E[0-9]+\]"#),
                "action": .string("both"),
                "color": .string("red"),
                "style": .string("box"),
                "title": .string("Rust Error"),
                "only_unfocused": .bool(true)
            ],
            from: nil
        )
        let addResponse = ControlCommands.handle(addRequest, all: [])
        guard case .ok(let addedDict) = addResponse else {
            Issue.record("Expected .ok from triggers add")
            return
        }
        #expect(addedDict["pattern"]?.string == #"error: \[E[0-9]+\]"#)
        #expect(addedDict["action"]?.string == "both")
        #expect(addedDict["color"]?.string == "red")
        #expect(addedDict["style"]?.string == "box")
        #expect(addedDict["is_dynamic"]?.bool == true)
        guard let idStr = addedDict["id"]?.string, UUID(uuidString: idStr) != nil else {
            Issue.record("Invalid trigger ID returned")
            return
        }

        // 2. List triggers
        let listRequest = ControlRequest(cmd: "triggers", args: ["subcommand": .string("list")], from: nil)
        let listResponse = ControlCommands.handle(listRequest, all: [])
        guard case .ok(let listDict) = listResponse,
              let triggersArray = listDict["triggers"]?.array else {
            Issue.record("Expected triggers array in list response")
            return
        }
        #expect(triggersArray.count == 1)
        #expect(triggersArray[0].object?["id"]?.string == idStr)

        // 3. Remove trigger
        let rmRequest = ControlRequest(
            cmd: "triggers",
            args: ["subcommand": .string("remove"), "id": .string(idStr)],
            from: nil
        )
        let rmResponse = ControlCommands.handle(rmRequest, all: [])
        guard case .ok(let rmDict) = rmResponse else {
            Issue.record("Expected .ok from triggers remove")
            return
        }
        #expect(rmDict["removed"]?.string == idStr)

        // 4. Invalid pattern throws ControlError
        let badRequest = ControlRequest(
            cmd: "triggers",
            args: ["subcommand": .string("add"), "pattern": .string("[unclosed regex")],
            from: nil
        )
        #expect(throws: ControlError.self) {
            _ = try ControlCommands.triggersCommand(badRequest, all: [])
        }
    }
}
