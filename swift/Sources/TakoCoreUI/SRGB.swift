import CoreGraphics

// A theme's `#rrggbb` is an sRGB triple. `CGColor(red:green:blue:alpha:)`
// builds in the generic RGB space instead, which on a wide-gamut display
// lands visibly off the intended colour -- TokyoNight's #1a1b26 background
// renders as #20212c. Everything that turns theme bytes into a colour goes
// through here.

public let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

public func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgbSpace, components: [r, g, b, a])
        ?? CGColor(red: r, green: g, blue: b, alpha: a)
}

public func srgb(r: UInt8, g: UInt8, b: UInt8, a: CGFloat = 1) -> CGColor {
    srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, a)
}
