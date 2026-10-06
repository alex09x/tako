/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation

/// Terminal appearance, mirroring the knobs upstream exposes in its
/// config: colors, font, padding, cursor and window opacity/blur.
///
/// Defaults are upstream's own defaults.
public struct TerminalTheme {
    /// `window-padding-color`: what shows in the leftover space around the
    /// grid. `extendAlways` always repeats the nearest edge cell's color;
    /// `extend` does too, except when that row is a full-width line that
    /// isn't the background color, where it falls back to `background`.
    public enum WindowPaddingColor: String, Sendable {
        case background
        case extend
        case extendAlways = "extend-always"
    }

    /// `window-colorspace`: the color space the Metal layer's colors are
    /// interpreted in.
    public enum ColorSpace: String, Sendable {
        case srgb
        case displayP3 = "display-p3"
    }

    public var background: CGColor
    public var foreground: CGColor
    public var selectionBackground: CGColor
    /// `selection-foreground`: color of selected text. Unset (nil, the
    /// default) keeps each cell's own foreground.
    public var selectionForeground: CGColor?
    /// `selection-invert-fg-bg`: draw a selection by swapping each cell's
    /// foreground and background instead of using
    /// `selection-background`/`selection-foreground`.
    public var selectionInvertFgBg: Bool
    public var cursorColor: CGColor
    /// `cursor-opacity`: the cursor's alpha, 0...1.
    public var cursorOpacity: Double
    /// `cursor-thickness`: the bar and underline cursor thickness in points.
    /// Nil keeps the renderer's own default thickness.
    public var cursorThickness: CGFloat?
    /// 0...1; below 1 the window is translucent (`background-opacity`).
    public var backgroundOpacity: Double
    /// Background blur radius behind a translucent window (`background-blur`).
    public var backgroundBlur: Int
    public var fontFamily: String?
    public var fontSize: CGFloat
    public var cellWidth: CGFloat?
    public var cellHeight: CGFloat?
    /// `window-padding-x` and `window-padding-y`, in points: each takes one
    /// value for both sides or `leading,trailing`.
    public var padding: TerminalPadding
    /// The padding on every side, for a caller that sets one value; reads
    /// the left.
    public var windowPadding: CGFloat {
        get { padding.left }
        set { padding = TerminalPadding(uniform: newValue) }
    }
    /// `window-padding-balance`: spread the leftover space evenly on all
    /// sides instead of leaving it at the right and bottom.
    public var windowPaddingBalance: Bool
    public var windowPaddingColor: WindowPaddingColor
    public var windowColorSpace: ColorSpace
    public var cursorBlink: Bool

    public init(
        background: CGColor = srgb(r: 0x14, g: 0x10, b: 0x0e),
        foreground: CGColor = srgb(r: 0xed, g: 0xe6, b: 0xdf),
        selectionBackground: CGColor = srgb(r: 0x35, g: 0x2b, b: 0x23),
        selectionForeground: CGColor? = nil,
        selectionInvertFgBg: Bool = false,
        cursorColor: CGColor = srgb(r: 0xf4, g: 0x58, b: 0x1c),
        cursorOpacity: Double = 1.0,
        cursorThickness: CGFloat? = nil,
        backgroundOpacity: Double = 1.0,
        backgroundBlur: Int = 0,
        fontFamily: String? = nil,
        fontSize: CGFloat = 13,
        cellWidth: CGFloat? = nil,
        cellHeight: CGFloat? = nil,
        windowPadding: CGFloat = 10,
        windowPaddingBalance: Bool = false,
        windowPaddingColor: WindowPaddingColor = .background,
        windowColorSpace: ColorSpace = .srgb,
        cursorBlink: Bool = true
    ) {
        self.background = background
        self.foreground = foreground
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.selectionInvertFgBg = selectionInvertFgBg
        self.cursorColor = cursorColor
        self.cursorOpacity = cursorOpacity
        self.cursorThickness = cursorThickness
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.padding = TerminalPadding(uniform: windowPadding)
        self.windowPaddingBalance = windowPaddingBalance
        self.windowPaddingColor = windowPaddingColor
        self.windowColorSpace = windowColorSpace
        self.cursorBlink = cursorBlink
    }

    /// The cursor's shape while the program has not chosen one (DECSCUSR).
    public var cursorShape: FfiCursorShape = .block

    /// `grapheme-width-method`: how many columns a grapheme cluster takes.
    public var graphemeWidthMethod: FfiGraphemeWidthMethod = .unicode

    /// The 16 ANSI colors plus the 240 extended ones a theme can override.
    public var palette: [Int: CGColor] = [:]

    /// Families for styled text (`font-family-bold` and so on); nil uses
    /// `fontFamily`.
    public var fontFamilyBold: String?
    public var fontFamilyItalic: String?
    public var fontFamilyBoldItalic: String?
    /// Named faces within each style's family (`font-style*`).
    public var fontStyle: FontStyle = .default
    public var fontStyleBold: FontStyle = .default
    public var fontStyleItalic: FontStyle = .default
    public var fontStyleBoldItalic: FontStyle = .default
    /// Which styles missing from a family may be synthesised.
    public var fontSyntheticStyle: FontSyntheticStyle = .all
    /// OpenType features applied to every face (`font-feature`).
    public var fontFeatures: [FontFeature] = []
    public var adjustCellWidth: MetricModifier?
    public var adjustCellHeight: MetricModifier?
    public var adjustFontBaseline: MetricModifier?
    public var adjustUnderlinePosition: MetricModifier?
    public var adjustUnderlineThickness: MetricModifier?

    /// `custom-shader` files in the order they are applied. A relative path
    /// is resolved against the directory of the config file that named it.
    public var customShaders: [String] = []
    /// `custom-shader-animation`.
    public var customShaderAnimation: TerminalCustomShaderAnimation = .enabled

    /// A `font-style*` value.
    public enum FontStyle: Equatable {
        /// The family's own face for the style.
        case `default`
        /// `false`: the style is drawn with the regular face.
        case disabled
        /// A face style name such as `Medium` or `Light Italic`.
        case named(String)

        init(configValue value: String) {
            switch value {
            case "", "default": self = .default
            case "false": self = .disabled
            default: self = .named(value)
            }
        }
    }

    /// `font-synthetic-style`: `true`, `false`, or a comma list of `bold`,
    /// `italic`, `bold-italic`, each optionally prefixed `no-`.
    public struct FontSyntheticStyle: OptionSet, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let bold = FontSyntheticStyle(rawValue: 1 << 0)
        public static let italic = FontSyntheticStyle(rawValue: 1 << 1)
        public static let boldItalic = FontSyntheticStyle(rawValue: 1 << 2)
        public static let all: FontSyntheticStyle = [.bold, .italic, .boldItalic]

        init?(configValue value: String) {
            switch value {
            case "true": self = .all; return
            case "false": self = []; return
            default: break
            }
            var result = FontSyntheticStyle.all
            for raw in value.split(separator: ",") {
                var name = raw.trimmingCharacters(in: .whitespaces)
                let enable = !name.hasPrefix("no-")
                if !enable { name.removeFirst(3) }
                let member: FontSyntheticStyle
                switch name {
                case "bold": member = .bold
                case "italic": member = .italic
                case "bold-italic": member = .boldItalic
                default: return nil
                }
                if enable { result.insert(member) } else { result.remove(member) }
            }
            self = result
        }
    }

    /// One OpenType feature setting: `ss01` is on, `-calt` off, `cv01=2`
    /// selects alternate 2.
    public struct FontFeature: Equatable {
        public var tag: String
        public var value: Int

        public init(tag: String, value: Int) {
            self.tag = tag
            self.value = value
        }

        static func parseList(_ value: String) -> [FontFeature]? {
            var features: [FontFeature] = []
            for item in value.split(separator: ",") {
                guard let feature = parse(item.trimmingCharacters(in: .whitespaces)) else { return nil }
                features.append(feature)
            }
            return features.isEmpty ? nil : features
        }

        private static func parse(_ item: String) -> FontFeature? {
            var text = Substring(item)
            var value = 1
            if text.hasPrefix("+") {
                text.removeFirst()
            } else if text.hasPrefix("-") {
                text.removeFirst()
                value = 0
            }
            var tag = text
            var setting: Substring?
            if let split = text.firstIndex(where: { $0 == "=" || $0 == " " }) {
                tag = text[..<split]
                setting = text[text.index(after: split)...]
            }
            let name = String(tag).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard name.count == 4, name.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
                return nil
            }
            if let setting {
                let word = setting.trimmingCharacters(in: CharacterSet(charactersIn: " ="))
                switch word {
                case "on": value = 1
                case "off": value = 0
                default:
                    guard let number = Int(word), number >= 0 else { return nil }
                    value = number
                }
            }
            return FontFeature(tag: name, value: value)
        }
    }

    /// An `adjust-*` value: whole points (`+2`, `-1`) or a percentage of
    /// the current value (`20%`, `-10%`).
    public enum MetricModifier: Equatable {
        case points(Int)
        case percent(Double)

        init?(configValue value: String) {
            if value.hasSuffix("%") {
                guard let percent = Double(value.dropLast()), percent.isFinite else { return nil }
                self = .percent(percent)
            } else {
                guard let points = Int(value) else { return nil }
                self = .points(points)
            }
        }

        public func apply(to value: CGFloat) -> CGFloat {
            switch self {
            case .points(let points): return value + CGFloat(points)
            case .percent(let percent): return (value * (1 + CGFloat(percent) / 100)).rounded()
            }
        }
    }

    /// Upstream's default theme.
    public static let takoDefault = TerminalTheme()

    /// Where a theme is looked up by name, first match wins: the user's own
    /// theme directories, then the themes bundled with the app.
    public static var themeSearchPaths: [String] {
        [
            "~/.config/tako-core/themes",
            "~/.config/tako/themes",
            "~/Library/Application Support/com.tako-core.terminal/themes",
        ].map { ($0 as NSString).expandingTildeInPath }
            + [Bundle.main.resourceURL?.appendingPathComponent("themes").path ?? ""]
    }
}
