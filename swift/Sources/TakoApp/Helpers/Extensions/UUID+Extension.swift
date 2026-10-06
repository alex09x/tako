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

extension UUID {
    /// Initialize a UUID from a CFUUID.
    init?(_ cfuuid: CFUUID) {
        guard let uuidString = CFUUIDCreateString(nil, cfuuid) as String? else { return nil }
        self.init(uuidString: uuidString)
    }
}
