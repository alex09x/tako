import Testing
import Foundation
import TakoKit
@testable import Tako

struct QuickTerminalSizeTests {
    @Test func sizeFromCStructNoneIsNil() {
        let cStruct = tako_quick_terminal_size_s(tag: .TAKO_QUICK_TERMINAL_SIZE_NONE)
        #expect(QuickTerminalSize.Size(from: cStruct) == nil)
    }

    @Test func sizeFromCStructPercentage() {
        let cStruct = tako_quick_terminal_size_s(
            tag: .TAKO_QUICK_TERMINAL_SIZE_PERCENTAGE,
            value: .init(percentage: 42))
        guard case .percentage(let value) = QuickTerminalSize.Size(from: cStruct) else {
            Issue.record("expected .percentage")
            return
        }
        #expect(value == 42)
    }

    @Test func sizeFromCStructPixels() {
        let cStruct = tako_quick_terminal_size_s(
            tag: .TAKO_QUICK_TERMINAL_SIZE_PIXELS,
            value: .init(pixels: 111))
        guard case .pixels(let value) = QuickTerminalSize.Size(from: cStruct) else {
            Issue.record("expected .pixels")
            return
        }
        #expect(value == 111)
    }

    @Test func quickTerminalSizeFromConfigCStructRoundTrips() {
        let cStruct = tako_config_quick_terminal_size_s(
            primary: .init(tag: .TAKO_QUICK_TERMINAL_SIZE_PIXELS, value: .init(pixels: 300)),
            secondary: .init(tag: .TAKO_QUICK_TERMINAL_SIZE_NONE))
        let size = QuickTerminalSize(from: cStruct)
        guard case .pixels(let value) = size.primary else {
            Issue.record("expected primary .pixels")
            return
        }
        #expect(value == 300)
        #expect(size.secondary == nil)
    }

    @Test func pixelsSizeIgnoresParentDimension() {
        let size = QuickTerminalSize.Size.pixels(250)
        #expect(size.toPixels(parentDimension: 1000) == 250)
        #expect(size.toPixels(parentDimension: 1) == 250)
    }

    @Test func percentageSizeScalesWithParentDimension() {
        let size = QuickTerminalSize.Size.percentage(25)
        #expect(size.toPixels(parentDimension: 1000) == 250)
        #expect(size.toPixels(parentDimension: 400) == 100)
    }

    @Test func defaultInitHasNoPrimaryOrSecondary() {
        let size = QuickTerminalSize()
        #expect(size.primary == nil)
        #expect(size.secondary == nil)
    }

    @Test func leftAndRightDefaultToFixed400WidthAndFullHeight() {
        let size = QuickTerminalSize()
        let dims = CGSize(width: 2000, height: 1200)
        #expect(size.calculate(position: .left, screenDimensions: dims) == CGSize(width: 400, height: 1200))
        #expect(size.calculate(position: .right, screenDimensions: dims) == CGSize(width: 400, height: 1200))
    }

    @Test func leftAndRightHonorConfiguredPrimaryAndSecondary() {
        let size = QuickTerminalSize(primary: .pixels(600), secondary: .percentage(50))
        let dims = CGSize(width: 2000, height: 1200)
        #expect(size.calculate(position: .left, screenDimensions: dims) == CGSize(width: 600, height: 600))
        #expect(size.calculate(position: .right, screenDimensions: dims) == CGSize(width: 600, height: 600))
    }

    @Test func topAndBottomDefaultToFullWidthAndFixed400Height() {
        let size = QuickTerminalSize()
        let dims = CGSize(width: 2000, height: 1200)
        #expect(size.calculate(position: .top, screenDimensions: dims) == CGSize(width: 2000, height: 400))
        #expect(size.calculate(position: .bottom, screenDimensions: dims) == CGSize(width: 2000, height: 400))
    }

    @Test func topAndBottomHonorConfiguredPrimaryAndSecondary() {
        let size = QuickTerminalSize(primary: .percentage(50), secondary: .pixels(1500))
        let dims = CGSize(width: 2000, height: 1200)
        #expect(size.calculate(position: .top, screenDimensions: dims) == CGSize(width: 1500, height: 600))
        #expect(size.calculate(position: .bottom, screenDimensions: dims) == CGSize(width: 1500, height: 600))
    }

    @Test func centerDefaultsToLandscape800x400WhenWiderThanTall() {
        let size = QuickTerminalSize()
        let dims = CGSize(width: 2000, height: 1200)
        #expect(size.calculate(position: .center, screenDimensions: dims) == CGSize(width: 800, height: 400))
    }

    @Test func centerDefaultsToPortrait400x800WhenTallerThanWide() {
        let size = QuickTerminalSize()
        let dims = CGSize(width: 800, height: 1600)
        #expect(size.calculate(position: .center, screenDimensions: dims) == CGSize(width: 400, height: 800))
    }

    @Test func centerTreatsEqualWidthAndHeightAsLandscape() {
        let size = QuickTerminalSize()
        let dims = CGSize(width: 1000, height: 1000)
        #expect(size.calculate(position: .center, screenDimensions: dims) == CGSize(width: 800, height: 400))
    }

    @Test func centerHonorsConfiguredPrimaryAndSecondaryInBothOrientations() {
        let size = QuickTerminalSize(primary: .pixels(900), secondary: .pixels(500))
        let landscape = CGSize(width: 2000, height: 1200)
        #expect(size.calculate(position: .center, screenDimensions: landscape) == CGSize(width: 900, height: 500))

        let portrait = CGSize(width: 800, height: 1600)
        #expect(size.calculate(position: .center, screenDimensions: portrait) == CGSize(width: 500, height: 900))
    }
}
