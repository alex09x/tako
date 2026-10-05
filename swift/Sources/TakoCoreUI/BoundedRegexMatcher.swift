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

/// Executes regular expression matches with an enforced per-call deadline/budget (E7).
/// Prevents any individual regex match from starving the UI or terminal rendering thread.
public enum BoundedRegexMatcher {
    private static let queue = DispatchQueue(
        label: "codes.prod.tako.regex-matcher",
        qos: .userInteractive,
        attributes: .concurrent
    )

    private final class MatchBox: @unchecked Sendable {
        var matches: [NSTextCheckingResult] = []
        var reachedLimit = false
    }

    /// Enumerates matches for `regex` in `string` up to `maxMatches`, with a strict per-call execution timeout.
    /// Returns `true` if matching completed within the timeout, or `false` if it timed out.
    @discardableResult
    public static func enumerateMatches(
        regex: NSRegularExpression,
        in string: String,
        range: NSRange,
        timeout: DispatchTimeInterval = .milliseconds(2),
        maxMatches: Int = 16,
        using block: (NSTextCheckingResult) -> Void
    ) -> Bool {
        let box = MatchBox()
        let group = DispatchGroup()
        let item = DispatchWorkItem {
            regex.enumerateMatches(in: string, options: [], range: range) { result, _, stop in
                guard let res = result else { return }
                box.matches.append(res)
                if box.matches.count >= maxMatches {
                    box.reachedLimit = true
                    stop.pointee = true
                }
            }
        }

        queue.async(group: group, execute: item)
        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            item.cancel()
            return false
        }

        for match in box.matches {
            block(match)
        }
        return true
    }
}
