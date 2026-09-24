import AppKit
import Foundation
import Testing
@testable import Tako

/// `Tako.SurfaceView.optionAsAlt` is applied from `Tako.App.config` at
/// construction, and kept current across `Tako.App.reloadConfig()` -- see
/// `Tako+Config.swift`'s `macosOptionAsAlt` and `Tako+App.swift`'s
/// `configDidReload(_:)`.
@Suite
struct SurfaceOptionAsAltTests {
    @Test @MainActor
    func newSurfaceReadsOptionAsAltFromTheAppsConfig() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try "macos-option-as-alt = right\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let app = Tako.App(configPath: file.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }

        #expect(view.optionAsAlt == .right)
    }

    @Test @MainActor
    func surfaceWithNoAppKeepsTodaysDefault() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        #expect(view.optionAsAlt == .off)
    }

    @Test @MainActor
    func reloadConfigUpdatesAnExistingSurface() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try "macos-option-as-alt = false\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let app = Tako.App(configPath: file.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }
        #expect(view.optionAsAlt == .off)

        try "macos-option-as-alt = left\n".write(to: file, atomically: true, encoding: .utf8)
        app.reloadConfig()

        #expect(view.optionAsAlt == .left)
    }
}

/// Reload Configuration reaches the terminals already on screen. It used to
/// stop at the windows: a new theme, font or colors applied only to
/// terminals opened afterwards.
@Suite
struct SurfaceConfigReloadTests {
    private func configFile(_ text: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func rgb(_ color: CGColor) -> [Int] {
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
            .components!
        return c.prefix(3).map { Int(($0 * 255).rounded()) }
    }

    @Test @MainActor
    func aNewSurfaceTakesItsThemeFromItsAppsConfig() throws {
        let file = try configFile("background = #102030\n")
        defer { try? FileManager.default.removeItem(at: file) }

        let app = Tako.App(configPath: file.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }

        #expect(rgb(view.theme.background) == [0x10, 0x20, 0x30])
    }

    @Test @MainActor
    func reloadingTheConfigRethemesAnOpenSurface() throws {
        let file = try configFile("background = #102030\nfont-size = 13\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let app = Tako.App(configPath: file.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }

        try "background = #405060\nfont-size = 17\n".write(to: file, atomically: true, encoding: .utf8)
        app.reloadConfig()

        #expect(rgb(view.theme.background) == [0x40, 0x50, 0x60])
        #expect(view.theme.fontSize == 17)
    }

    /// Anything may call reloadConfig, from any thread. The surface took the
    /// announcement as already on the main thread, which trapped the process
    /// when it was not.
    @Test @MainActor
    func aReloadAnnouncedOffTheMainThreadReachesTheSurfaceOnIt() async throws {
        let file = try configFile("background = #102030\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let app = Tako.App(configPath: file.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }

        try "background = #405060\n".write(to: file, atomically: true, encoding: .utf8)
        nonisolated(unsafe) let unsafeApp = app
        await Task.detached { unsafeApp.reloadConfig() }.value

        let deadline = Date().addingTimeInterval(3)
        while rgb(view.theme.background) != [0x40, 0x50, 0x60], Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(rgb(view.theme.background) == [0x40, 0x50, 0x60])
    }

    @Test @MainActor
    func anotherAppsReloadLeavesTheSurfaceAlone() throws {
        let mine = try configFile("background = #102030\n")
        let other = try configFile("background = #405060\n")
        defer {
            try? FileManager.default.removeItem(at: mine)
            try? FileManager.default.removeItem(at: other)
        }
        let app = Tako.App(configPath: mine.path)
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }

        Tako.App(configPath: other.path).reloadConfig()

        #expect(rgb(view.theme.background) == [0x10, 0x20, 0x30])
    }
}
