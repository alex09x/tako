// Tako — permission request tracking regression
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import Tako

@Suite @MainActor
struct SetupPermissionRequestTrackingTests {
    @Test func missingInterfaceKeepsTheNetworkRequestAvailableForRetry() async throws {
        let domain = "SetupPermissionRequestTracking-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).config")
        let model = SetupModel(store: SetupProgressStore(defaults: defaults), configPath: config.path)
        var interfaceAvailable = false
        let service = TerminalPermissionService(authorization: { _ in .notDetermined },
            check: { $0 == .localNetwork ? .managedInSettings : nil },
            screenCaptureCheck: { false }, networkRequest: { interfaceAvailable })
        await model.requestPermission(.localNetwork, service: service)
        #expect(!model.permissionRequests.contains(.localNetwork))
        interfaceAvailable = true
        await model.requestPermission(.localNetwork, service: service)
        #expect(model.permissionRequests.contains(.localNetwork))
        #expect(service.permission(for: .localNetwork)?.status == .managedInSettings)
    }
}
