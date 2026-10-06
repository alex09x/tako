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
import Cocoa
import SwiftUI
import Combine

class ConfigurationErrorsController: NSWindowController, NSWindowDelegate, ConfigurationErrorsViewModel {
    /// Singleton for the errors view.
    static let sharedInstance = ConfigurationErrorsController()

    override var windowNibName: NSNib.Name? { "ConfigurationErrors" }

    /// The data model for this view. Update this directly and the associated view will be updated, too.
    @Published var errors: [String] = [] {
        didSet {
            if errors.count == 0 {
                ConfigurationErrorsNotice.dismiss()
                self.close()
                self.window?.orderOut(nil)
            }
        }
    }

    override func showWindow(_ sender: Any?) {
        // Enforce in-terminal TUI presentation. Never display a native Cocoa window.
        self.window?.orderOut(nil)
        ConfigurationErrorsNotice.show(errors: errors)
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.center()
        window.level = .popUpMenu
        window.contentView = NSHostingView(rootView: ConfigurationErrorsView(model: self))
        window.titlebarAppearsTransparent = true
    }
}

