import AppKit
import Foundation

// The app icons, drawn from the brand mark.
//
// The mark is a 10x7 grid of rounded cells -- claws, body, eyes, legs -- so
// it draws directly rather than going through an SVG renderer. The grid is
// `assets/takocore-mark.svg` transcribed; the eyes are holes punched
// through the body so the plate shows through, not squares of a third
// colour.

/// `C` claw, `#` body, `o` eye, `.` empty.
let mark = [
    "CC......CC",
    "C........C",
    ".#......#.",
    "..######..",
    "..#o##o#..",
    "..######..",
    ".#.#..#.#.",
]
let markCols = 10
let markRows = 7

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

struct Style {
    let top: NSColor        // gradient start, 160 degrees
    let bottom: NSColor
    let body: NSColor
    let claw: NSColor
    let squircle: Bool      // macOS sits on a rounded plate; iOS is masked by the system
}

let macOS = Style(top: color("#2A211B"), bottom: color("#120F0D"),
                  body: color("#F4581C"), claw: color("#FF7A3D"), squircle: true)
let iOS = Style(top: color("#FF7A3D"), bottom: color("#C23E0E"),
                body: color("#FAF7F2"), claw: color("#FAF7F2"), squircle: false)

func draw(size: Int, style: Style) -> Data {
    let px = CGFloat(size)
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let inset: CGFloat = style.squircle ? px * 0.09 : 0
    let plate = CGRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let radius = style.squircle ? plate.width * 0.2237 : 0
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
    ctx.clip()
    // 160 degrees measured from the top, so the light end is upper-left.
    let angle = 160.0 * Double.pi / 180
    let half = plate.width / 2
    let start = CGPoint(x: plate.midX - CGFloat(sin(angle)) * half,
                        y: plate.midY + CGFloat(cos(angle)) * half)
    let end = CGPoint(x: plate.midX + CGFloat(sin(angle)) * half,
                      y: plate.midY - CGFloat(cos(angle)) * half)
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [style.top.cgColor, style.bottom.cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: start, end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // The mark spans 65% of the plate: 665px on a 1024 icon.
    let markWidth = plate.width * 0.65
    let step = markWidth / CGFloat(markCols)
    let cell = step * 10 / 11          // the source grid is cell 10 on step 11
    let cornerRadius = cell * 0.2      // radius 2 on a cell of 10
    let markHeight = step * CGFloat(markRows)
    let originX = plate.midX - markWidth / 2
    let topY = plate.midY + markHeight / 2

    func rect(_ r: Int, _ c: Int) -> CGRect {
        CGRect(x: originX + CGFloat(c) * step,
               y: topY - CGFloat(r + 1) * step,
               width: cell, height: cell)
    }

    // At 32pt and below the two oranges stop being distinguishable, so the
    // brand sheet calls for a single colour there.
    let mono = size <= 32

    for (r, row) in mark.enumerated() {
        for (c, ch) in row.enumerated() where ch != "." {
            let fill: NSColor
            switch ch {
            case "C": fill = mono ? style.body : style.claw
            default: fill = style.body          // eyes are punched out below
            }
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(CGPath(roundedRect: rect(r, c), cornerWidth: cornerRadius,
                               cornerHeight: cornerRadius, transform: nil))
            ctx.fillPath()
        }
    }

    // The eyes are holes, so whatever is behind the crab shows through.
    ctx.setBlendMode(.clear)
    for (r, row) in mark.enumerated() {
        for (c, ch) in row.enumerated() where ch == "o" {
            ctx.addPath(CGPath(roundedRect: rect(r, c), cornerWidth: cornerRadius,
                               cornerHeight: cornerRadius, transform: nil))
            ctx.fillPath()
        }
    }
    ctx.setBlendMode(.normal)

    // Clearing punched through the plate too, so the gradient is laid back in
    // underneath everything that survived.
    image.unlockFocus()

    let backdrop = NSImage(size: NSSize(width: px, height: px))
    backdrop.lockFocus()
    let bctx = NSGraphicsContext.current!.cgContext
    bctx.saveGState()
    bctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                        transform: nil))
    bctx.clip()
    bctx.drawLinearGradient(gradient, start: start, end: end,
                            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    bctx.restoreGState()
    image.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
    backdrop.unlockFocus()

    let rep = NSBitmapImageRep(data: backdrop.tiffRepresentation!)!
    // The macOS plate is a squircle, so its corners have to stay transparent.
    guard !style.squircle else {
        return rep.representation(using: .png, properties: [:])!
    }

    // An iOS icon fills its square and the system applies the mask, so every
    // pixel here is already opaque -- but App Store Connect rejects an app
    // icon that merely *has* an alpha channel, so the pixels are copied into
    // a bitmap that does not have one.
    let opaque = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: opaque)
    backdrop.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return opaque.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
for (dir, style) in [("brand/out/macos", macOS), ("brand/out/ios", iOS)] {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        let png = draw(size: size, style: style)
        try png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(size).png"))
    }
}
print("icons written")
