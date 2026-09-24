import AppKit
import Foundation
import Testing
@testable import Tako

/// `link-url`, `cursor-click-to-move` and `mouse-shift-capture`: parsed with
/// upstream's defaults, reach an open surface, survive Reload Configuration,
/// and fall back to their default on an invalid value. See
/// `SurfaceOptionAsAltTests` for the sibling pattern these follow.
@Suite
struct SurfaceMouseAndLinkConfigTests {
    private func app(_ text: String) throws -> (Tako.App, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (Tako.App(configPath: file.path), file)
    }

    @Test @MainActor
    func theKeysAreReadWithUpstreamsDefaults() throws {
        let (defaults, file1) = try app("")
        let (set, file2) = try app("""
            link-url = false
            cursor-click-to-move = false
            mouse-shift-capture = always
            """)
        let (bad, file3) = try app("link-url = maybe\ncursor-click-to-move = maybe\nmouse-shift-capture = maybe\n")
        defer { [file1, file2, file3].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(defaults.config.linkURL == true)
        #expect(defaults.config.cursorClickToMove == true)
        #expect(defaults.config.mouseShiftCapture == .off)

        #expect(set.config.linkURL == false)
        #expect(set.config.cursorClickToMove == false)
        #expect(set.config.mouseShiftCapture == .always)

        #expect(bad.config.linkURL == true)
        #expect(bad.config.cursorClickToMove == true)
        #expect(bad.config.mouseShiftCapture == .off)
    }

    @Test @MainActor
    func aNewSurfaceReadsAllThreeFromTheAppsConfig() throws {
        let (app, file) = try app("link-url = false\ncursor-click-to-move = false\nmouse-shift-capture = never\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }

        #expect(view.linkURLDetectionEnabled == false)
        #expect(view.cursorClickToMove == false)
        #expect(view.mouseShiftCapture == .never)
    }

    @Test @MainActor
    func surfaceWithNoAppKeepsUpstreamsDefaults() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        #expect(view.linkURLDetectionEnabled == true)
        #expect(view.cursorClickToMove == true)
        #expect(view.mouseShiftCapture == .off)
    }

    /// Reload Configuration must apply these to terminals already on screen,
    /// the same as `macos-option-as-alt` and the theme already do.
    @Test @MainActor
    func reloadConfigUpdatesAnExistingSurface() throws {
        let (app, file) = try app("link-url = true\ncursor-click-to-move = true\nmouse-shift-capture = false\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }
        #expect(view.linkURLDetectionEnabled == true)
        #expect(view.cursorClickToMove == true)
        #expect(view.mouseShiftCapture == .off)

        try "link-url = false\ncursor-click-to-move = false\nmouse-shift-capture = always\n"
            .write(to: file, atomically: true, encoding: .utf8)
        app.reloadConfig()

        #expect(view.linkURLDetectionEnabled == false)
        #expect(view.cursorClickToMove == false)
        #expect(view.mouseShiftCapture == .always)
    }
}
