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

/// Access control gate for the companion app (F5 / G5).
/// Secure-input sessions are strictly excluded from companion access (viewing, typing, or inspection).
public enum CompanionAccessGate {
    /// Returns true if the companion app is allowed to access the given surface.
    public static func isAccessAllowed(for surface: AnyObject) -> Bool {
        return !SecureInput.shared.isSecure(for: surface)
    }

    /// Checks if companion app access is allowed for this surface, throwing an error if excluded.
    public static func checkAccess(for surface: AnyObject) throws {
        guard isAccessAllowed(for: surface) else {
            throw ControlError(.disabled, "secure-input panes cannot be accessed by the companion app")
        }
    }
}
