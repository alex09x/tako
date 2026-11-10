/*
 * tako — A deferred recovery offer stays quiet while manual recovery remains available
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

/// Continues the missing-layout fixture after its first recovery question.
/// The enclosing isolated persistence runner owns every session in this profile.
func revisitDeferredRecoveryThroughMenu(_ d: Driver, config: String, shell: pid_t) throws {
    try d.clickButton(titled: "Later")
    guard d.wait(for: { !d.hasText(containing: "Session Recovery") }, timeout: 5),
          let current = try d.focusedPaneId() else {
        throw Failure("Later did not leave the startup terminal usable")
    }
    guard kill(shell, 0) == 0 else { throw Failure("Later stopped the unclaimed shell") }

    try d.quitNormally()
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { (try? d.focusedPaneId())?.lowercased() == current.lowercased() }, timeout: 15) else {
        throw Failure("the ordinary startup terminal was not restored before checking the deferred offer")
    }
    // Observe the real startup scan, not only a defaults helper. The fixture
    // has one runtime and its own session home, so no real sessions are scanned.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if d.hasText(containing: "Session Recovery") {
            throw Failure("the same deferred session was offered again after a real relaunch")
        }
        usleep(100_000)
    }
    guard kill(shell, 0) == 0 else { throw Failure("relaunch stopped the deferred shell") }

    guard d.pressMenu(title: "Recover Sessions…") || d.pressMenuItem(titledPrefix: "Recover Sessions") else {
        throw Failure("the manual Recover Sessions command was unavailable")
    }
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 15) else {
        throw Failure("manual recovery did not reopen the deferred offer")
    }
    print("[recovery deferral] Manual offer: \(d.staticTexts().suffix(10))")
    guard kill(shell, 0) == 0 else { throw Failure("opening manual recovery stopped the deferred shell") }
    print("[recovery deferral] Later persisted across relaunch; manual recovery reopened the live session")
}
