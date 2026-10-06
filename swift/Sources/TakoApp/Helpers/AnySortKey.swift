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

/// Type-erased wrapper for any Comparable type to use as a sort key.
struct AnySortKey: Comparable {
    private let value: Any
    private let comparator: (Any, Any) -> ComparisonResult

    init<T: Comparable>(_ value: T) {
        self.value = value
        self.comparator = { lhs, rhs in
            guard let l = lhs as? T, let r = rhs as? T else { return .orderedSame }
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        }
    }

    static func < (lhs: AnySortKey, rhs: AnySortKey) -> Bool {
        lhs.comparator(lhs.value, rhs.value) == .orderedAscending
    }

    static func == (lhs: AnySortKey, rhs: AnySortKey) -> Bool {
        lhs.comparator(lhs.value, rhs.value) == .orderedSame
    }
}
