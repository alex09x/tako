import Foundation
import Cocoa
import SwiftUI
import TakoKit

/// This initializes a clipboard confirmation warning window. The window itself
/// WILL NOT show automatically and the caller must show the window via
/// showWindow, beginSheet, etc.
class ClipboardConfirmationController: NSWindowController {
    override var windowNibName: NSNib.Name? { "ClipboardConfirmation" }

    let surface: tako_surface_t?
    let surfaceView: Tako.SurfaceView?
    let contents: String
    let request: Tako.ClipboardRequest
    let state: UnsafeMutableRawPointer?
    weak private var delegate: ClipboardConfirmationViewDelegate?

    init(surface: tako_surface_t, contents: String, request: Tako.ClipboardRequest, state: UnsafeMutableRawPointer?, delegate: ClipboardConfirmationViewDelegate) {
        self.surface = surface
        self.surfaceView = nil
        self.contents = contents
        self.request = request
        self.state = state
        self.delegate = delegate
        super.init(window: nil)
    }

    init(surfaceView: Tako.SurfaceView, contents: String, request: Tako.ClipboardRequest, state: UnsafeMutableRawPointer? = nil, delegate: ClipboardConfirmationViewDelegate) {
        self.surface = surfaceView.surface
        self.surfaceView = surfaceView
        self.contents = contents
        self.request = request
        self.state = state
        self.delegate = delegate
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    override func loadWindow() {
        if let nibName = windowNibName,
           Bundle.main.url(forResource: nibName, withExtension: "nib") != nil,
           let nib = NSNib(nibNamed: nibName, bundle: Bundle.main) {
            var topLevelObjects: NSArray?
            if nib.instantiate(withOwner: self, topLevelObjects: &topLevelObjects) {
                if let window = topLevelObjects?.first(where: { $0 is NSWindow }) as? NSWindow {
                    self.window = window
                    return
                }
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window = window
    }

    // MARK: - NSWindowController

    override func windowDidLoad() {
        guard let window = window else { return }

        switch request {
        case .paste:
            window.title = "Warning: Potentially Unsafe Paste"
        case .osc_52_read, .osc_52_write:
            window.title = "Authorize Clipboard Access"
        }

        window.contentView = NSHostingView(rootView: ClipboardConfirmationView(
            contents: contents,
            request: request,
            delegate: delegate
        ))
    }
}
