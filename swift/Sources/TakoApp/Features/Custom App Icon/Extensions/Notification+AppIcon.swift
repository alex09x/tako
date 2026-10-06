import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// Tako -> DockTilePlugin
    static let takoIconDidChange = Notification.Name("com.tako-core.terminal.iconDidChange")
}
