/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@Suite @MainActor
struct SetupNotificationFeedbackTests {
    @Test func checkAgainSendsAnExplicitTestWhenAllowed() async throws {
        try await fixture(.init(access: .allowed, alerts: true)) { model, calls in
            await model.checkNotificationsAndSendTest()
            #expect(calls.sent == 1)
            #expect(calls.permissionRequests == 0)
            #expect(model.message == "Test notification delivered to Notification Center.")
            #expect(!model.isBusy)
        }
    }

    @Test func deniedCheckShowsFeedbackWithoutRequestingAccess() async throws {
        try await fixture(.init(access: .denied)) { model, calls in
            await model.checkNotificationsAndSendTest()
            #expect(calls.sent == 0)
            #expect(calls.permissionRequests == 0)
            #expect(model.message?.contains("disabled") == true)
        }
    }

    @Test func sendingFailureIsReportedInsteadOfSuccess() async throws {
        try await fixture(.init(access: .allowed, alerts: true), error: "fixture rejected") { model, calls in
            await model.checkNotificationsAndSendTest()
            #expect(calls.sent == 1)
            #expect(model.message?.contains("fixture rejected") == true)
            #expect(model.message?.contains("Test notification sent.") == false)
        }
    }

    @Test func testNotificationCanBePresentedWhileSetupIsInFront() {
        let request = SetupServices.testNotificationRequest()
        #expect(request.content.title == "Tako test notification")
        #expect(Tako.shouldPresent(userInfo: request.content.userInfo, surfaceLookedAt: true))
    }

    @Test func acceptedRequestIsNotReportedAsDelivered() async throws {
        try await fixture(.init(access: .allowed, alerts: true), result: .submitted) { model, _ in
            await model.checkNotificationsAndSendTest()
            #expect(model.message?.contains("delivery is not confirmed") == true)
            #expect(model.message?.contains("delivered to") == false)
        }
    }

    @Test func deliveredTestStillReportsDisabledBanners() async throws {
        try await fixture(.init(access: .allowed, alerts: false)) { model, _ in
            await model.checkNotificationsAndSendTest()
            #expect(model.message?.contains("Banners are off") == true)
        }
    }

    private final class Calls {
        var sent = 0
        var permissionRequests = 0
    }

    private func fixture(_ status: SetupNotificationStatus, error: String? = nil,
                         result: SetupNotificationTestResult = .delivered,
                         body: (SetupModel, Calls) async throws -> Void) async throws {
        let name = "SetupNotificationFeedbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let calls = Calls()
        var services = SetupServices(checkCLI: { .init(installed: false, detail: "Unused") },
            installCLI: { .init(installed: false, detail: "Unused") }, checkAgents: { [] }, connectAgents: { _ in [] },
            checkNotifications: { status },
            enableNotifications: { calls.permissionRequests += 1; return status }, openNotificationSettings: {})
        services.sendTestNotification = { calls.sent += 1; return error.map { .failed($0) } ?? result }
        let model = SetupModel(store: SetupProgressStore(defaults: defaults), services: services,
                               configPath: "/nonexistent/setup-notification-feedback/config")
        try await body(model, calls)
    }
}
