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
import Testing
@testable import Tako

/// A toast is one row high, however tall the window it lies over: the stack
/// is an overlay across the whole terminal, which offers it the full height.
/// A toast once stretched to it and slid in as a full-height panel.
@Suite @MainActor
struct PaneToastRowTests {
    @Test func aToastIsOneRowHighInATallWindow() {
        for message in ["", "The command exited with an error"] {
            let toast = PaneToast(id: UUID(), surfaceID: UUID(), state: .done, headline: "muse — done",
                                  message: message, place: "in the background")
            let host = NSHostingController(rootView: PaneToastRow(toast: toast, open: {}).frame(width: 300))
            let height = host.sizeThatFits(in: CGSize(width: 300, height: 800)).height
            #expect(height > 20 && height < 120, "a toast \(message.isEmpty ? "without" : "with") a message is \(height) pt high in an 800 pt window")
        }
    }
}
