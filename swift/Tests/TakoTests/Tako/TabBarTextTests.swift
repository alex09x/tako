import AppKit
import CoreGraphics
import Testing
@testable import Tako

@MainActor
struct TabBarTextTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    @Test func unsupportedSpinnerAndEmojiNeverReachCoreTextFallback() {
        #expect(Tako.TabText.displayText("\u{2839} myfit", font: font) == "? myfit")
        #expect(Tako.TabText.displayText("build \u{1F980}", font: font) == "build ?")
        #expect(Tako.TabText.displayText("plain ASCII", font: font) == "plain ASCII")
    }

    @Test func rapidOscStyleTitlesHaveStableFiniteMetrics() {
        let spinners = ["\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}"]
        var checksum: CGFloat = 0
        var minimum = CGFloat.greatestFiniteMagnitude
        for index in 0..<20_000 {
            let title = "\(spinners[index % spinners.count]) myfit-\(index)"
            let width = Tako.TabText.width(of: title, font: font)
            minimum = min(minimum, width)
            checksum += width
        }
        #expect(checksum.isFinite)
        #expect(checksum > 0)
        #expect(minimum > 0)
    }

    @Test func truncationUsesOnlyMeasuredGlyphsAndHonorsTheLimit() {
        let limit = Tako.TabText.width(of: "01234567", font: font)
        let truncated = Tako.TabText.truncate("\u{2839} 0123456789 abc", to: limit, font: font)
        #expect(truncated.hasSuffix("\u{2026}"))
        #expect(!truncated.contains("\u{2839}"))
        #expect(Tako.TabText.width(of: truncated, font: font) <= limit)
    }

    @Test func directGlyphDrawingSurvivesFallbackHeavyTitles() throws {
        let width = 320
        let height = 40
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        for index in 0..<5_000 {
            let title = "\u{2839} compile \u{1F980} \(index)"
            let drawn = Tako.TabText.draw(
                title,
                atX: 4,
                centeredAtY: 20,
                font: font,
                color: .white,
                context: context
            )
            #expect(drawn.isFinite)
            #expect(drawn > 0)
        }
    }
}
