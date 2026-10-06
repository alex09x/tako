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

/// Errors related to user-defined redaction patterns.
public enum RedactionPatternError: Error, LocalizedError, Equatable {
    case unsafePattern(String)
    case patternTooComplex(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePattern(let reason):
            return "Unsafe redaction pattern: \(reason)"
        case .patternTooComplex(let reason):
            return "Redaction pattern too complex: \(reason)"
        }
    }
}
