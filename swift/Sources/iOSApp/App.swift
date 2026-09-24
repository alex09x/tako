import SwiftUI

// The iPhone app. Everything below the UI -- the engine and the renderer --
// is the same code the Mac runs; only this shell is different, because
// upstream's macOS app is AppKit from top to bottom and nothing in it
// transfers.

@main
struct TakoCoreApp: App {
    var body: some Scene {
        WindowGroup {
            SessionListScreen()
        }
    }
}
