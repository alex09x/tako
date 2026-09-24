import CoreGraphics
import CoreText
import Foundation
import Metal
import XCTest
@testable import TakoCoreUI

/// `custom-shader`: GLSL translated to Metal, run over the rendered
/// terminal image, observed as pixels read back from an offscreen target.
final class CustomShaderPixelTests: XCTestCase {
    private static let cellWidth = 10
    private static let cellHeight = 20

    private static let inverting = """
    #version 300 es
    precision highp float;
    // Inverts every pixel.
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        vec2 uv = fragCoord / iResolution.xy;
        vec4 color = texture(iChannel0, uv);
        fragColor = vec4(1.0 - color.rgb, color.a);
    }
    """

    private static let halving = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        fragColor = vec4(texture(iChannel0, fragCoord / iResolution.xy).rgb * 0.5, 1.0);
    }
    """

    private static let brightening = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        fragColor = vec4(texture(iChannel0, fragCoord / iResolution.xy).rgb + 0.25, 1.0);
    }
    """

    private static let broken = """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        fragColor = vec4(1.0
    }
    """

    // MARK: - Fixtures

    private func device() throws -> MTLDevice {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        try XCTSkipUnless(device.hasUnifiedMemory, "reading a texture back needs shared storage")
        return device
    }

    private func makeRenderer(device: MTLDevice) throws -> MetalTerminalRenderer {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        return try MetalTerminalRenderer(
            device: device,
            library: library,
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: CGFloat(Self.cellWidth),
                cellHeight: CGFloat(Self.cellHeight),
                ascent: 15,
                scale: 1))
    }

    /// Blank cells, one background per row.
    private func frame(
        cols: UInt32,
        rowBackgrounds: [(UInt8, UInt8, UInt8)],
        cursor: (row: UInt32, col: UInt32)? = nil
    ) -> FfiRenderFrame {
        var bytes = [UInt8]()
        for bg in rowBackgrounds {
            for _ in 0..<cols {
                bytes += [32, 0, 0, 0, 0xff, 0xff, 0xff, bg.0, bg.1, bg.2]
                while bytes.count % TerminalCell.byteSize != 0 { bytes.append(0) }
            }
        }
        let rows = UInt32(rowBackgrounds.count)
        return FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: cols,
                rows: rows,
                cursorRow: cursor?.row ?? 0,
                cursorCol: cursor?.col ?? 0,
                cursorVisible: cursor != nil,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                title: "test",
                modes: FfiTerminalModes(
                    autowrap: true, originMode: false, cursorKeyAppMode: false, mouseTracking: .off,
                    mouseUtf8: false, mouseSgr: false, focusEvents: false, bracketedPaste: false),
                viewportOffset: 0,
                scrollbackLen: 0,
                damagedRows: Array(0..<rows),
                selection: nil,
                graphicsPlacements: []),
            packedCells: Data(bytes),
            epoch: 0)
    }

    private struct Pixels: Equatable {
        let width: Int
        let bytes: [UInt8]

        func at(x: Int, y: Int) -> [Int] {
            let i = (y * width + x) * 4
            return [Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i])]
        }

        func centre(col: Int, row: Int) -> [Int] {
            at(x: col * CustomShaderPixelTests.cellWidth + CustomShaderPixelTests.cellWidth / 2,
               y: row * CustomShaderPixelTests.cellHeight + CustomShaderPixelTests.cellHeight / 2)
        }
    }

    private func render(_ frame: FfiRenderFrame, with renderer: MetalTerminalRenderer) throws -> Pixels {
        let width = Int(frame.snapshot.cols) * Self.cellWidth
        let height = Int(frame.snapshot.rows) * Self.cellHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = renderer.clearColor
        let stats = renderer.render(
            frame: frame,
            viewport: TerminalMetalViewport(drawableWidth: Float(width), drawableHeight: Float(height)),
            descriptor: pass,
            waitUntilCompleted: true)
        XCTAssertEqual(stats.presentation, .committedOffscreen)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return Pixels(width: width, bytes: bytes)
    }

    private func assertColour(_ actual: [Int], _ expected: [Int], _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (a, e) in zip(actual, expected) where abs(a - e) > 2 {
            XCTFail("\(message): got \(actual), expected \(expected)", file: file, line: line)
            return
        }
    }

    // MARK: - Tests

    /// A known cell's pixels come out as their inverse, and each row stays
    /// in its own place: a missing v flip would swap the two rows.
    func testAnInvertingShaderTurnsEachCellIntoItsInverse() throws {
        let device = try device()
        let terminal = frame(cols: 2, rowBackgrounds: [(0x20, 0x30, 0x40), (0xf0, 0x10, 0x80)])

        let plain = try render(terminal, with: try makeRenderer(device: device))
        assertColour(plain.centre(col: 1, row: 0), [0x20, 0x30, 0x40], "the unshaded frame")
        assertColour(plain.centre(col: 1, row: 1), [0xf0, 0x10, 0x80], "the unshaded frame")

        let renderer = try makeRenderer(device: device)
        XCTAssertEqual(renderer.setCustomShaders([("invert.glsl", Self.inverting)]), [])
        XCTAssertEqual(renderer.customShaders.map(\.name), ["invert.glsl"])
        let shaded = try render(terminal, with: renderer)
        assertColour(shaded.centre(col: 1, row: 0), [0xdf, 0xcf, 0xbf], "row 0 inverted")
        assertColour(shaded.centre(col: 0, row: 1), [0x0f, 0xef, 0x7f], "row 1 inverted")
    }

    /// GLSL `mod` (floored, unlike `fmod`), two-argument `atan`, a user
    /// function, a global const and `iTime` all compile and mean what GLSL
    /// says they mean.
    func testGLSLBuiltinsUserFunctionsConstantsAndTimeWork() throws {
        let device = try device()
        let renderer = try makeRenderer(device: device)
        var now: CFTimeInterval = 100
        renderer.customShaderClock = { now }
        let source = """
        const float PI = 3.14159265;
        const float HALF = 0.5;
        float wrapped(float x) { return mod(x, 1.0); }
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            float angle = atan(1.0, -1.0);
            fragColor = vec4(wrapped(iTime), angle / PI, mod(-0.25, 1.0) * HALF, 1.0);
        }
        """
        XCTAssertEqual(renderer.setCustomShaders([("builtins.glsl", source)]), [])
        now = 102.25
        let pixels = try render(frame(cols: 1, rowBackgrounds: [(0, 0, 0)]), with: renderer)
        // 0.25, 0.75 and 0.375 of full scale.
        assertColour(pixels.centre(col: 0, row: 0), [64, 191, 96], "builtins")
        XCTAssertEqual(renderer.customShaderUniforms.time, 2.25)
        XCTAssertEqual(renderer.customShaderUniforms.frame, 0)

        now = 102.5
        _ = try render(frame(cols: 1, rowBackgrounds: [(0, 0, 0)]), with: renderer)
        XCTAssertEqual(renderer.customShaderUniforms.frame, 1)
        XCTAssertEqual(renderer.customShaderUniforms.timeDelta, 0.25)
    }

    /// The cursor uniforms follow the drawn cursor, bottom-left origin, and
    /// keep where it was before.
    func testCursorUniformsTrackTheCursor() throws {
        let device = try device()
        let renderer = try makeRenderer(device: device)
        var now: CFTimeInterval = 0
        renderer.customShaderClock = { now }
        let source = """
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            fragColor = vec4(iCurrentCursor.xy, iPreviousCursor.x, 255.0) / 255.0;
        }
        """
        XCTAssertEqual(renderer.setCustomShaders([("cursor.glsl", source)]), [])
        let rows: [(UInt8, UInt8, UInt8)] = [(0x10, 0x10, 0x10), (0x10, 0x10, 0x10)]

        now = 1
        let first = try render(frame(cols: 3, rowBackgrounds: rows, cursor: (row: 1, col: 1)), with: renderer)
        // Column 1, top edge 20 px down a 40 px target: y 20 from the bottom.
        assertColour(first.centre(col: 0, row: 0), [10, 20, 10], "first cursor")
        XCTAssertEqual(renderer.customShaderUniforms.currentCursor, SIMD4<Float>(10, 20, 10, 20))

        now = 2
        let moved = try render(frame(cols: 3, rowBackgrounds: rows, cursor: (row: 0, col: 2)), with: renderer)
        assertColour(moved.centre(col: 0, row: 0), [20, 40, 10], "moved cursor")
        XCTAssertEqual(renderer.customShaderUniforms.previousCursor, SIMD4<Float>(10, 20, 10, 20))
        XCTAssertEqual(renderer.customShaderUniforms.timeCursorChange, 2)
    }

    /// Chained shaders run in the order given, through the ping-pong
    /// textures, the last one writing the target.
    func testChainedShadersComposeInOrder() throws {
        let device = try device()
        let background: (UInt8, UInt8, UInt8) = (0x40, 0x80, 0xc0)
        let terminal = frame(cols: 1, rowBackgrounds: [background])
        func expected(_ steps: [(Double) -> Double]) -> [Int] {
            [background.0, background.1, background.2].map { byte in
                var value = Double(byte) / 255
                for step in steps { value = (min(max(step(value), 0), 1) * 255).rounded() / 255 }
                return Int((value * 255).rounded())
            }
        }
        let half: (Double) -> Double = { $0 * 0.5 }
        let plus: (Double) -> Double = { $0 + 0.25 }

        let halfThenPlus = try makeRenderer(device: device)
        halfThenPlus.setCustomShaders([("half.glsl", Self.halving), ("plus.glsl", Self.brightening)])
        assertColour(try render(terminal, with: halfThenPlus).centre(col: 0, row: 0),
                     expected([half, plus]), "half, then plus")

        let plusThenHalf = try makeRenderer(device: device)
        plusThenHalf.setCustomShaders([("plus.glsl", Self.brightening), ("half.glsl", Self.halving)])
        assertColour(try render(terminal, with: plusThenHalf).centre(col: 0, row: 0),
                     expected([plus, half]), "plus, then half")

        let three = try makeRenderer(device: device)
        three.setCustomShaders([
            ("half.glsl", Self.halving), ("plus.glsl", Self.brightening), ("half.glsl", Self.halving),
        ])
        assertColour(try render(terminal, with: three).centre(col: 0, row: 0),
                     expected([half, plus, half]), "half, plus, half")
    }

    /// A shader that does not compile is reported with its own file name
    /// and leaves the frame exactly as it is with no shader -- even when it
    /// is chained after one that does compile.
    func testABrokenShaderLeavesTheFrameUntouchedAndIsReported() throws {
        let device = try device()
        let terminal = frame(cols: 2, rowBackgrounds: [(0x20, 0x30, 0x40), (0x50, 0x60, 0x70)], cursor: (0, 0))
        let plain = try render(terminal, with: try makeRenderer(device: device))

        let renderer = try makeRenderer(device: device)
        let errors = renderer.setCustomShaders([("invert.glsl", Self.inverting), ("broken.glsl", Self.broken)])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].hasPrefix("custom-shader broken.glsl: does not compile"), errors[0])
        XCTAssertTrue(errors[0].contains("broken.glsl:"), "the diagnostic does not name the user's file: \(errors[0])")
        XCTAssertEqual(renderer.customShaderErrors, errors)
        XCTAssertTrue(renderer.customShaders.isEmpty)
        XCTAssertEqual(try render(terminal, with: renderer), plain)
    }

    /// Files are read by path; one that cannot be read disables the chain
    /// and says which file it was.
    func testShadersLoadFromFilesAndAnUnreadableFileIsReported() throws {
        let device = try device()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("invert.glsl").path
        try Self.inverting.write(toFile: path, atomically: true, encoding: .utf8)

        let renderer = try makeRenderer(device: device)
        XCTAssertEqual(renderer.loadCustomShaders(paths: [path]), [])
        XCTAssertEqual(renderer.customShaders.map(\.name), ["invert.glsl"])

        let missing = directory.appendingPathComponent("missing.glsl").path
        let errors = renderer.loadCustomShaders(paths: [path, missing])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].hasPrefix("custom-shader \(missing): cannot read the file"), errors[0])
        XCTAssertTrue(renderer.customShaders.isEmpty)
    }
}

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
