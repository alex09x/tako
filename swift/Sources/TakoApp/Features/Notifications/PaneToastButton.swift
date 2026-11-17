/*
 * tako — Native click target for the toast over the window's titlebar band
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// The window forwards titlebar-band presses to native content views. A
/// SwiftUI Button needs NSWindow's gesture dispatch, which that path bypasses.
/// This transparent native button tracks the press normally over the unchanged
/// SwiftUI label, including when the toast overlaps that band.
struct PaneToastButton: NSViewRepresentable {
    let action: () -> Void
    let label: String
    let identifier: String

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.press))
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.isTransparent = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}
