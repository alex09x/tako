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

/// When a launch checks for updates on its own. The check ends in a dialog
/// whenever a release is newer, which a self-test's typed keys would land in,
/// and which an unversioned local build would show on every start.
struct AppUpdaterLaunchTests {
    @Test func aReleasedBuildChecks() {
        #expect(AppUpdater.checksAtLaunch(arguments: ["Tako"], version: "0.1.2", enabled: true))
    }

    @Test func autoUpdateOffDoesNot() {
        #expect(!AppUpdater.checksAtLaunch(arguments: ["Tako"], version: "0.1.2", enabled: false))
    }

    @Test func aSelfTestDoesNot() {
        for flag in ["--selftest-keys", "--selftest-input", "--selftest-scroll", "--selftest-frame"] {
            #expect(!AppUpdater.checksAtLaunch(arguments: ["Tako", flag], version: "0.1.2", enabled: true), "\(flag)")
        }
    }

    @Test func anUnversionedLocalBuildDoesNot() {
        #expect(!AppUpdater.checksAtLaunch(arguments: ["Tako"], version: "0.0.0", enabled: true))
        #expect(!AppUpdater.checksAtLaunch(arguments: ["Tako"], version: nil, enabled: true))
        #expect(!AppUpdater.checksAtLaunch(arguments: ["Tako"], version: "", enabled: true))
    }

    @Test func theConfigKeyTurnsItOff() throws {
        #expect(try TemporaryConfig("auto-update = off").autoUpdateEnabled == false)
        #expect(try TemporaryConfig("auto-update = OFF").autoUpdateEnabled == false)
        #expect(try TemporaryConfig("auto-update = check").autoUpdateEnabled == true)
        #expect(try TemporaryConfig("").autoUpdateEnabled == true)
    }
}
