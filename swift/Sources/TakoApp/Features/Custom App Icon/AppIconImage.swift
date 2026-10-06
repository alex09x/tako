import SwiftUI

extension View {
    /// Returns the application icon to use for views.
    func appIconImage() -> Image {
        #if os(macOS)
        appIconImage(running: NSRunningApplication.current.icon, application: NSApp.applicationIconImage)
        #else
        Image("AppIconImage")
        #endif
    }

    #if os(macOS)
    /// The running application's icon first: it is the one that carries the
    /// icon tinting of macOS Tahoe. Then the application's icon image, then
    /// the static asset.
    func appIconImage(running: NSImage?, application: NSImage?) -> Image {
        if let icon = running ?? application {
            return Image(nsImage: icon)
        }
        return Image("AppIconImage")
    }
    #endif
}
