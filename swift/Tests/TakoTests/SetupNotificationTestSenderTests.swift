// Tako — test notification receipt regressions
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Testing
import UserNotifications
@testable import Tako

@Suite @MainActor
struct SetupNotificationTestSenderTests {
    @Test func waitsForTheCurrentRequestRatherThanTreatingSubmissionAsDelivery() async {
        let request = SetupServices.testNotificationRequest()
        var added = false
        var polls = 0
        let sender = SetupNotificationTestSender(add: { _ in added = true }, deliveredIDs: {
            guard added else { return [] }
            polls += 1
            return polls >= 3 ? [request.identifier] : []
        }, pendingIDs: { [] }, removeDelivered: { _ in }, removePending: { _ in }, pause: {})
        #expect(await sender.send(request) == .delivered)
        #expect(polls == 3)
    }

    @Test func anOlderTestIsNotProofThatTheNewRequestWasDelivered() async {
        let request = SetupServices.testNotificationRequest()
        var reads = 0
        let sender = SetupNotificationTestSender(add: { _ in }, deliveredIDs: {
            reads += 1
            return ["tako-setup-test-older"]
        }, pendingIDs: { [] }, removeDelivered: { _ in }, removePending: { _ in }, pause: {})
        #expect(await sender.send(request) == .submitted)
        #expect(reads <= 25)
    }

    @Test func failedSubmissionCannotProduceADeliveryReceipt() async {
        let sender = SetupNotificationTestSender(add: { _ in
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture rejected"])
        }, deliveredIDs: { [] }, pendingIDs: { [] }, removeDelivered: { _ in }, removePending: { _ in }, pause: {})
        #expect(await sender.send(SetupServices.testNotificationRequest()) == .failed("fixture rejected"))
    }

    @Test func replacesOnlySyntheticSetupTestsAndPreservesTaskNotifications() async {
        var removedDelivered: [String] = []
        var removedPending: [String] = []
        let request = SetupServices.testNotificationRequest()
        var added = false
        let sender = SetupNotificationTestSender(add: { _ in added = true }, deliveredIDs: {
            added ? [request.identifier] : ["agent-completion", "tako-setup-test-old"]
        }, pendingIDs: { ["scheduled-task", "tako-setup-test-pending"] },
            removeDelivered: { removedDelivered = $0 }, removePending: { removedPending = $0 }, pause: {})
        #expect(await sender.send(request) == .delivered)
        #expect(removedDelivered == ["tako-setup-test-old"])
        #expect(removedPending == ["tako-setup-test-pending"])
    }
}
