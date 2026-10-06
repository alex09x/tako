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

extension FileHandle: @retroactive TextOutputStream {
    /// Write a string to a filehandle.
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}
