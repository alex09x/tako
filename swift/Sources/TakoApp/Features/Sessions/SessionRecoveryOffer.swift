/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import TakoCoreUI

/// The question Session Recovery asks about sessions found outside the
/// restored windows, and what counts as having asked it.
@MainActor
enum SessionRecoveryOffer {
    enum Outcome: Equatable {
        /// Everything found was already offered at an earlier launch.
        case nothingNew
        /// The question could not be drawn: nothing is recorded as asked.
        case notShown
        /// The question was shown and nothing is to be restored now.
        case declined
        case restore(verified: [SessionRecoveryInventory.Candidate], adoptable: [SessionRecoveryInventory.Candidate])
    }

    /// At launch only something not offered before is a reason to ask; the
    /// menu command (`showEmpty`) always asks.
    static func isDue(_ discovered: [SessionRecoveryInventory.Candidate], showEmpty: Bool,
                      deferral: SessionRecoveryDeferral) -> Bool {
        showEmpty || !deferral.unasked(discovered).isEmpty
    }

    /// Asks in `window`. A launch offer is recorded as made only after its
    /// question was actually answered -- "Later" and "OK" included -- never
    /// for a question that could not be shown, for the notice that
    /// persistence is disabled, or for the menu command.
    static func ask(_ discovered: [SessionRecoveryInventory.Candidate], showEmpty: Bool, persistenceEnabled: Bool,
                    deferral: SessionRecoveryDeferral, window: NSWindow, theme: TerminalTheme?) async -> Outcome {
        guard isDue(discovered, showEmpty: showEmpty, deferral: deferral) else { return .nothingNew }
        guard persistenceEnabled else {
            let shown = await TerminalDialogView.choose(in: window, title: "Session Recovery",
                lines: TUIText.plain("Session persistence is disabled. Enable it before reconnecting saved sessions.", width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: theme)
            return shown == nil ? .notShown : .declined
        }
        let verified = discovered.filter { $0.identity == .verified && $0.record != nil }
        let adoptable = discovered.filter {
            $0.identity == .unverified &&
                ($0.observedGeneration.map(SessionRecoveryInventory.isGeneration) ?? false)
        }
        let uncertain = discovered.count - verified.count - adoptable.count
        var message = "Tako found \(verified.count) sessions matching saved records outside the restored windows."
        if !adoptable.isEmpty {
            message += " \(adoptable.count) sessions have no matching record and require individual confirmation."
        }
        if uncertain > 0 {
            message += " \(uncertain) more could not be verified; they will be kept untouched."
        }
        let restorable = !verified.isEmpty || !adoptable.isEmpty
        let answer: Int?
        if restorable {
            answer = await TerminalDialogView.choose(in: window, title: "Session Recovery",
                lines: TUIText.plain(message + " Review and restore these sessions?", width: 56),
                choices: [.init(title: "Later", kind: .normal), .init(title: "Restore", kind: .primary)],
                selected: 0, cancelIndex: 0, theme: theme)
        } else {
            answer = await TerminalDialogView.choose(in: window, title: "Session Recovery",
                lines: TUIText.plain(message, width: 56), choices: [.init(title: "OK", kind: .normal)],
                cancelIndex: 0, theme: theme)
        }
        guard let answer else { return .notShown }
        if !showEmpty { deferral.remember(offered: discovered) }
        return restorable && answer == 1 ? .restore(verified: verified, adoptable: adoptable) : .declined
    }
}
