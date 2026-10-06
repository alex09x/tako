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

extension Duration {
    var timeInterval: TimeInterval {
        return TimeInterval(self.components.seconds) +
               TimeInterval(self.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
