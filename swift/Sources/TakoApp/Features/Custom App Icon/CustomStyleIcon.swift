import AppKit

/// Draws Tako's own mark at runtime for `macos-icon = custom-style`.
///
/// Upstream's custom-style icon draws its own trademarked ghost; this is a
/// port of `brand/make-icons.swift`'s macOS artwork instead -- a 10x7 grid
/// of rounded cells (claws, body, eyes) on a squircle plate, itself set
/// inside a material rim. The eyes are holes punched through the mark so
/// the plate shows through them, not a third fill colour.
enum CustomStyleIcon {
    static let defaultBodyColor = "#F4581C"
    static let defaultClawColor = "#FF7A3D"
    static let defaultScreenColors = ["#2A211B", "#120F0D"]

    /// `C` claw, `#` body, `o` eye, `.` empty.
    static let mark = [
        "CC......CC",
        "C........C",
        ".#......#.",
        "..######..",
        "..#o##o#..",
        "..######..",
        ".#.#..#.#.",
    ]
    static let markCols = 10
    static let markRows = 7

    /// The rim's gradient colours, top to bottom, for each frame material.
    static func frameColors(_ frame: Tako.MacOSIconFrame) -> [String] {
        switch frame {
        case .aluminum: return ["#E8E8EA", "#AEB0B4"]
        case .beige: return ["#E9DDC5", "#C8B695"]
        case .plastic: return ["#3B3B3D", "#222224"]
        case .chrome: return ["#FFFFFF", "#8E9094", "#FFFFFF", "#6A6C70"]
        }
    }

    /// The full icon bounds, before the plate's own inset.
    static func outerRect(size: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: size, height: size)
    }

    /// The squircle plate: inset 9% of the icon, corner radius 22.37% of
    /// its own width.
    static func plateRect(size: CGFloat) -> CGRect {
        let inset = size * 0.09
        return CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    }

    /// The bounds of one mark cell, laid out inside `plate`. The mark spans
    /// 65% of the plate's width, and each cell is drawn at 10/11 of its
    /// step so a gap remains between cells.
    static func cellRect(row: Int, col: Int, plate: CGRect) -> CGRect {
        let markWidth = plate.width * 0.65
        let step = markWidth / CGFloat(markCols)
        let cell = step * 10 / 11
        let markHeight = step * CGFloat(markRows)
        let originX = plate.midX - markWidth / 2
        let topY = plate.midY + markHeight / 2
        return CGRect(x: originX + CGFloat(col) * step, y: topY - CGFloat(row + 1) * step,
                      width: cell, height: cell)
    }

    /// Renders the icon at `size` pixels (1024 for the Dock tile).
    static func image(
        bodyColor: String, clawColor: String, screenColors: [String],
        frame: Tako.MacOSIconFrame, size: CGFloat = 1024
    ) -> NSImage {
        let body = OSColor(hex: bodyColor) ?? OSColor(hex: defaultBodyColor)!
        let claw = OSColor(hex: clawColor) ?? OSColor(hex: defaultClawColor)!
        let screenHexes = screenColors.isEmpty ? defaultScreenColors : screenColors
        let screen = screenHexes.compactMap { OSColor(hex: $0) }.isEmpty
            ? defaultScreenColors.map { OSColor(hex: $0)! }
            : screenHexes.compactMap { OSColor(hex: $0) }
        let rim = frameColors(frame).map { OSColor(hex: $0)! }

        // Draw the plate/frame twice: once alone as a backdrop, once with
        // the mark on top and the eyes punched clear through everything.
        // Compositing the backdrop underneath means the punched-out eyes
        // reveal the intact plate, not whatever is further behind it.
        let backdrop = renderLayer(screen: screen, rim: rim, size: size, mark: nil)
        let full = renderLayer(screen: screen, rim: rim, size: size, mark: (body, claw))

        let finalRep = bitmap(size: size)
        withContext(finalRep) { ctx in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            if let cgImage = backdrop.cgImage { ctx.draw(cgImage, in: rect) }
            if let cgImage = full.cgImage { ctx.draw(cgImage, in: rect) }
        }
        let final = NSImage(size: NSSize(width: size, height: size))
        final.addRepresentation(finalRep)
        return final
    }

    /// A pixel-exact bitmap, `size` pixels on a side regardless of the
    /// process's screen (or lack of one): `NSImage.lockFocus()` renders at
    /// the current screen's backing scale, which would silently double
    /// every pixel on a Retina display and make `size` a lie.
    private static func bitmap(size: CGFloat) -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else {
            fatalError("could not allocate a \(Int(size))x\(Int(size)) icon bitmap")
        }
        rep.size = NSSize(width: size, height: size)
        return rep
    }

    private static func withContext(_ rep: NSBitmapImageRep, _ body: (CGContext) -> Void) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body(NSGraphicsContext.current!.cgContext)
    }

    private static func renderLayer(
        screen: [OSColor], rim: [OSColor], size: CGFloat, mark markColors: (body: OSColor, claw: OSColor)?
    ) -> NSBitmapImageRep {
        let outer = outerRect(size: size)
        let plate = plateRect(size: size)
        let rep = bitmap(size: size)
        withContext(rep) { ctx in
            renderLayerContent(ctx, outer: outer, plate: plate, screen: screen, rim: rim, size: size, mark: markColors)
        }
        return rep
    }

    private static func renderLayerContent(
        _ ctx: CGContext, outer: CGRect, plate: CGRect, screen: [OSColor], rim: [OSColor], size: CGFloat,
        mark markColors: (body: OSColor, claw: OSColor)?
    ) {
        let outerRadius = size * 0.2237
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
        ctx.clip()
        drawTopToBottomGradient(ctx, colors: rim, in: outer)
        ctx.restoreGState()

        let plateRadius = plate.width * 0.2237
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil))
        ctx.clip()
        drawTopToBottomGradient(ctx, colors: screen, in: plate)
        ctx.restoreGState()

        if let markColors {
            let cornerRadius = (plate.width * 0.65 / CGFloat(markCols)) * 10 / 11 * 0.2
            for (r, row) in mark.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." {
                    let fill = ch == "C" ? markColors.claw : markColors.body
                    ctx.setFillColor(fill.cgColor)
                    ctx.addPath(CGPath(roundedRect: cellRect(row: r, col: c, plate: plate),
                                       cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
                    ctx.fillPath()
                }
            }

            ctx.setBlendMode(.clear)
            for (r, row) in mark.enumerated() {
                for (c, ch) in row.enumerated() where ch == "o" {
                    ctx.addPath(CGPath(roundedRect: cellRect(row: r, col: c, plate: plate),
                                       cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
                    ctx.fillPath()
                }
            }
            ctx.setBlendMode(.normal)
        }
    }

    /// A linear gradient down the vertical centreline of `rect`, first
    /// colour at the top and last at the bottom.
    private static func drawTopToBottomGradient(_ ctx: CGContext, colors: [OSColor], in rect: CGRect) {
        guard colors.count > 1 else {
            if let only = colors.first {
                ctx.setFillColor(only.cgColor)
                ctx.fill(rect)
            }
            return
        }
        let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors.map(\.cgColor) as CFArray, locations: locations)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

extension OSColor {
    /// A lighter tint used for the mark's claws when only a body colour is
    /// configured: brightness raised toward white, saturation eased back.
    func lightened(by amount: CGFloat = 0.35) -> OSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return OSColor(hue: h, saturation: max(s - amount * 0.3, 0),
                       brightness: min(b + (1 - b) * amount, 1), alpha: a)
    }
}
