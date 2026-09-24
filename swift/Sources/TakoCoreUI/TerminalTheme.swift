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
    /// `block_hollow` in a config reads as a block: the view already draws
    /// the cursor hollow while the terminal is not focused.
    public var cursorShape: FfiCursorShape = .block

    /// `grapheme-width-method`: how many columns a grapheme cluster takes.
    public var graphemeWidthMethod: FfiGraphemeWidthMethod = .unicode

    /// The 16 ANSI colors plus the 240 extended ones a theme can override.
    /// `nil` entries keep the engine's built-in value.
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

        /// Nil when any part is not understood. Styles a list does not name
        /// stay enabled.
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

        /// Every setting in a comma list, or nil when one is malformed.
        /// Accepts `feat`, `+feat`, `-feat`, `feat=N`, `feat N`, `feat on`
        /// and `feat off`, with the tag optionally quoted.
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

        /// `value` adjusted; a percentage lands on a whole point.
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

    /// Every theme name available on this machine, sorted.
    public static func availableThemes() -> [String] {
        var names = Set<String>()
        for dir in themeSearchPaths {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in contents where !name.hasPrefix(".") {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    /// Load a theme by name and apply it on top of `self`. A theme file is
    /// the same `key = value` syntax as a config, so it reuses the parser.
    public func applyingTheme(named name: String) -> TerminalTheme {
        applyingTheme(named: name, searchPaths: Self.themeSearchPaths)
    }

    func applyingTheme(named name: String, searchPaths: [String]) -> TerminalTheme {
        for dir in searchPaths {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var merged = Self.parse(
                config: text,
                base: self,
                honourTheme: false,
                themeSearchPaths: searchPaths)
            // A theme sets colors; it must not clobber the user's font or
            // padding choices, which live in the config proper.
            merged.fontFamily = fontFamily
            merged.fontSize = fontSize
            merged.cellWidth = cellWidth
            merged.cellHeight = cellHeight
            merged.padding = padding
            merged.fontFamilyBold = fontFamilyBold
            merged.fontFamilyItalic = fontFamilyItalic
            merged.fontFamilyBoldItalic = fontFamilyBoldItalic
            merged.fontStyle = fontStyle
            merged.fontStyleBold = fontStyleBold
            merged.fontStyleItalic = fontStyleItalic
            merged.fontStyleBoldItalic = fontStyleBoldItalic
            merged.fontSyntheticStyle = fontSyntheticStyle
            merged.fontFeatures = fontFeatures
            merged.adjustCellWidth = adjustCellWidth
            merged.adjustCellHeight = adjustCellHeight
            merged.adjustFontBaseline = adjustFontBaseline
            merged.adjustUnderlinePosition = adjustUnderlinePosition
            merged.adjustUnderlineThickness = adjustUnderlineThickness
            merged.windowPaddingBalance = windowPaddingBalance
            merged.windowPaddingColor = windowPaddingColor
            merged.windowColorSpace = windowColorSpace
            merged.customShaders = customShaders
            merged.customShaderAnimation = customShaderAnimation
            return merged
        }
        return self
    }

    /// Parse a config file's appearance keys: `key = value` lines, `#`
    /// comments. Keys that are not about appearance are ignored.
    /// `configPath` is the file the text came from; relative
    /// `custom-shader` paths are resolved against its directory.
    public static func parse(config text: String,
                             base: TerminalTheme = TerminalTheme(),
                             honourTheme: Bool = true,
                             configPath: String? = nil) -> TerminalTheme {
        parse(
            config: text,
            base: base,
            honourTheme: honourTheme,
            themeSearchPaths: Self.themeSearchPaths,
            configPath: configPath)
    }

    static func parse(config text: String,
                      base: TerminalTheme,
                      honourTheme: Bool,
                      themeSearchPaths: [String],
                      configPath: String? = nil) -> TerminalTheme {
        var entries: [(key: String, value: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            entries.append((String(key), String(value)))
        }

        // Tako applies the selected theme first, then overlays every
        // explicit setting in the config regardless of textual order.
        // This matters for generated configs, where `theme` is often the
        // last line but a hand-picked foreground must still win.
        let themeName = honourTheme
            ? entries.last(where: { $0.key == "theme" })?.value
            : nil
        var theme = themeName.map {
            base.applyingTheme(named: $0, searchPaths: themeSearchPaths)
        } ?? base

        for (key, value) in entries {
            switch key {
            case "background":
                if let c = parseColor(value) { theme.background = c }
            case "foreground":
                if let c = parseColor(value) { theme.foreground = c }
            case "selection-background":
                if let c = parseColor(value) { theme.selectionBackground = c }
            case "selection-foreground":
                if let c = parseColor(value) { theme.selectionForeground = c }
            case "selection-invert-fg-bg":
                if let b = parseBool(value) { theme.selectionInvertFgBg = b }
            case "cursor-color":
                if let c = parseColor(value) { theme.cursorColor = c }
            case "cursor-opacity":
                if let d = Double(value), d.isFinite { theme.cursorOpacity = min(max(d, 0), 1) }
            case "cursor-thickness":
                if let d = Double(value), d.isFinite, d > 0 { theme.cursorThickness = CGFloat(d) }
            case "background-opacity":
                if let d = Double(value) { theme.backgroundOpacity = min(max(d, 0), 1) }
            case "background-blur", "background-blur-radius":
                if let i = Int(value) { theme.backgroundBlur = i }
            case "font-family":
                theme.fontFamily = value
            case "font-size":
                if let d = Double(value) { theme.fontSize = CGFloat(d) }
            case "cell-width", "cell_width":
                if let d = Double(value) { theme.cellWidth = CGFloat(d) }
            case "cell-height", "cell_height":
                if let d = Double(value) { theme.cellHeight = CGFloat(d) }
            case "font-family-bold":
                theme.fontFamilyBold = family(value)
            case "font-family-italic":
                theme.fontFamilyItalic = family(value)
            case "font-family-bold-italic":
                theme.fontFamilyBoldItalic = family(value)
            case "font-style":
                theme.fontStyle = FontStyle(configValue: unquoted(value))
            case "font-style-bold":
                theme.fontStyleBold = FontStyle(configValue: unquoted(value))
            case "font-style-italic":
                theme.fontStyleItalic = FontStyle(configValue: unquoted(value))
            case "font-style-bold-italic":
                theme.fontStyleBoldItalic = FontStyle(configValue: unquoted(value))
            case "font-synthetic-style":
                if let style = FontSyntheticStyle(configValue: value) { theme.fontSyntheticStyle = style }
            case "font-feature":
                // Repeatable; an empty value clears the list.
                if value.isEmpty {
                    theme.fontFeatures = []
                } else if let features = FontFeature.parseList(value) {
                    for feature in features {
                        theme.fontFeatures.removeAll { $0.tag == feature.tag }
                        theme.fontFeatures.append(feature)
                    }
                }
            case "adjust-cell-width":
                parseModifier(value, into: &theme.adjustCellWidth)
            case "adjust-cell-height":
                parseModifier(value, into: &theme.adjustCellHeight)
            case "adjust-font-baseline":
                parseModifier(value, into: &theme.adjustFontBaseline)
            case "adjust-underline-position":
                parseModifier(value, into: &theme.adjustUnderlinePosition)
            case "adjust-underline-thickness":
                parseModifier(value, into: &theme.adjustUnderlineThickness)
            case "window-padding-x":
                if let pair = TerminalPadding.pair(value) { (theme.padding.left, theme.padding.right) = pair }
            case "window-padding-y":
                if let pair = TerminalPadding.pair(value) { (theme.padding.top, theme.padding.bottom) = pair }
            case "window-padding-balance":
                if let b = parseBool(value) { theme.windowPaddingBalance = b }
            case "window-padding-color":
                if let c = WindowPaddingColor(rawValue: value) { theme.windowPaddingColor = c }
            case "window-colorspace":
                if let c = ColorSpace(rawValue: value) { theme.windowColorSpace = c }
            case "cursor-style-blink":
                theme.cursorBlink = (value != "false")
            case "cursor-style":
                switch value {
                case "block", "block_hollow": theme.cursorShape = .block
                case "bar": theme.cursorShape = .bar
                case "underline": theme.cursorShape = .underline
                default: break
                }
            case "grapheme-width-method":
                switch value {
                case "unicode": theme.graphemeWidthMethod = .unicode
                case "legacy": theme.graphemeWidthMethod = .legacy
                default: break
                }
            case "custom-shader":
                // Repeatable; an empty value clears the list.
                if value.isEmpty {
                    theme.customShaders = []
                } else {
                    theme.customShaders.append(shaderPath(unquoted(value), configPath: configPath))
                }
            case "custom-shader-animation":
                if let animation = TerminalCustomShaderAnimation(configValue: value) {
                    theme.customShaderAnimation = animation
                }
            case "theme":
                continue
            case "palette":
                // `palette = N=#rrggbb`
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   let color = parseColor(String(parts[1])) {
                    theme.palette[index] = color
                }
            default:
                continue
            }
        }
        return theme
    }

    /// `path` with `~` expanded and, when relative, anchored at the
    /// directory of `configPath`.
    static func shaderPath(_ path: String, configPath: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/"), let configPath else { return expanded }
        let directory = (configPath as NSString).deletingLastPathComponent
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// An empty value resets the modifier; one that does not parse is ignored.
    private static func parseModifier(_ value: String, into modifier: inout MetricModifier?) {
        if value.isEmpty {
            modifier = nil
        } else if let parsed = MetricModifier(configValue: value) {
            modifier = parsed
        }
    }

    /// A family name, or nil for an empty value (back to `font-family`).
    private static func family(_ value: String) -> String? {
        let name = unquoted(value)
        return name.isEmpty ? nil : name
    }

    /// `value` without one pair of surrounding double quotes.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// `true` or `false`; anything else is not a valid boolean, so the
    /// caller keeps whatever the field already held.
    static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// `#rrggbb`, `rrggbb`, or `r,g,b` -- the forms Tako configs use.
    public static func parseColor(_ s: String) -> CGColor? {
        var text = s.trimmingCharacters(in: .whitespaces)
        if text.contains(",") {
            let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 else { return nil }
            return srgb(parts[0] / 255, parts[1] / 255, parts[2] / 255, 1)
        }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return srgb(CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255, 1)
    }

    /// Load the user's config: the application-support file first, then the
    /// XDG files, which win.
    public static func loadUserConfig() -> TerminalTheme {
        let paths = [
            "~/Library/Application Support/com.tako-core.terminal/config",
            "~/.config/tako-core/config",
            "~/.config/tako/config",
        ].map { ($0 as NSString).expandingTildeInPath }
        return loadUserConfig(paths: paths, themeSearchPaths: Self.themeSearchPaths)
    }

    /// Each existing file in `paths` is parsed on top of the previous result,
    /// so a later file overrides an earlier one, `theme` included.
    static func loadUserConfig(paths: [String], themeSearchPaths: [String]) -> TerminalTheme {
        var theme = TerminalTheme.takoDefault
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            theme = parse(
                config: text,
                base: theme,
                honourTheme: true,
                themeSearchPaths: themeSearchPaths,
                configPath: path)
        }
        return theme
    }
}

extension TakoCore {
    /// Makes `theme`'s colors the engine's base colors: what a program's
    /// OSC 104/110/111/112 and a reset return to, and what color queries
    /// report until a program sets its own. Colors a program has already set
    /// stay as it set them, so this is safe to call on every theme change.
    ///
    /// Feeding the theme as OSC 4/10/11/12 instead would make it a program
    /// override: a program resetting "its" colors on exit would then land on
    /// the engine's built-ins rather than the theme.
    public func setBaseColors(from theme: TerminalTheme) {
        let palette: [FfiPaletteEntry] = theme.palette
            .sorted(by: { $0.key < $1.key })
            .compactMap { index, color in
                guard (0..<256).contains(index), let value = Self.rgb(color) else { return nil }
                return FfiPaletteEntry(index: UInt8(index), color: value)
            }
        setBaseColors(
            foreground: Self.rgb(theme.foreground),
            background: Self.rgb(theme.background),
            cursor: Self.rgb(theme.cursorColor),
            palette: palette)
    }

    /// Makes `theme`'s cursor the engine's default: what a program's
    /// DECSCUSR 0 and a reset return to. A style the program chose stays.
    public func setDefaultCursorStyle(from theme: TerminalTheme) {
        setDefaultCursorStyle(shape: theme.cursorShape, blinking: theme.cursorBlink)
    }

    /// Makes `theme`'s `grapheme-width-method` the engine's: mode 2027's
    /// value now and after a reset.
    public func setGraphemeWidthMethod(from theme: TerminalTheme) {
        setGraphemeWidthMethod(method: theme.graphemeWidthMethod)
    }

    /// `color` as sRGB bytes, rounded; nil when it has no RGB form.
    static func rgb(_ color: CGColor) -> FfiRgb? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return FfiRgb(r: byte(c[0]), g: byte(c[1]), b: byte(c[2]))
    }
}

/// Space between a terminal view's edges and its grid, in points.
public struct TerminalPadding: Equatable, Sendable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    public init(uniform value: CGFloat) {
        self.init(left: value, right: value, top: value, bottom: value)
    }

    /// `a` for both sides or `a,b` for leading and trailing; nil for
    /// anything else, including a negative value.
    static func pair(_ value: String) -> (CGFloat, CGFloat)? {
        let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let first = CGFloat(parts[0]!)
        return (first, parts.count == 2 ? CGFloat(parts[1]!) : first)
    }
}

/// Where a terminal's grid sits in its view: as many whole cells as fit
/// inside the padding, placed at the top-left of what is left -- or, with
/// `window-padding-balance`, centred in it, so the leftover is spread over
/// both sides instead of all landing at the right and the bottom.
public struct TerminalGridLayout: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    /// Points from the view's left edge to the grid's.
    public let left: CGFloat
    /// Points from the view's top edge to the grid's.
    public let top: CGFloat
    public let cellSize: CGSize

    public init(viewSize: CGSize, cellSize: CGSize, padding: TerminalPadding, balance: Bool) {
        let cellW = max(cellSize.width, 1)
        let cellH = max(cellSize.height, 1)
        let usableW = viewSize.width - padding.left - padding.right
        let usableH = viewSize.height - padding.top - padding.bottom
        // A hair of tolerance: a size made as cells times cell width must fit
        // that many cells, however the product rounded.
        cols = max(Int((usableW / cellW + 1e-6).rounded(.down)), 1)
        rows = max(Int((usableH / cellH + 1e-6).rounded(.down)), 1)
        let spareW = max(0, usableW - CGFloat(cols) * cellW)
        let spareH = max(0, usableH - CGFloat(rows) * cellH)
        left = padding.left + (balance ? (spareW / 2).rounded(.down) : 0)
        top = padding.top + (balance ? (spareH / 2).rounded(.down) : 0)
        self.cellSize = CGSize(width: cellW, height: cellH)
    }

    public init(viewSize: CGSize, cellSize: CGSize, theme: TerminalTheme) {
        self.init(viewSize: viewSize, cellSize: cellSize, padding: theme.padding, balance: theme.windowPaddingBalance)
    }

    /// Where a grid of a known size sits -- the one on screen, which lags the
    /// view's size while a resize settles.
    public init(viewSize: CGSize, cellSize: CGSize, theme: TerminalTheme, cols: Int, rows: Int) {
        let fitted = TerminalGridLayout(viewSize: viewSize, cellSize: cellSize, theme: theme)
        let cellW = fitted.cellSize.width
        let cellH = fitted.cellSize.height
        let padding = theme.padding
        let spareW = max(0, viewSize.width - padding.left - padding.right - CGFloat(cols) * cellW)
        let spareH = max(0, viewSize.height - padding.top - padding.bottom - CGFloat(rows) * cellH)
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        left = padding.left + (theme.windowPaddingBalance ? (spareW / 2).rounded(.down) : 0)
        top = padding.top + (theme.windowPaddingBalance ? (spareH / 2).rounded(.down) : 0)
        self.cellSize = fitted.cellSize
    }

    /// Points from the grid's right edge to the view's.
    public func right(in viewSize: CGSize) -> CGFloat {
        max(0, viewSize.width - left - CGFloat(cols) * cellSize.width)
    }

    /// Points from the grid's bottom edge to the view's.
    public func bottom(in viewSize: CGSize) -> CGFloat {
        max(0, viewSize.height - top - CGFloat(rows) * cellSize.height)
    }

    /// The grid cell under a point measured from the view's top-left, with
    /// the grid's own size as the bound. A point in the padding maps to the
    /// nearest edge cell.
    public func cell(atTopLeftPoint point: CGPoint, cols: Int, rows: Int) -> (row: Int, col: Int) {
        let col = Int(((point.x - left) / cellSize.width).rounded(.down))
        let row = Int(((point.y - top) / cellSize.height).rounded(.down))
        return (min(max(row, 0), max(rows - 1, 0)), min(max(col, 0), max(cols - 1, 0)))
    }
}
