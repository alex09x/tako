import AppKit

class DockTilePlugin: NSObject, NSDockTilePlugIn {
    // WARNING: An instance of this class is alive as long as Tako's icon is
    // in the doc (running or not!), so keep any state and processing to a
    // minimum to respect resource usage.

    private let pluginBundle = Bundle(for: DockTilePlugin.self)

    // Separate defaults based on debug vs release builds so we can test icons
    // without messing up releases.
    #if DEBUG
    private let takoUserDefaults = UserDefaults(suiteName: "com.tako-core.terminal.debug")
    #else
    private let takoUserDefaults = UserDefaults(suiteName: "com.tako-core.terminal")
    #endif

    private var iconChangeObserver: Any?

    /// Where the app announces an icon change: the distributed center, which
    /// reaches this plugin in the Dock's process. Tests pass a private one,
    /// so they announce nothing to other processes on the machine.
    private let iconChangeCenter: NotificationCenter

    override init() {
        iconChangeCenter = DistributedNotificationCenter.default()
        super.init()
    }

    init(iconChangeCenter: NotificationCenter) {
        self.iconChangeCenter = iconChangeCenter
        super.init()
    }

    /// The primary NSDockTilePlugin function.
    func setDockTile(_ dockTile: NSDockTile?) {
        // If no dock tile or no access to Tako defaults, we can't do anything.
        guard let dockTile, let takoUserDefaults else {
            iconChangeObserver = nil
            return
        }

        // Try to restore the previous icon on launch.
        iconDidChange(takoUserDefaults.appIcon, dockTile: dockTile)

        // Setup a new observer for when the icon changes so we can update. This message
        // is sent by the primary Tako app.
        iconChangeObserver = iconChangeCenter
            .publisher(for: .takoIconDidChange)
            .map { [weak self] _ in self?.takoUserDefaults?.appIcon }
            .receive(on: DispatchQueue.global())
            .sink { [weak self] newIcon in self?.iconDidChange(newIcon, dockTile: dockTile) }
    }

    private func iconDidChange(_ newIcon: AppIcon?, dockTile: NSDockTile) {
        guard let appIcon = newIcon?.image(in: pluginBundle) else {
            resetIcon(dockTile: dockTile)
            return
        }

        dockTile.setIcon(appIcon)
    }

    /// Reset the application icon and dock tile icon to the default.
    private func resetIcon(dockTile: NSDockTile) {
        let appIcon: NSImage?
        if #available(macOS 26.0, *) {
            // Reset to the bundle's own icon.
            appIcon = nil
        } else {
            // Use the bundled icon to keep the corner radius consistent with pre-Tahoe apps.
            appIcon = pluginBundle.image(forResource: "AppIconImage")!
        }
        dockTile.setIcon(appIcon)
    }
}

private extension NSDockTile {
    func setIcon(_ newIcon: NSImage?) {
        // Update the Dock tile on the main thread.
        DispatchQueue.main.async {
            guard let newIcon else {
                self.contentView = nil
                self.display()
                return
            }
            let iconView = NSImageView(frame: CGRect(origin: .zero, size: self.size))
            iconView.wantsLayer = true
            iconView.image = newIcon
            self.contentView = iconView
            self.display()
        }
    }
}

// This is required because of the DispatchQueue call above. This doesn't
// feel right but I don't know a better way to solve this.
extension NSDockTile: @unchecked @retroactive Sendable {}
