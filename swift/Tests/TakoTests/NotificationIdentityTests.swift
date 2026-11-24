/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
@testable import Tako

/// Only Tako itself shows up in System Settings › Notifications; test, demo
/// and preview builds (other bundle ids, some new per run) stay out unless
/// asked in with TAKO_NOTIFICATIONS=1.
struct NotificationIdentityTests {
    @Test func onlyTakoItselfRegisters() {
        #expect(NotificationIdentity.registers(bundleID: "com.tako-core.terminal", environment: [:]))
        for id in ["com.tako-core.terminal.e2e", "com.tako-core.terminal.showcase-1791737541-6223", "com.tako-core.terminal.dev",
                   "com.tako-core.terminal.uitest", "com.tako-core.terminal.setup-live-preview", "com.apple.dt.xctest.tool"] {
            #expect(!NotificationIdentity.registers(bundleID: id, environment: [:]), "\(id) would leave a row behind")
        }
        #expect(!NotificationIdentity.registers(bundleID: nil, environment: ["TAKO_NOTIFICATIONS": "1"]))
        #expect(NotificationIdentity.registers(bundleID: "com.tako-core.terminal.dev", environment: ["TAKO_NOTIFICATIONS": "1"]))
        #expect(!NotificationIdentity.registers(bundleID: "com.tako-core.terminal.dev", environment: ["TAKO_NOTIFICATIONS": "yes"]))
    }
}
