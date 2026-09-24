import AppKit
import Testing
@testable import Tako

// Coverage for CustomStyleIcon.swift and AppIcon's `.customStyle` case: the
// rendered pixels (mark body/claw, eye holes showing the plate, the plate
// gradient's top/bottom stops, and each frame material's rim), the Codable
// storage form, and the `macos-icon = custom-style` config parse path
// (including invalid colours falling back to the brand defaults).

// `CustomStyleIcon.image` renders into an explicit `size`x`size` pixel
// bitmap (see its doc comment), so a CG point maps 1:1 to a bitmap pixel --
// only the vertical axis flips, since `colorAt(x:y:)` counts down from the
// top while the drawing used bottom-left-origin CG coordinates.
private func pixel(_ image: NSImage, cgX: CGFloat, cgY: CGFloat) -> NSColor? {
    guard let rep = image.representations.first as? NSBitmapImageRep else { return nil }
    let bmpX = Int(cgX.rounded())
    let bmpY = rep.pixelsHigh - 1 - Int(cgY.rounded())
    guard bmpX >= 0, bmpX < rep.pixelsWide, bmpY >= 0, bmpY < rep.pixelsHigh else { return nil }
    return rep.colorAt(x: bmpX, y: bmpY)
}

private func closeColor(_ a: NSColor?, _ hex: String, tolerance: CGFloat = 12.0 / 255) -> Bool {
    guard let a, let ar = a.usingColorSpace(.deviceRGB), let expected = NSColor(hex: hex),
          let br = expected.usingColorSpace(.deviceRGB) else { return false }
    return abs(ar.redComponent - br.redComponent) < tolerance
        && abs(ar.greenComponent - br.greenComponent) < tolerance
        && abs(ar.blueComponent - br.blueComponent) < tolerance
}

@Suite
struct CustomStyleIconCoverageTests {
    private static let size: CGFloat = 256

    private static func render(
        body: String = CustomStyleIcon.defaultBodyColor,
        claw: String = CustomStyleIcon.defaultClawColor,
        screen: [String] = CustomStyleIcon.defaultScreenColors,
        frame: Tako.MacOSIconFrame = .aluminum
    ) -> NSImage {
        CustomStyleIcon.image(bodyColor: body, clawColor: claw, screenColors: screen, frame: frame, size: size)
    }

    @Test func bodyCellIsTheBodyColor() {
        let image = Self.render()
        let plate = CustomStyleIcon.plateRect(size: Self.size)
        // Row 3 ("..######..") is body cells only.
        let cell = CustomStyleIcon.cellRect(row: 3, col: 4, plate: plate)
        let color = pixel(image, cgX: cell.midX, cgY: cell.midY)
        #expect(closeColor(color, CustomStyleIcon.defaultBodyColor))
    }

    @Test func clawCellIsTheClawColor() {
        let image = Self.render()
        let plate = CustomStyleIcon.plateRect(size: Self.size)
        // Row 0 ("CC......CC") col 1 is a claw cell.
        let cell = CustomStyleIcon.cellRect(row: 0, col: 1, plate: plate)
        let color = pixel(image, cgX: cell.midX, cgY: cell.midY)
        #expect(closeColor(color, CustomStyleIcon.defaultClawColor))
    }

    @Test func eyeHoleShowsThePlateBehindIt() {
        let image = Self.render()
        let plate = CustomStyleIcon.plateRect(size: Self.size)
        // Row 4 ("..#o##o#..") col 3 is an eye.
        let cell = CustomStyleIcon.cellRect(row: 4, col: 3, plate: plate)
        let color = pixel(image, cgX: cell.midX, cgY: cell.midY)
        // An eye must not be the mark's own body/claw colour...
        #expect(!closeColor(color, CustomStyleIcon.defaultBodyColor))
        #expect(!closeColor(color, CustomStyleIcon.defaultClawColor))
        // ...it is somewhere along the plate's top-to-bottom gradient, so
        // it lies between the gradient's two stops on every channel.
        guard let color, let rgb = color.usingColorSpace(.deviceRGB),
              let top = NSColor(hex: CustomStyleIcon.defaultScreenColors[0])?.usingColorSpace(.deviceRGB),
              let bottom = NSColor(hex: CustomStyleIcon.defaultScreenColors[1])?.usingColorSpace(.deviceRGB)
        else {
            Issue.record("could not read colours to compare")
            return
        }
        let tolerance: CGFloat = 12.0 / 255
        #expect(rgb.redComponent <= max(top.redComponent, bottom.redComponent) + tolerance)
        #expect(rgb.redComponent >= min(top.redComponent, bottom.redComponent) - tolerance)
        #expect(rgb.blueComponent <= max(top.blueComponent, bottom.blueComponent) + tolerance)
        #expect(rgb.blueComponent >= min(top.blueComponent, bottom.blueComponent) - tolerance)
    }

    @Test func plateTopIsTheFirstScreenColor() {
        let image = Self.render()
        let plate = CustomStyleIcon.plateRect(size: Self.size)
        let color = pixel(image, cgX: plate.midX, cgY: plate.maxY - 2)
        #expect(closeColor(color, CustomStyleIcon.defaultScreenColors[0]))
    }

    @Test func plateBottomIsTheLastScreenColor() {
        let image = Self.render()
        let plate = CustomStyleIcon.plateRect(size: Self.size)
        let color = pixel(image, cgX: plate.midX, cgY: plate.minY + 2)
        #expect(closeColor(color, CustomStyleIcon.defaultScreenColors[1]))
    }

    @Test(arguments: [Tako.MacOSIconFrame.aluminum, .beige, .plastic, .chrome])
    func rimShowsTheFrameMaterialsFirstColor(frame: Tako.MacOSIconFrame) {
        let image = Self.render(frame: frame)
        // Just inside the top edge, above the plate: the rim, not the plate.
        let color = pixel(image, cgX: Self.size / 2, cgY: Self.size - 2)
        #expect(closeColor(color, CustomStyleIcon.frameColors(frame)[0]))
    }

    @Test func differentFrameMaterialsRenderDifferentRimColors() {
        let aluminum = Self.render(frame: .aluminum)
        let plastic = Self.render(frame: .plastic)
        let aluminumRim = pixel(aluminum, cgX: Self.size / 2, cgY: Self.size - 2)
        let plasticRim = pixel(plastic, cgX: Self.size / 2, cgY: Self.size - 2)
        #expect(!closeColor(aluminumRim, CustomStyleIcon.frameColors(.plastic)[0]))
        #expect(!closeColor(plasticRim, CustomStyleIcon.frameColors(.aluminum)[0]))
    }

    @Test func imageIsRenderedAtDockTileSize() {
        let image = CustomStyleIcon.image(
            bodyColor: CustomStyleIcon.defaultBodyColor, clawColor: CustomStyleIcon.defaultClawColor,
            screenColors: CustomStyleIcon.defaultScreenColors, frame: .aluminum)
        #expect(image.size.width == 1024)
        #expect(image.size.height == 1024)
    }
}

@Suite
struct AppIconCustomStyleCoverageTests {
    @Test func imageDelegatesToCustomStyleIcon() {
        let icon = AppIcon.customStyle(
            bodyColor: "#F4581C", clawColor: "#FF7A3D", screenColors: ["#2A211B", "#120F0D"], frame: .aluminum)
        let image = icon.image(in: .main)
        #expect(image != nil)
        #expect(image?.size.width == 1024)
    }

    @Test func codableRoundTripsTheCustomStyleCase() throws {
        let icon = AppIcon.customStyle(
            bodyColor: "#112233", clawColor: "#445566", screenColors: ["#010101", "#020202", "#030303"],
            frame: .chrome)
        let data = try JSONEncoder().encode(icon)
        let decoded = try JSONDecoder().decode(AppIcon.self, from: data)
        #expect(decoded == icon)
    }

    @Test func equatableDistinguishesCustomStylePayloads() {
        let a = AppIcon.customStyle(bodyColor: "#111111", clawColor: "#222222", screenColors: ["#000000"], frame: .beige)
        let b = AppIcon.customStyle(bodyColor: "#111111", clawColor: "#222222", screenColors: ["#000000"], frame: .plastic)
        #expect(a != b)
        #expect(a == a)
    }

    @Test func configWithDefaultsProducesTheBrandColorsAndAluminumFrame() throws {
        let config = try TemporaryConfig("macos-icon = custom-style")
        guard case let .customStyle(body, claw, screen, frame)? = AppIcon(config: config) else {
            Issue.record("expected .customStyle")
            return
        }
        #expect(body == CustomStyleIcon.defaultBodyColor)
        #expect(claw == CustomStyleIcon.defaultClawColor)
        #expect(screen == CustomStyleIcon.defaultScreenColors)
        #expect(frame == .aluminum)
    }

    @Test func configWithAGhostColorSetsTheBodyAndLightensTheClaw() throws {
        let config = try TemporaryConfig("""
            macos-icon = custom-style
            macos-icon-ghost-color = #336699
            """)
        guard case let .customStyle(body, claw, _, _)? = AppIcon(config: config) else {
            Issue.record("expected .customStyle")
            return
        }
        #expect(body.uppercased() == "#336699")
        #expect(claw != body)
        #expect(claw != CustomStyleIcon.defaultClawColor)
    }

    @Test func configWithScreenColorsParsesTheCommaList() throws {
        let config = try TemporaryConfig("""
            macos-icon = custom-style
            macos-icon-screen-color = #101010,#202020,#303030
            """)
        guard case let .customStyle(_, _, screen, _)? = AppIcon(config: config) else {
            Issue.record("expected .customStyle")
            return
        }
        #expect(screen == ["#101010", "#202020", "#303030"])
    }

    @Test func configWithAFrameSetsIt() throws {
        let config = try TemporaryConfig("""
            macos-icon = custom-style
            macos-icon-frame = chrome
            """)
        guard case let .customStyle(_, _, _, frame)? = AppIcon(config: config) else {
            Issue.record("expected .customStyle")
            return
        }
        #expect(frame == .chrome)
    }

    @Test func configWithInvalidColorsFallsBackToDefaults() throws {
        let config = try TemporaryConfig("""
            macos-icon = custom-style
            macos-icon-ghost-color = not-a-color
            macos-icon-screen-color = also-not-a-color,nope
            macos-icon-frame = not-a-material
            """)
        guard case let .customStyle(body, claw, screen, frame)? = AppIcon(config: config) else {
            Issue.record("expected .customStyle")
            return
        }
        #expect(body == CustomStyleIcon.defaultBodyColor)
        #expect(claw == CustomStyleIcon.defaultClawColor)
        #expect(screen == CustomStyleIcon.defaultScreenColors)
        #expect(frame == .aluminum)
    }
}
