/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Metal
import XCTest
@testable import TakoCoreUI

/// The translation itself, without a GPU.
final class CustomShaderTranslatorTests: XCTestCase {
    func testTheUserSourceIsRewrittenAndKeepsItsLineNumbers() {
        let glsl = """
        #version 330
        precision mediump float;
        uniform float iTime;
        /* two
           lines */ float f(in float x, inout vec2 p, out float y) { y = x; return x; } // out of here
        void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = vec4(0.0); }
        """
        let body = TerminalCustomShaderTranslator.translateBody(glsl)
        XCTAssertEqual(body.components(separatedBy: "\n").count, 6)
        XCTAssertFalse(body.contains("#version"))
        XCTAssertFalse(body.contains("precision"))
        XCTAssertFalse(body.contains("uniform"))
        XCTAssertFalse(body.contains("two"))
        XCTAssertFalse(body.contains("of here"))
        XCTAssertTrue(body.contains("float f(float x, thread vec2& p, thread float& y)"), body)
        XCTAssertTrue(body.contains("void mainImage(thread vec4& fragColor, vec2 fragCoord)"), body)

        let source = TerminalCustomShaderTranslator.metalSource(glsl: glsl, name: "my \"file\".glsl")
        XCTAssertTrue(source.contains("#line 1 \"my 'file'.glsl\""))
        XCTAssertTrue(source.contains("#define mod tako_mod"))
        XCTAssertTrue(source.contains("#undef mod"))
    }

    func testAnimationModes() {
        XCTAssertEqual(TerminalCustomShaderAnimation(configValue: "true"), .enabled)
        XCTAssertEqual(TerminalCustomShaderAnimation(configValue: "false"), .disabled)
        XCTAssertEqual(TerminalCustomShaderAnimation(configValue: "always"), .always)
        XCTAssertNil(TerminalCustomShaderAnimation(configValue: "sometimes"))
        XCTAssertFalse(TerminalCustomShaderAnimation.disabled.keepsAnimating(isFocused: true))
        XCTAssertTrue(TerminalCustomShaderAnimation.enabled.keepsAnimating(isFocused: true))
        XCTAssertFalse(TerminalCustomShaderAnimation.enabled.keepsAnimating(isFocused: false))
        XCTAssertTrue(TerminalCustomShaderAnimation.always.keepsAnimating(isFocused: false))
    }

    func testErrorDescriptions() {
        XCTAssertEqual(
            String(describing: TerminalCustomShaderError.pipelineFailed(name: "a.glsl", message: "why")),
            "custom-shader a.glsl: no pipeline: why")
    }
}

/// `custom-shader` and `custom-shader-animation` in a config.
final class CustomShaderConfigTests: XCTestCase {
    func testPathsAreRepeatableAndRelativeToTheConfigFile() {
        let theme = TerminalTheme.parse(config: """
        custom-shader = crt.glsl
        custom-shader = "../shared/bloom.glsl"
        custom-shader = /abs/glow.glsl
        custom-shader = ~/tilde.glsl
        """, configPath: "/cfg/tako/config")
        XCTAssertEqual(theme.customShaders, [
            "/cfg/tako/crt.glsl",
            "/cfg/shared/bloom.glsl",
            "/abs/glow.glsl",
            ("~/tilde.glsl" as NSString).expandingTildeInPath,
        ])
        XCTAssertEqual(theme.customShaderAnimation, .enabled)
    }

    func testAnEmptyValueClearsTheListAndAnimationParses() {
        let theme = TerminalTheme.parse(config: """
        custom-shader = a.glsl
        custom-shader =
        custom-shader = b.glsl
        custom-shader-animation = always
        custom-shader-animation = bogus
        """)
        XCTAssertEqual(theme.customShaders, ["b.glsl"])
        XCTAssertEqual(theme.customShaderAnimation, .always)
        XCTAssertEqual(TerminalTheme.parse(config: "custom-shader-animation = false").customShaderAnimation, .disabled)
    }

    /// Each user config file anchors its own relative paths.
    func testUserConfigFilesAnchorTheirOwnPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config").path
        try "custom-shader = shaders/crt.glsl\n".write(toFile: config, atomically: true, encoding: .utf8)
        let theme = TerminalTheme.loadUserConfig(paths: [config], themeSearchPaths: [])
        XCTAssertEqual(theme.customShaders, [
            ((directory.path as NSString).appendingPathComponent("shaders/crt.glsl") as NSString).standardizingPath,
        ])
    }

    /// A theme file sets colors; it keeps the config's shaders.
    func testAThemeDoesNotReplaceTheShaders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "custom-shader = other.glsl\ncustom-shader-animation = false\n"
            .write(to: directory.appendingPathComponent("shady"), atomically: true, encoding: .utf8)
        let theme = TerminalTheme.parse(
            config: "theme = shady\ncustom-shader = /mine.glsl",
            base: TerminalTheme(),
            honourTheme: true,
            themeSearchPaths: [directory.path])
        XCTAssertEqual(theme.customShaders, ["/mine.glsl"])
        XCTAssertEqual(theme.customShaderAnimation, .enabled)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// `custom-shader-animation` decides whether a drawn frame asks for the next.
@MainActor
final class CustomShaderAnimationNSViewTests: XCTestCase {
    private func makeView(shader: String?, animation: TerminalCustomShaderAnimation) throws -> (TakoTerminalNSView, NSWindow) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        TakoTerminalNSView.metalLibraryProviderForTesting = { _ in library }
        addTeardownBlock { TakoTerminalNSView.metalLibraryProviderForTesting = nil }

        var theme = TerminalTheme()
        theme.customShaderAnimation = animation
        if let shader {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("shader.glsl").path
            try shader.write(toFile: path, atomically: true, encoding: .utf8)
            theme.customShaders = [path]
        }
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), theme: theme)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.metalRendererForTesting, "the view built no renderer")
        return (view, window)
    }

    private static let shader = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        fragColor = texture(iChannel0, fragCoord / iResolution.xy) * (0.5 + 0.5 * sin(iTime));
    }
    """

    /// Whether the frame just drawn left another one owed.
    private func requestsAnotherFrame(_ view: TakoTerminalNSView) -> Bool {
        view.redrawNow()
        return view.redrawPending
    }

    func testFalseDrawsOnlyWhenSomethingChanged() throws {
        let (view, window) = try makeView(shader: Self.shader, animation: .disabled)
        window.makeFirstResponder(view)
        XCTAssertEqual(view.customShaderErrors, [])
        XCTAssertFalse(requestsAnotherFrame(view))
    }

    func testTrueAnimatesOnlyWhileFocused() throws {
        let (view, window) = try makeView(shader: Self.shader, animation: .enabled)
        window.makeFirstResponder(view)
        XCTAssertTrue(requestsAnotherFrame(view))
        XCTAssertTrue(requestsAnotherFrame(view), "the second frame stopped the animation")
        window.makeFirstResponder(nil)
        XCTAssertFalse(requestsAnotherFrame(view))
    }

    func testAlwaysAnimatesUnfocused() throws {
        let (view, window) = try makeView(shader: Self.shader, animation: .always)
        window.makeFirstResponder(nil)
        XCTAssertTrue(requestsAnotherFrame(view))
    }

    func testNoShaderOrABrokenOneNeverAnimates() throws {
        let (plain, _) = try makeView(shader: nil, animation: .always)
        XCTAssertFalse(requestsAnotherFrame(plain))

        let (broken, _) = try makeView(shader: "void mainImage(", animation: .always)
        XCTAssertEqual(broken.customShaderErrors.count, 1)
        XCTAssertFalse(requestsAnotherFrame(broken))
    }
}
#endif

#if canImport(UIKit)
import UIKit

@MainActor
final class CustomShaderAnimationUIViewTests: XCTestCase {
    func testAnimationFollowsTheSetting() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        TakoTerminalView.metalLibraryProviderForTesting = { _ in library }
        defer { TakoTerminalView.metalLibraryProviderForTesting = nil }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("shader.glsl").path
        try "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }"
            .write(toFile: path, atomically: true, encoding: .utf8)

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        for (animation, expected) in [(TerminalCustomShaderAnimation.disabled, false), (.enabled, false), (.always, true)] {
            var theme = view.theme
            theme.customShaders = [path]
            theme.customShaderAnimation = animation
            view.theme = theme
            XCTAssertEqual(view.customShaderErrors, [])
            view.redrawNow()
            XCTAssertEqual(view.redrawPending, expected, "\(animation) unfocused")
        }
    }
}
#endif
