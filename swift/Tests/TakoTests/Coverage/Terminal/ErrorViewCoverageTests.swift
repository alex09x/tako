/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import SwiftUI
@testable import Tako

@MainActor
struct ErrorViewCoverageTests {
    @Test func bodyBuildsWithoutCrashing() {
        let view = ErrorView()
        // Force SwiftUI to build the view's body so every line in it runs.
        _ = view.body
    }

    @Test func previewsBuildsWithoutCrashing() {
        _ = ErrorView_Previews.previews
    }
}
