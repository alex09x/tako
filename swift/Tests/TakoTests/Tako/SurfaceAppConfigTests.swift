import AppKit
import Foundation
import Testing
@testable import Tako

/// The surfaces in a real window carry their app's config.
///
/// Controllers built every surface from the app's C handle, and that
/// initializer had no app to give it: in the running app no surface had
/// macos-option-as-alt, copy-on-select, mouse-hide-while-typing,
/// confirm-close-surface or scrollback-limit, and Reload Configuration reached
/// none of them. Tests that built a surface from a `Tako.App` directly passed
/// throughout; driving the built app with real key events is what found it.
@Suite @MainActor
struct SurfaceAppConfigTests {
    private func app(_ text: String) throws -> (Tako.App, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (Tako.App(configPath: file.path), file)
    }

    private func close(_ controller: BaseTerminalController) {
        for view in controller.surfaceTree { view.close() }
    }

    @Test func aWindowsFirstSurfaceHasTheAppsConfig() throws {
        let (app, file) = try app("macos-option-as-alt = right\ncopy-on-select = clipboard\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = BaseTerminalController(app)
        defer { close(controller) }

        let view = try #require(controller.surfaceTree.first)
        #expect(view.optionAsAlt == .right)
        #expect(view.copyOnSelect == .clipboard)
        #expect(view.derivedConfig == Tako.SurfaceView.DerivedConfig(app.config))
    }

    @Test func aSplitHasTheAppsConfig() throws {
        let (app, file) = try app("macos-option-as-alt = left\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = BaseTerminalController(app)
        defer { close(controller) }

        let first = try #require(controller.surfaceTree.first)
        let split = try #require(controller.newSplit(at: first, direction: .right))
        #expect(split.optionAsAlt == .left)
    }

    /// A window restored at launch decodes its surfaces without an app; the
    /// controller that takes them gives them its own, and reloads reach them.
    @Test func aRestoredSurfaceIsAdoptedAndFollowsReloads() throws {
        let (app, file) = try app("macos-option-as-alt = right\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let restored = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        #expect(restored.optionAsAlt == .off)

        let controller = BaseTerminalController(app, surfaceTree: .init(view: restored))
        defer { close(controller) }
        #expect(restored.optionAsAlt == .right)

        try "macos-option-as-alt = left\n".write(to: file, atomically: true, encoding: .utf8)
        app.reloadConfig()
        #expect(restored.optionAsAlt == .left)
    }

    /// Adoption only fills a gap: a surface moved between windows keeps the
    /// app it was made by.
    @Test func adoptionLeavesASurfaceThatHasAnAppAlone() throws {
        let (owner, ownerFile) = try app("macos-option-as-alt = right\n")
        let (other, otherFile) = try app("macos-option-as-alt = left\n")
        defer {
            try? FileManager.default.removeItem(at: ownerFile)
            try? FileManager.default.removeItem(at: otherFile)
        }
        let view = Tako.SurfaceView(owner, uuid: UUID())
        defer { view.close() }
        view.adopt(by: other)
        #expect(view.optionAsAlt == .right)
    }
}
