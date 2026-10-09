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

    @Test func noUpdateFlagDoesNot() {
        for flag in ["--no-update", "--no-update-check", "--disable-update-check"] {
            #expect(!AppUpdater.checksAtLaunch(arguments: ["Tako", flag], version: "0.1.2", enabled: true, environment: [:]), "\(flag)")
        }
    }

    @Test func noUpdateEnvDoesNot() {
        for envKey in ["TAKO_NO_UPDATE", "TAKO_NO_UPDATE_CHECK", "TAKO_DISABLE_UPDATE_CHECK"] {
            #expect(!AppUpdater.checksAtLaunch(arguments: ["Tako"], version: "0.1.2", enabled: true, environment: [envKey: "1"]), "\(envKey)")
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

    @Test @MainActor func sessionSuppressionForSilentChecks() {
        let updater = AppUpdater.shared
        updater.resetSessionNotifiedVersions()

        // First check in session presents dialog
        #expect(updater.shouldPresentUpdate(version: "v0.1.8", silent: true) == true)
        #expect(updater.notifiedVersionsInSession.contains("v0.1.8"))

        // Subsequent silent background check suppresses repeat presentation
        #expect(updater.shouldPresentUpdate(version: "v0.1.8", silent: true) == false)

        // Manual user check (silent = false) always presents
        #expect(updater.shouldPresentUpdate(version: "v0.1.8", silent: false) == true)

        // Another silent check remains suppressed for that version
        #expect(updater.shouldPresentUpdate(version: "v0.1.8", silent: true) == false)

        // A newer version released during session presents
        #expect(updater.shouldPresentUpdate(version: "v0.1.9", silent: true) == true)
        #expect(updater.shouldPresentUpdate(version: "v0.1.9", silent: true) == false)

        // On next launch (simulated restart), previously seen version prompts again
        updater.resetSessionNotifiedVersions()
        #expect(updater.shouldPresentUpdate(version: "v0.1.8", silent: true) == true)
    }

    @Test @MainActor func periodicTimerLifecycle() {
        let updater = AppUpdater.shared
        updater.stopPeriodicChecks()
        #expect(updater.isPeriodicCheckActive == false)

        updater.startPeriodicChecks(interval: 3600)
        #expect(updater.isPeriodicCheckActive == true)

        // Re-starting with same interval keeps it active
        updater.startPeriodicChecks(interval: 3600)
        #expect(updater.isPeriodicCheckActive == true)

        updater.stopPeriodicChecks()
        #expect(updater.isPeriodicCheckActive == false)
    }
}
