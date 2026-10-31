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
import SwiftUI
import TakoKit

extension View {
    /// A click selects on release; an actual drag remains owned by SwiftUI's drag session.
    func onPress(perform action: @escaping () -> Void) -> some View {
        onTapGesture(perform: action)
    }
}
