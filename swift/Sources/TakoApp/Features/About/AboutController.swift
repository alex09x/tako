import Foundation
import Cocoa
import SwiftUI

class AboutController: NSWindowController, NSWindowDelegate {
    static let shared: AboutController = AboutController()

    private let viewModel = AboutViewModel()
    override var windowNibName: NSNib.Name? { "About" }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.center()
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: AboutView().environmentObject(viewModel))
        window.titlebarAppearsTransparent = true
    }

    // MARK: - Functions

    func show() {
        if let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
            AboutNotice.show(in: window)
            return
        }
        if window == nil { _ = self.window }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.startCyclingIcons()
    }

    func hide() {
        window?.close()
    }

    // MARK: - First Responder

    @IBAction func close(_ sender: Any) {
        self.window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        self.window?.performClose(sender)
    }

    // This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stopCyclingIcons()
    }
}
