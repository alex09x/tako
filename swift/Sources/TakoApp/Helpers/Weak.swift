/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/// A wrapper that holds a weak reference to an object. This lets us create native containers
/// of weak references.
class Weak<T: AnyObject> {
    weak var value: T?

    init(_ value: T? = nil) {
        self.value = value
    }
}
