import Testing
import AppKit
import TakoKit
@testable import Tako

@MainActor
struct OSColorExtensionTests {
    @Test func isLightColorTrueForWhite() {
        #expect(OSColor.white.isLightColor)
    }

    @Test func isLightColorFalseForBlack() {
        #expect(!OSColor.black.isLightColor)
    }

    @Test func luminanceOfBlackIsZero() {
        #expect(OSColor.black.luminance == 0)
    }

    @Test func luminanceOfWhiteIsOne() {
        #expect(abs(OSColor.white.luminance - 1.0) < 0.0001)
    }

    @Test func hexStringRoundTripsThroughSixDigitHex() {
        let original = OSColor(hex: "#FF8800")
        #expect(original != nil)
        #expect(original?.hexString == "#FF8800")
    }

    @Test func hexInitParsesEightDigitHexWithAlpha() {
        let color = OSColor(hex: "80FF8800")
        #expect(color != nil)

        var alpha: CGFloat = 0
        color?.usingColorSpace(.sRGB)?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        #expect(abs(alpha - (Double(0x80) / 255.0)) < 0.01)
    }

    @Test func hexInitTrimsWhitespaceAndHash() {
        let color = OSColor(hex: "  #00FF00  ")
        #expect(color != nil)
        #expect(color?.hexString == "#00FF00")
    }

    @Test func hexInitRejectsInvalidLength() {
        #expect(OSColor(hex: "#FFF") == nil)
        #expect(OSColor(hex: "") == nil)
    }

    @Test func hexInitRejectsNonHexCharacters() {
        #expect(OSColor(hex: "ZZZZZZ") == nil)
    }

    @Test func darkenReducesBrightness() {
        let color = OSColor(hue: 0.3, saturation: 0.5, brightness: 0.8, alpha: 1)
        let darker = color.darken(by: 0.5)

        var originalBrightness: CGFloat = 0
        var darkerBrightness: CGFloat = 0
        color.getHue(nil, saturation: nil, brightness: &originalBrightness, alpha: nil)
        darker.getHue(nil, saturation: nil, brightness: &darkerBrightness, alpha: nil)

        #expect(darkerBrightness < originalBrightness)
    }

    @Test func takoColorInitConvertsComponentsToUnitRange() {
        var takoColor = tako_config_color_s()
        takoColor.r = 255
        takoColor.g = 0
        takoColor.b = 128

        let color = OSColor(tako: takoColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)

        #expect(abs(r - 1.0) < 0.01)
        #expect(abs(g - 0.0) < 0.01)
        #expect(abs(b - (128.0 / 255.0)) < 0.01)
    }
}
