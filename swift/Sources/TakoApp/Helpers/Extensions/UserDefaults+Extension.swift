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

extension UserDefaults {
    public static var takoSuite: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["TAKO_USER_DEFAULTS_SUITE"]
        #else
        nil
        #endif
    }

    public static var tako: UserDefaults {
        takoSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
