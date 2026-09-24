import Foundation
import Testing
@testable import Tako

/// A relative `custom-shader` path names a file next to the config that
/// holds it, so the app's config hands the views absolute paths.
struct CustomShaderConfigPathTests {
    private func expected(_ config: TemporaryConfig, _ relative: String) -> String {
        let directory = (config.temporaryFile.path as NSString).deletingLastPathComponent
        return ((directory as NSString).appendingPathComponent(relative) as NSString).standardizingPath
    }

    @Test func aLoadedConfigResolvesRelativeShadersAgainstItsOwnDirectory() throws {
        let config = try TemporaryConfig("""
        custom-shader = shaders/crt.glsl
        custom-shader = /abs/glow.glsl
        custom-shader-animation = always
        """)
        #expect(config.theme.customShaders == [expected(config, "shaders/crt.glsl"), "/abs/glow.glsl"])
        #expect(config.theme.customShaderAnimation == .always)
    }

    @Test func aReloadedConfigResolvesThemTheSameWay() throws {
        let config = try TemporaryConfig("")
        #expect(config.theme.customShaders.isEmpty)
        try config.reload("custom-shader = bloom.glsl")
        #expect(config.theme.customShaders == [expected(config, "bloom.glsl")])
    }
}
