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

/// Sessions the person was already asked about at launch and did not
/// restore. The same session is not offered again on the next launch;
/// Session Recovery from the menu always lists everything. A new generation
/// of a session is a new question.
struct SessionRecoveryDeferral {
    static let defaultsKey = "SessionRecoveryDeferred"

    var defaults: UserDefaults = .tako

    static func key(for candidate: SessionRecoveryInventory.Candidate) -> String {
        "\(candidate.id.uuidString):\(candidate.runtimeID):\(candidate.observedGeneration ?? "")"
    }

    var deferred: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// The candidates nobody has been asked about yet.
    func unasked(_ candidates: [SessionRecoveryInventory.Candidate]) -> [SessionRecoveryInventory.Candidate] {
        let known = deferred
        return candidates.filter { !known.contains(Self.key(for: $0)) }
    }

    /// Remembers what was offered; sessions that are gone are forgotten, so
    /// the list never outgrows what is actually running.
    func remember(offered: [SessionRecoveryInventory.Candidate]) {
        defaults.set(offered.map(Self.key(for:)).sorted(), forKey: Self.defaultsKey)
    }
}
