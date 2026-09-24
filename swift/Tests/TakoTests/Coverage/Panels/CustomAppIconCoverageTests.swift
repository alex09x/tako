import AppKit
import Foundation
import Testing
@testable import Tako

// Coverage for swift/Sources/TakoApp/Features/Custom App Icon: AppIcon's
// config-driven init and image rendering, AppIconUpdater's persistence +
// notification side effects, DockTilePlugin's dock-tile rendering, and the
// small Notification.Name / UserDefaults.appIcon extensions they lean on.

private func makePNGData(color: NSColor = .systemBlue, size: NSSize = NSSize(width: 8, height: 8)) -> Data {
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not build test PNG data")
    }
    return png
}

@Suite
struct AppIconCoverageTests {
    @Test func officialConfigYieldsNilIcon() throws {
        let config = try TemporaryConfig("macos-icon = official")
        #expect(AppIcon(config: config) == nil)
    }

    /// The shim's `macosCustomIcon` always resolves to an empty path (see
    /// Tako+Config.swift), so `Data(contentsOf:)` always fails for the
    /// `.custom` case in this test harness -- the success assignment
    /// (`self = .custom(data)`) inside `init?(config:)` is therefore
    /// unreachable via any config text; only the failure branch is
    /// reachable, which this exercises.
    @Test func customConfigWithUnresolvablePathYieldsNilIcon() throws {
        let config = try TemporaryConfig("macos-icon = custom")
        #expect(AppIcon(config: config) == nil)
    }

    @Test func officialImageIsNil() {
        #expect(AppIcon.official.image(in: .main) == nil)
    }

    @Test func customImageDecodesTheStoredData() {
        let data = makePNGData()
        let icon = AppIcon.custom(data)
        let image = icon.image(in: .main)
        #expect(image != nil)
        #expect(image?.size.width ?? 0 > 0)
    }

    @Test func customImageWithGarbageDataFailsToDecode() {
        let icon = AppIcon.custom(Data([0x00, 0x01, 0x02]))
        #expect(icon.image(in: .main) == nil)
    }

    @Test func equatableDistinguishesCasesAndPayloads() {
        #expect(AppIcon.official == AppIcon.official)
        #expect(AppIcon.official != AppIcon.custom(Data()))
        #expect(AppIcon.custom(Data([1])) != AppIcon.custom(Data([2])))
    }

    @Test func codableRoundTripsBothCases() throws {
        for icon: AppIcon in [.official, .custom(makePNGData())] {
            let data = try JSONEncoder().encode(icon)
            let decoded = try JSONDecoder().decode(AppIcon.self, from: data)
            #expect(decoded == icon)
        }
    }
}

@Suite
struct UserDefaultsAppIconCoverageTests {
    @Test func roundTripsThroughTheStandardDefaults() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "CustomTakoIcon2")
        defer {
            if let previous {
                defaults.set(previous, forKey: "CustomTakoIcon2")
            } else {
                defaults.removeObject(forKey: "CustomTakoIcon2")
            }
        }

        defaults.set("stale-pre-dock-tile-plugin-value", forKey: "CustomTakoIcon")
        defaults.appIcon = .custom(makePNGData())
        // The *getter* always clears the legacy key as a side effect (via
        // its own `defer`), whether or not it finds anything under the new
        // key -- so the read below must happen before the legacy-key check.
        #expect(defaults.appIcon == .custom(makePNGData()))
        #expect(defaults.string(forKey: "CustomTakoIcon") == nil)

        defaults.appIcon = .official
        #expect(defaults.appIcon == .official)
    }

    @Test func missingKeyReadsAsNil() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "CustomTakoIcon2")
        defer {
            if let previous {
                defaults.set(previous, forKey: "CustomTakoIcon2")
            } else {
                defaults.removeObject(forKey: "CustomTakoIcon2")
            }
        }
        defaults.removeObject(forKey: "CustomTakoIcon2")
        #expect(defaults.appIcon == nil)
    }
}

@Suite
/// Counts announcements from the updater's actor.
private final class Announcements: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

@MainActor
struct AppIconUpdaterCoverageTests {
    @Test func updatePersistsTheIconAndAnnouncesTheChange() async throws {
        let suiteName = "tako-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let announced = Announcements()
        let updater = AppIconUpdater(
            defaults: defaults, announce: { announced.record() }, bundlePath: bundle.path)
        await updater.update(icon: .official)

        #expect(defaults.appIcon == .official)
        #expect(announced.count == 1)
    }
}

@Suite
@MainActor
struct DockTilePluginCoverageTests {
    private static let suiteName = "com.tako-core.terminal.debug"

    private func withDebugSuite(_ body: (UserDefaults) async -> Void) async {
        guard let suite = UserDefaults(suiteName: Self.suiteName) else {
            Issue.record("could not open the dock tile plugin's debug UserDefaults suite")
            return
        }
        let previous = suite.data(forKey: "CustomTakoIcon2")
        defer {
            if let previous {
                suite.set(previous, forKey: "CustomTakoIcon2")
            } else {
                suite.removeObject(forKey: "CustomTakoIcon2")
            }
        }
        await body(suite)
    }

    @Test func setDockTileWithNoTileClearsTheObserverAndReturns() {
        let plugin = DockTilePlugin(iconChangeCenter: NotificationCenter())
        // Must not crash, and is the only way to exercise the guard-failure
        // branch that tears down any existing observer.
        plugin.setDockTile(nil)
    }

    /// `resetIcon`'s pre-Tahoe branch force-unwraps `pluginBundle.image(forResource:
    /// "AppIconImage")`, which is only guaranteed to resolve in the real app
    /// bundle -- this SPM test target ships no asset catalog, so running
    /// that branch here would crash the whole test process. Only exercise
    /// it on macOS 26+, where the guarded branch returns nil instead and
    /// the resource lookup never happens.
    @Test func setDockTileWithNoStoredIconResetsOnModernMacOS() async {
        guard #available(macOS 26.0, *) else { return }
        await withDebugSuite { suite in
            suite.removeObject(forKey: "CustomTakoIcon2")
            let plugin = DockTilePlugin(iconChangeCenter: NotificationCenter())
            let dockTile = NSApplication.shared.dockTile
            // Something to reset from: with no stored icon the tile goes
            // back to the bundle's own icon, i.e. no content view.
            dockTile.contentView = NSView()
            plugin.setDockTile(dockTile)
            #expect(await waitUntilPanelAsync(timeout: 3) { dockTile.contentView == nil })
        }
    }

    @Test func setDockTileWithAStoredCustomIconRendersIt() async {
        await withDebugSuite { suite in
            suite.appIcon = .custom(makePNGData(color: .systemRed))
            let plugin = DockTilePlugin(iconChangeCenter: NotificationCenter())
            let dockTile = NSApplication.shared.dockTile
            plugin.setDockTile(dockTile)
            #expect(await waitUntilPanelAsync(timeout: 3) { (dockTile.contentView as? NSImageView)?.image != nil })
        }
    }

    @Test func anIconChangeNotificationUpdatesAnAlreadyInstalledTile() async {
        let center = NotificationCenter()
        await withDebugSuite { suite in
            // Start from a real stored icon (never nil) so the initial
            // `setDockTile` call only ever exercises the safe, always-real
            // `iconDidChange` success branch -- never `resetIcon`.
            suite.appIcon = .custom(makePNGData(color: .systemRed))
            let plugin = DockTilePlugin(iconChangeCenter: center)
            let dockTile = NSApplication.shared.dockTile
            plugin.setDockTile(dockTile)
            #expect(await waitUntilPanelAsync(timeout: 3) { (dockTile.contentView as? NSImageView)?.image != nil })

            suite.appIcon = .custom(makePNGData(color: .systemGreen))
            let before = dockTile.contentView
            center.post(name: .takoIconDidChange, object: nil)

            #expect(await waitUntilPanelAsync(timeout: 5) { dockTile.contentView !== before })
        }
    }
}
