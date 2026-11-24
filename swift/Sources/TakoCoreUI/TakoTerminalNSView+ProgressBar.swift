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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    /// Records the pane's OSC 9;4 progress. The tab, the dock icon and the
    /// window show it; nothing is drawn over the terminal itself.
    public func updateProgressBar(state: ProgressState, progress: Int?) {
        activeProgressState = state
        activeProgressValue = progress
    }
}
#endif
