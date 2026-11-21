// Tako — test notification delivery receipts
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import UserNotifications

enum SetupNotificationTestResult: Equatable, Sendable {
    case delivered
    case submitted
    case failed(String)
}

@MainActor
struct SetupNotificationTestSender {
    static let prefix = "tako-setup-test-"
    var add: (UNNotificationRequest) async throws -> Void
    var deliveredIDs: () async -> [String]
    var pendingIDs: () async -> [String]
    var removeDelivered: ([String]) -> Void
    var removePending: ([String]) -> Void
    var pause: () async -> Void = { try? await Task.sleep(for: .milliseconds(100)) }

    func send(_ request: UNNotificationRequest) async -> SetupNotificationTestResult {
        // Replace only this feature's synthetic tests, never task notifications.
        removeDelivered(await deliveredIDs().filter { $0.hasPrefix(Self.prefix) })
        removePending(await pendingIDs().filter { $0.hasPrefix(Self.prefix) })
        do { try await add(request) }
        catch { return .failed(error.localizedDescription) }
        for attempt in 0..<20 {
            if await deliveredIDs().contains(request.identifier) { return .delivered }
            if attempt < 19 { await pause() }
        }
        return .submitted
    }

    static func live(center: UNUserNotificationCenter) -> Self {
        Self(add: { try await center.add($0) }, deliveredIDs: {
            await withCheckedContinuation { continuation in
                center.getDeliveredNotifications { notifications in
                    continuation.resume(returning: notifications.map { $0.request.identifier })
                }
            }
        }, pendingIDs: {
            await withCheckedContinuation { continuation in
                center.getPendingNotificationRequests { requests in
                    continuation.resume(returning: requests.map(\.identifier))
                }
            }
        }, removeDelivered: { center.removeDeliveredNotifications(withIdentifiers: $0) },
           removePending: { center.removePendingNotificationRequests(withIdentifiers: $0) })
    }
}
