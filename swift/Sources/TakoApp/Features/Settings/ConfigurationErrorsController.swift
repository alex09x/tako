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
                self.window?.performClose(nil)
            }
        }
    }

    override func showWindow(_ sender: Any?) {
        if let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
            ConfigurationErrorsNotice.show(errors: errors, in: window)
            return
        }
        super.showWindow(sender)
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
