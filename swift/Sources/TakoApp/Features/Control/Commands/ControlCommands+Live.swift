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
import Foundation

/// A quiet program's live state as `takoctl` reads it (Sessions UI 5a): what
/// the tab, the sidebar and Overview show, so a terminal sees it too.
extension ControlCommands {
    /// `{"program", "detail", "flowing", "linesPerSecond", "quietSeconds",
    /// "rate", "quiet", "summary"}` -- `summary` is the one line a terminal
    /// prints: "ssh alex@ram11 · 38/s", "tail · quiet 4m".
    static func liveJSON(_ live: Tako.LiveActivity) -> JSON {
        .object([
            "program": live.program.map(JSON.string) ?? .null,
            "detail": live.detail.map(JSON.string) ?? .null,
            "flowing": .bool(live.isFlowing),
            "linesPerSecond": .number(Double(live.linesPerSecond)),
            "quietSeconds": .number(live.quietSeconds),
            "rate": live.rateLabel.map(JSON.string) ?? .null,
            "quiet": live.isFlowing ? .null : .string(live.quietLabel),
            "summary": .string(liveSummary(live)),
        ])
    }

    /// The program and where it runs, then the rate while dense or how long
    /// it has been quiet: the tab's meta and the sidebar's second line in one.
    static func liveSummary(_ live: Tako.LiveActivity) -> String {
        let name = [live.program, live.detail].compactMap { $0 }.joined(separator: " ")
        let state = live.rateLabel ?? (live.isFlowing ? nil : live.quietLabel)
        return [name.isEmpty ? nil : name, state].compactMap { $0 }.joined(separator: " · ")
    }

    /// The code a failure shows as "exit N", when the command reported one.
    static func exitCode(of crab: Tako.CrabTracker) -> Int32? {
        if case .failed(let code?) = crab.state { return code }
        return nil
    }

    /// A tab's live program: of several panes, one whose output arrives.
    static func liveActivity(in window: NSWindow) -> Tako.LiveActivity? {
        let lives = Tako.surfaces(in: window).compactMap { $0.crab.live }
        return lives.first(where: \.isFlowing) ?? lives.first
    }

    /// Adds what 5a shows to a pane's or a tab's facts.
    static func addLive(_ live: Tako.LiveActivity?, exitCode: Int32?, to node: inout [String: JSON]) {
        if let live { node["live"] = liveJSON(live) }
        if let exitCode { node["exitCode"] = .number(Double(exitCode)) }
    }
}
