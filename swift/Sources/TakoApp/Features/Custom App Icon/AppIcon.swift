import AppKit
import System

/// The icon style for the app.
///
/// Upstream offered eight artwork variants and a "colorized ghost" style
/// built from its own mark. Those are Tako's trademark rather than its
/// MIT-licensed code, so they are not redistributed here: what remains is
/// the app's own icon, whatever `.icns` the user points at, and
/// `.customStyle`, which draws Tako's own mark instead of upstream's ghost
/// (see `CustomStyleIcon.swift`).
enum AppIcon: Equatable, Codable, Sendable {
    case official
    /// Save full image data to avoid sandboxing issues
    case custom(_ iconFile: Data)
    /// Colours are hex strings, not `NSColor`, so this stays `Codable` for
    /// storage in defaults (see `DockTilePlugin.swift`): `bodyColor` tints
    /// the mark, `clawColor` its claws, `screenColors` are the plate's
    /// top-to-bottom gradient, and `frame` is the rim material.
    case customStyle(bodyColor: String, clawColor: String, screenColors: [String], frame: Tako.MacOSIconFrame)

#if !DOCK_TILE_PLUGIN
    init?(config: Tako.Config) {
        switch config.macosIcon {
        case .official:
            return nil
        case .custom:
            if let data = try? Data(contentsOf: URL(filePath: config.macosCustomIcon, relativeTo: nil)) {
                self = .custom(data)
            } else {
                return nil
            }
        case .customStyle:
            let ghost = config.macosIconGhostColor
            let body = ghost?.hexString ?? CustomStyleIcon.defaultBodyColor
            let claw = ghost.map { $0.lightened().hexString ?? CustomStyleIcon.defaultClawColor }
                ?? CustomStyleIcon.defaultClawColor
            let screens = config.macosIconScreenColor?.compactMap(\.hexString) ?? []
            let screenColors = screens.isEmpty ? CustomStyleIcon.defaultScreenColors : screens
            self = .customStyle(bodyColor: body, clawColor: claw, screenColors: screenColors,
                                frame: config.macosIconFrame)
        }
    }
#endif

    func image(in bundle: Bundle) -> NSImage? {
        switch self {
        case .official:
            return nil
        case let .custom(file):
            return NSImage(data: file)
        case let .customStyle(bodyColor, clawColor, screenColors, frame):
            return CustomStyleIcon.image(bodyColor: bodyColor, clawColor: clawColor,
                                         screenColors: screenColors, frame: frame)
        }
    }
}

#if !DOCK_TILE_PLUGIN
/// Making sure that `NSWorkspace.shared.setIcon` executes on only one thread at a time
actor AppIconUpdater {
    private let defaults: UserDefaults
    private let announce: @Sendable () -> Void
    private let bundlePath: String

    /// The defaults are the app's, the announcement goes to the Dock tile
    /// plugin in the Dock's process, and the icon is set on the app bundle.
    /// Tests substitute all three: the real ones reach beyond the test.
    init(
        defaults: UserDefaults = .tako,
        announce: @escaping @Sendable () -> Void = {
            DistributedNotificationCenter.default().postNotificationName(
                .takoIconDidChange, object: nil, userInfo: nil, deliverImmediately: true)
        },
        bundlePath: String = Bundle.main.bundlePath
    ) {
        self.defaults = defaults
        self.announce = announce
        self.bundlePath = bundlePath
    }

    func update(icon: AppIcon?) {
        defaults.appIcon = icon
        // Notify DockTilePlugin to update dock icon
        announce()

        NSWorkspace.shared.setIcon(icon?.image(in: .main), forFile: bundlePath)
        NSWorkspace.shared.noteFileSystemChanged(bundlePath)
    }
}
#endif
