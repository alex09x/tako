import CoreGraphics
import CoreText
import Foundation

/// Draws a `TakoCore` terminal grid with CoreText.
///
/// This is the piece that lets Prod drop SwiftTerm and TakoKit: the Rust
/// core owns parsing and state, this owns pixels, and nothing in between is a
/// bridge. It draws into any `CGContext`, so the same code backs a
/// `UIView`/`NSView`, a SwiftUI `Canvas`, or an offscreen bitmap.
public struct TerminalRenderer {
    /// Cell metrics derived from the font, so the grid and the glyphs agree.
    public struct Metrics {
        public let cellWidth: CGFloat
        public let cellHeight: CGFloat
        /// Points from the bottom of a cell up to the text baseline.
        public let baseline: CGFloat
        public let font: CTFont
        /// Faces for SGR bold, italic and both. The regular face when the
        /// style is disabled or missing and may not be synthesised.
        public let boldFont: CTFont
        public let italicFont: CTFont
        public let boldItalicFont: CTFont
        /// Bold drawn by thickening a face that has no bold weight.
        public let boldIsSynthetic: Bool
        public let boldItalicIsSynthetic: Bool
        /// Points from the top of a cell down to the top of the underline.
        public let underlinePosition: CGFloat
        public let underlineThickness: CGFloat
        /// Whether `font-feature` settings apply, so a glyph has to be
        /// shaped rather than looked up in the character map.
        public let hasFontFeatures: Bool

        /// Slant given to a synthesised italic, as the font matrix's `c`.
        static let syntheticItalicSkew: CGFloat = 0.2

        /// Tako ships JetBrains Mono and falls back to the system
        /// monospace; do the same so text matches it where the font exists.
        public init(
            fontSize: CGFloat,
            fontName: String? = nil,
            cellWidth: CGFloat? = nil,
            cellHeight: CGFloat? = nil
        ) {
            self.init(theme: TerminalTheme(
                fontFamily: fontName,
                fontSize: fontSize,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            ))
        }

        public init(theme: TerminalTheme) {
            let fontSize = theme.fontSize
            let base = Self.resolveFont(named: theme.fontFamily, size: fontSize)
            let regular = Self.namedFace(theme.fontStyle, like: base) ?? base

            // A monospace advance is the same for every glyph; measure "M".
            let glyph = CTFontGetGlyphWithName(regular, "M" as CFString)
            var advance = CGSize.zero
            var glyphs = [glyph]
            CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyphs, &advance, 1)
            let ascent = CTFontGetAscent(regular)
            let descent = CTFontGetDescent(regular)
            let leading = CTFontGetLeading(regular)
            var width = ceil(advance.width)
            var height = ceil(ascent + descent + leading)
            if let cellWidth = theme.cellWidth, cellWidth.isFinite, cellWidth > 0 {
                width = cellWidth
            }
            if let cellHeight = theme.cellHeight, cellHeight.isFinite, cellHeight > 0 {
                height = cellHeight
            }
            var baseline = ceil(descent + leading)
            var underlinePosition = height - baseline + 1
            var underlineThickness: CGFloat = 1

            if let modifier = theme.adjustCellWidth {
                width = max(modifier.apply(to: width), 1)
            }
            if let modifier = theme.adjustCellHeight {
                // The text stays centred in the taller or shorter cell.
                let adjusted = max(modifier.apply(to: height), 1)
                let shift = ((adjusted - height) / 2).rounded(.down)
                baseline += shift
                underlinePosition += shift
                height = adjusted
            }
            if let modifier = theme.adjustFontBaseline {
                baseline = max(modifier.apply(to: baseline), 0)
            }
            if let modifier = theme.adjustUnderlinePosition {
                underlinePosition = max(modifier.apply(to: underlinePosition), 0)
            }
            if let modifier = theme.adjustUnderlineThickness {
                underlineThickness = max(modifier.apply(to: underlineThickness), 1)
            }
            self.cellWidth = width
            self.cellHeight = height
            self.baseline = baseline
            self.underlinePosition = underlinePosition
            self.underlineThickness = underlineThickness

            let synthetic = theme.fontSyntheticStyle
            let bold = Self.styledFace(
                traits: .traitBold, family: theme.fontFamilyBold, style: theme.fontStyleBold,
                regular: regular, synthesise: synthetic.contains(.bold))
            let italic = Self.styledFace(
                traits: .traitItalic, family: theme.fontFamilyItalic, style: theme.fontStyleItalic,
                regular: regular, synthesise: synthetic.contains(.italic))
            let boldItalic = Self.styledFace(
                traits: [.traitBold, .traitItalic], family: theme.fontFamilyBoldItalic,
                style: theme.fontStyleBoldItalic, regular: regular,
                synthesise: synthetic.contains(.boldItalic))

            let features = Self.featureDescriptor(theme.fontFeatures)
            func withFeatures(_ font: CTFont) -> CTFont {
                features.map { CTFontCreateCopyWithAttributes(font, fontSize, nil, $0) } ?? font
            }
            self.font = withFeatures(regular)
            self.boldFont = withFeatures(bold.font)
            self.italicFont = withFeatures(italic.font)
            self.boldItalicFont = withFeatures(boldItalic.font)
            self.boldIsSynthetic = bold.emboldened
            self.boldItalicIsSynthetic = boldItalic.emboldened
            self.hasFontFeatures = features != nil
        }

        /// The font `fontName` names, or the default chain when it is nil,
        /// Menlo when nothing matches.
        static func resolveFont(named fontName: String?, size fontSize: CGFloat) -> CTFont {
            let candidates = fontName.map { name in
                var candidates = [name, name + "-Regular"]
                // A common spelling of a family regular face is
                // "JetBrains Mono-Regular". It is neither that family's
                // PostScript name nor its full name, but its family is still
                // a valid CoreText request.
                if name.lowercased().hasSuffix("-regular") {
                    candidates.append(String(name.dropLast("-Regular".count)))
                }
                return candidates
            } ?? [
                // Upstream's default, bundled in Resources/fonts.
                "JetBrainsMonoNF-Regular",
                "JetBrainsMono-Regular",
                "JetBrains Mono",
                "SFMono-Regular",
                "Menlo",
            ]
            return firstMatch(candidates, size: fontSize)
                ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        }

        /// The first of `names` CoreText really has.
        private static func firstMatch(_ names: [String], size: CGFloat) -> CTFont? {
            for name in names {
                let candidate = CTFontCreateWithName(name as CFString, size, nil)
                // CTFontCreateWithName substitutes silently, so confirm we got
                // what we asked for before accepting it.
                if Self.matchesRequestedName(candidate, requested: name) {
                    return candidate
                }
            }
            return nil
        }

        /// The face `style` names in `font`'s family, or nil when the style
        /// is not a name or the family has no such face.
        static func namedFace(_ style: TerminalTheme.FontStyle, like font: CTFont) -> CTFont? {
            guard case .named(let name) = style else { return nil }
            let family = CTFontCopyFamilyName(font) as String
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontFamilyNameAttribute: family,
                kCTFontStyleNameAttribute: name,
            ] as CFDictionary)
            let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String, kCTFontStyleNameAttribute as String]
            guard let match = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatory as CFSet) else {
                return nil
            }
            let face = CTFontCreateWithFontDescriptor(match, CTFontGetSize(font), nil)
            let style = CTFontCopyName(face, kCTFontStyleNameKey).map { $0 as String } ?? ""
            guard normalizedFontName(CTFontCopyFamilyName(face) as String) == normalizedFontName(family),
                  normalizedFontName(style) == normalizedFontName(name) else { return nil }
            return face
        }

        /// The face for one SGR style: a named face, the family's own face
        /// with `traits`, a synthesised one, or `regular`.
        private static func styledFace(
            traits: CTFontSymbolicTraits,
            family: String?,
            style: TerminalTheme.FontStyle,
            regular: CTFont,
            synthesise: Bool
        ) -> (font: CTFont, emboldened: Bool) {
            if style == .disabled { return (regular, false) }
            let size = CTFontGetSize(regular)
            // An unknown family falls back to `font-family`'s.
            let base = family.flatMap { firstMatch([$0, $0 + "-Regular"], size: size) } ?? regular
            if let named = namedFace(style, like: base) { return (named, false) }
            if let face = traitFace(base, traits) { return (face, false) }
            guard synthesise else { return (regular, false) }

            let wantsBold = traits.contains(.traitBold)
            let wantsItalic = traits.contains(.traitItalic)
            // Bold-italic starts from whichever half the family does have.
            var font = base
            var emboldened = wantsBold
            var slanted = wantsItalic
            if wantsBold, wantsItalic {
                if let bold = traitFace(base, .traitBold) {
                    font = bold
                    emboldened = false
                } else if let italic = traitFace(base, .traitItalic) {
                    font = italic
                    slanted = false
                }
            }
            if slanted {
                var skew = CGAffineTransform(a: 1, b: 0, c: syntheticItalicSkew, d: 1, tx: 0, ty: 0)
                font = CTFontCreateCopyWithAttributes(font, size, &skew, nil)
            }
            return (font, emboldened)
        }

        /// `font`'s family face with `traits`, when the family has one.
        private static func traitFace(_ font: CTFont, _ traits: CTFontSymbolicTraits) -> CTFont? {
            guard let face = CTFontCreateCopyWithSymbolicTraits(font, CTFontGetSize(font), nil, traits, traits),
                  CTFontGetSymbolicTraits(face).contains(traits),
                  CTFontCopyFamilyName(face) as String == CTFontCopyFamilyName(font) as String else {
                return nil
            }
            return face
        }

        private static func featureDescriptor(_ features: [TerminalTheme.FontFeature]) -> CTFontDescriptor? {
            guard !features.isEmpty else { return nil }
            let settings = features.map {
                [kCTFontOpenTypeFeatureTag: $0.tag, kCTFontOpenTypeFeatureValue: $0.value] as [CFString: Any]
            }
            return CTFontDescriptorCreateWithAttributes(
                [kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
        }

        /// The face SGR `bold`/`italic` text is drawn with, and whether it
        /// is thickened at raster time.
        public func face(bold: Bool, italic: Bool) -> (font: CTFont, emboldened: Bool) {
            switch (bold, italic) {
            case (true, true): return (boldItalicFont, boldItalicIsSynthetic)
            case (true, false): return (boldFont, boldIsSynthetic)
            case (false, true): return (italicFont, false)
            case (false, false): return (font, false)
            }
        }

        /// `CTFontCreateWithName` accepts PostScript, family, and full names,
        /// but substitutes an unrelated system font for an unknown name. Check
        /// every documented identity CoreText may have used, not only the
        /// PostScript name of the selected regular face.
        private static func matchesRequestedName(_ font: CTFont, requested: String) -> Bool {
            let requested = normalizedFontName(requested)
            let identities = [
                CTFontCopyPostScriptName(font) as String,
                CTFontCopyFamilyName(font) as String,
                CTFontCopyFullName(font) as String,
            ]
            return identities.contains { normalizedFontName($0) == requested }
        }

        private static func normalizedFontName(_ name: String) -> String {
            name.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
                .lowercased()
        }
    }

    public let metrics: Metrics
    /// Colors used when the terminal says "default" and the host hasn't
    /// overridden them via OSC 10/11.
    public var defaultForeground: CGColor
    public var defaultBackground: CGColor
    /// Selection highlight; drawn under the glyphs so text stays readable.
    public var selectionColor: CGColor
    /// `selection-foreground`: color of selected text. Nil (the default)
    /// keeps each cell's own foreground.
    public var selectionForeground: CGColor?
    /// `selection-invert-fg-bg`: swap each selected cell's own foreground
    /// and background instead of overlaying `selectionColor`/
    /// `selectionForeground`.
    public var selectionInvertFgBg: Bool
    /// The cursor is ember by brand, whatever the palette is.
    public var cursorColor: CGColor
    /// `cursor-opacity`: the cursor's alpha, 0...1.
    public var cursorOpacity: Double
    /// `cursor-thickness`: bar/underline cursor thickness in points. Nil
    /// keeps this renderer's own default (2pt).
    public var cursorThickness: CGFloat?
    /// A pane that does not take the keys draws its cursor as an outline and
    /// dims its text, so which one is live is obvious without reading it.
    public var unfocused = false

    public init(
        metrics: Metrics,
        defaultForeground: CGColor = srgb(r: 0xed, g: 0xe6, b: 0xdf),
        defaultBackground: CGColor = srgb(r: 0x14, g: 0x10, b: 0x0e),
        selectionColor: CGColor = srgb(0.96, 0.35, 0.11, 0.3),
        selectionForeground: CGColor? = nil,
        selectionInvertFgBg: Bool = false,
        cursorColor: CGColor = srgb(r: 0xf4, g: 0x58, b: 0x1c),
        cursorOpacity: Double = 1.0,
        cursorThickness: CGFloat? = nil
    ) {
        self.metrics = metrics
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.selectionColor = selectionColor
        self.selectionForeground = selectionForeground
        self.selectionInvertFgBg = selectionInvertFgBg
        self.cursorColor = cursorColor
        self.cursorOpacity = cursorOpacity
        self.cursorThickness = cursorThickness
    }

    /// Pixel size of a `cols` x `rows` grid at these metrics.
    public func pixelSize(cols: Int, rows: Int) -> CGSize {
        CGSize(
            width: metrics.cellWidth * CGFloat(cols),
            height: metrics.cellHeight * CGFloat(rows)
        )
    }

    /// Draw a view's grid where `layout` puts it, with its margins filled as
    /// `window-padding-color` says. The caller has already cleared the view to
    /// its (possibly translucent) background; the context is left translated
    /// to the grid's bottom-left, so whatever the caller draws next -- marked
    /// text, Kitty images -- lands in grid coordinates too.
    ///
    /// `extend` repeats the edge cells' colours into the side margins, and
    /// into the top and bottom ones only when that edge row has no
    /// default-background cell (or on the alternate screen), so a prompt's
    /// colours do not bleed; `extendAlways` repeats them regardless.
    public func drawWindow(
        in context: CGContext,
        windowSize: CGSize,
        layout: TerminalGridLayout,
        paddingColor: TerminalTheme.WindowPaddingColor,
        alternateScreen: Bool = false,
        cols: Int,
        rows: Int,
        rowProvider: (Int) -> [TerminalCell],
        graphemes: [FfiGrapheme] = [],
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool,
        cursorStyle: FfiCursorStyle,
        selection: FfiSelectionRange? = nil
    ) {
        let gridSize = pixelSize(cols: cols, rows: rows)
        let bottomInset = max(0, windowSize.height - layout.top - gridSize.height)
        if paddingColor != .background, cols > 0, rows > 0 {
            drawMargins(
                in: context,
                windowSize: windowSize,
                left: layout.left,
                bottom: bottomInset,
                cols: cols,
                rows: rows,
                rowProvider: rowProvider,
                always: paddingColor == .extendAlways || alternateScreen
            )
        }
        context.translateBy(x: layout.left, y: bottomInset)
        draw(
            in: context, cols: cols, rows: rows, rowProvider: rowProvider, graphemes: graphemes,
            cursorRow: cursorRow, cursorCol: cursorCol, cursorVisible: cursorVisible,
            cursorStyle: cursorStyle, selection: selection
        )
    }

    /// The margin strips: each side strip takes its row's edge cell's
    /// colour, each top and bottom strip its column's edge-row colour. The
    /// corners stay the view's background.
    private func drawMargins(
        in context: CGContext,
        windowSize: CGSize,
        left: CGFloat,
        bottom: CGFloat,
        cols: Int,
        rows: Int,
        rowProvider: (Int) -> [TerminalCell],
        always: Bool
    ) {
        let gridSize = pixelSize(cols: cols, rows: rows)
        let right = max(0, windowSize.width - left - gridSize.width)
        let top = max(0, windowSize.height - bottom - gridSize.height)
        for row in 0..<rows {
            let cells = rowProvider(row)
            let y = bottom + CGFloat(rows - 1 - row) * metrics.cellHeight
            if left > 0, let color = marginColor(of: cells.first) {
                context.setFillColor(color)
                context.fill(CGRect(x: 0, y: y, width: left, height: metrics.cellHeight))
            }
            if right > 0, let color = marginColor(of: cells.last) {
                context.setFillColor(color)
                context.fill(CGRect(x: left + gridSize.width, y: y, width: right, height: metrics.cellHeight))
            }
        }
        for (row, y, height) in [(0, bottom + gridSize.height, top), (rows - 1, CGFloat(0), bottom)] where height > 0 {
            let cells = rowProvider(row)
            guard always || !cells.contains(where: { marginColor(of: $0) == nil }) else { continue }
            for (col, cell) in cells.prefix(cols).enumerated() {
                guard let color = marginColor(of: cell) else { continue }
                context.setFillColor(color)
                context.fill(CGRect(
                    x: left + CGFloat(col) * metrics.cellWidth, y: y, width: metrics.cellWidth, height: height
                ))
            }
        }
    }

    /// Draw the whole viewport. `rowProvider` returns one row of cells, which
    /// is exactly `TakoCore.viewportRow(row:)`; `graphemes` are the frame's
    /// clusters, drawn in place of their cells' first scalar.
    public func draw(
        in context: CGContext,
        cols: Int,
        rows: Int,
        rowProvider: (Int) -> [TerminalCell],
        graphemes: [FfiGrapheme] = [],
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool,
        cursorStyle: FfiCursorStyle,
        selection: FfiSelectionRange? = nil,
        skipBackgrounds: Bool = false
    ) {
        if !skipBackgrounds {
            let size = pixelSize(cols: cols, rows: rows)
            context.setFillColor(defaultBackground)
            context.fill(CGRect(origin: .zero, size: size))
        }

        // `selection-invert-fg-bg` swaps each selected cell's own colors
        // instead of overlaying a translucent selection color, so no
        // separate overlay is drawn in that mode.
        if let selection, !selectionInvertFgBg {
            drawSelection(selection, cols: cols, rows: rows, in: context)
        }

        var rowGraphemes: [Int: [Int: String]] = [:]
        for grapheme in graphemes {
            rowGraphemes[Int(grapheme.row), default: [:]][Int(grapheme.col)] = grapheme.text
        }
        for row in 0..<rows {
            let cells = rowProvider(row)
            let selectedColumns = selection.flatMap {
                Self.selectedColumnRange(for: row, selection: $0, cols: cols)
            }
            drawRow(
                cells, row: row, rows: rows, graphemes: rowGraphemes[row] ?? [:], in: context,
                skipBackground: skipBackgrounds, selectedColumns: selectedColumns
            )
        }

        if cursorVisible {
            drawCursor(
                in: context,
                row: cursorRow,
                col: cursorCol,
                rows: rows,
                style: cursorStyle
            )
        }
    }

    /// Draw a single row. Rendering row by row is what makes damage-driven
    /// redraw cheap: only rows in `takeDamage()` need this call.
    ///
    /// Glyphs are drawn as *runs* of identically-styled cells rather than
    /// cell by cell, which is what lets CoreText apply ligatures (`!=`,
    /// `=>`, `->` in Fira Code / JetBrains Mono) and shape scripts that need
    /// context. A monospace face keeps every advance equal, so a shaped run
    /// still lands on the grid. `graphemes` maps a column to the cluster its
    /// cell holds.
    public func drawRow(
        _ cells: [TerminalCell], row: Int, rows: Int, graphemes: [Int: String] = [:],
        in context: CGContext, skipBackground: Bool = false,
        selectedColumns: ClosedRange<Int>? = nil
    ) {
        // CoreGraphics origin is bottom-left; terminal row 0 is at the top.
        let y = CGFloat(rows - 1 - row) * metrics.cellHeight

        if !skipBackground {
            for run in backgroundRuns(for: cells, selectedColumns: selectedColumns) {
                context.setFillColor(run.color)
                context.fill(CGRect(
                    x: CGFloat(run.range.lowerBound) * metrics.cellWidth,
                    y: y,
                    width: CGFloat(run.range.count) * metrics.cellWidth,
                    height: metrics.cellHeight
                ))
            }
        }

        // Then text, as runs of cells sharing a style.
        var index = 0
        while index < cells.count {
            let style = effectiveStyle(cells[index], col: index, selectedColumns: selectedColumns)
            var text = ""
            var glyphs: [(col: Int, ch: String, wide: Bool)] = []
            let startCol = index
            while index < cells.count,
                  effectiveStyle(cells[index], col: index, selectedColumns: selectedColumns) == style {
                let cell = cells[index]
                // A wide glyph's tail carries no character of its own.
                if cell.ch != 0 {
                    let ch = cell.hasGrapheme
                        ? graphemes[index] ?? Self.string(for: cell.ch)
                        : Self.string(for: cell.ch)
                    text += ch
                    glyphs.append((col: index, ch: ch, wide: cell.wide))
                }
                index += 1
            }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || style.hasDecoration else {
                continue
            }
            drawRun(
                text,
                glyphs: glyphs,
                startCol: startCol,
                endCol: index,
                y: y,
                style: style,
                in: context
            )
        }
    }

    /// Everything that must match for two cells to shape as one run.
    private struct Style: Equatable {
        var fg: CGColor
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let underlineStyle: UInt8
        let ul: CGColor
        let strikethrough: Bool
        let overline: Bool
        let hidden: Bool

        init(_ cell: TerminalCell) {
            // SGR 7 swaps which resolved color is "the text": read the bg
            // triple instead of fg rather than touching the colors upstream.
            let (r, g, b) = cell.reverse
                ? (cell.bgR, cell.bgG, cell.bgB)
                : (cell.fgR, cell.fgG, cell.fgB)
            let alpha: CGFloat = cell.hidden ? 0 : (cell.dim ? 0.55 : 1)
            fg = srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, alpha)
            bold = cell.bold
            italic = cell.italic
            underline = cell.underline
            underlineStyle = cell.underlineStyle
            ul = srgb(CGFloat(cell.ulR) / 255, CGFloat(cell.ulG) / 255, CGFloat(cell.ulB) / 255, 1)
            strikethrough = cell.strikethrough
            overline = cell.overline
            hidden = cell.hidden
        }

        init(foreground: CGColor) {
            fg = foreground
            bold = false
            italic = false
            underline = false
            underlineStyle = 0
            ul = foreground
            strikethrough = false
            overline = false
            hidden = false
        }

        var hasDecoration: Bool { underline || strikethrough || overline }
    }

    /// `Style(cell)`, with the selection override for `col` applied on top:
    /// swapped fg/bg under `selection-invert-fg-bg`, or `selectionForeground`
    /// when set and not inverting. Neither set leaves the cell's own colors.
    private func effectiveStyle(_ cell: TerminalCell, col: Int, selectedColumns: ClosedRange<Int>?) -> Style {
        var style = Style(cell)
        guard let selectedColumns, selectedColumns.contains(col) else { return style }
        if selectionInvertFgBg {
            let (r, g, b) = cell.reverse
                ? (cell.fgR, cell.fgG, cell.fgB)
                : (cell.bgR, cell.bgG, cell.bgB)
            style.fg = srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, cell.hidden ? 0 : 1)
        } else if let selectionForeground {
            style.fg = selectionForeground
        }
        return style
    }

    /// The selected column span within `row`, or nil when `row` is not part
    /// of `selection`. Mirrors `drawSelection`'s own per-row bounds so a
    /// selected cell's text overrides land exactly where its highlight does.
    private static func selectedColumnRange(
        for row: Int, selection: FfiSelectionRange, cols: Int
    ) -> ClosedRange<Int>? {
        let r1 = Int(selection.startRow)
        let r2 = Int(selection.endRow)
        let startRow = min(r1, r2)
        let endRow = max(r1, r2)
        guard row >= startRow, row <= endRow else { return nil }
        let first: Int
        let last: Int
        switch selection.mode {
        case .linear:
            first = row == startRow ? Int(selection.startCol) : 0
            last = row == endRow ? Int(selection.endCol) : cols - 1
        case .rectangular:
            let c1 = Int(selection.startCol)
            let c2 = Int(selection.endCol)
            first = min(c1, c2)
            last = max(c1, c2)
        }
        guard last >= first else { return nil }
        return first...last
    }

    private func drawRun(
        _ text: String,
        glyphs: [(col: Int, ch: String, wide: Bool)],
        startCol: Int,
        endCol: Int,
        y: CGFloat,
        style: Style,
        in context: CGContext
    ) {
        let x = CGFloat(startCol) * metrics.cellWidth
        let width = CGFloat(endCol - startCol) * metrics.cellWidth

        if !text.isEmpty, !style.hidden {
            let baseline = y + metrics.baseline
            // Drawing the whole run at once is what lets CoreText apply
            // ligatures, but CoreText advances by the font's own metrics,
            // not by the terminal's grid. They agree for plain monospaced
            // text and diverge the moment a glyph comes from a fallback
            // font or is double-width -- box drawing and CJK both do -- and
            // then everything after it in the row is off by the difference.
            // So: shape the run, and keep it only if it still lands on the
            // grid. Otherwise place each glyph in its own cell.
            let line = makeLine(text, style: style)
            let measured = CTLineGetTypographicBounds(line, nil, nil, nil)
            let expected = glyphs.reduce(0.0) { $0 + ($1.wide ? 2 : 1) * Double(metrics.cellWidth) }
            if abs(measured - expected) < 0.5 {
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, context)
            } else {
                for glyph in glyphs {
                    drawFitted(glyph.ch, style: style,
                               col: glyph.col, cells: glyph.wide ? 2 : 1,
                               baseline: baseline, in: context)
                }
            }
        }

        if style.underline || style.underlineStyle > 0 {
            drawUnderline(
                style: style.underlineStyle,
                color: style.ul,
                x: x, y: y, width: width,
                in: context
            )
        }
        if style.strikethrough {
            context.setFillColor(style.fg)
            context.fill(CGRect(x: x, y: y + metrics.cellHeight / 2, width: width, height: 1))
        }
        if style.overline {
            context.setFillColor(style.fg)
            context.fill(CGRect(x: x, y: y + metrics.cellHeight - 1, width: width, height: 1))
        }
    }

    /// SGR 4:x underline styles: single, double, curly, dotted, dashed.
    private func drawUnderline(
        style: UInt8,
        color: CGColor,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        in context: CGContext
    ) {
        let thickness = metrics.underlineThickness
        // The line's bottom edge; `underlinePosition` is its top, from the
        // top of the cell.
        let base = y + metrics.cellHeight - metrics.underlinePosition - thickness
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(thickness)
        switch style {
        case 2:
            context.fill(CGRect(x: x, y: base, width: width, height: thickness))
            context.fill(CGRect(x: x, y: base - 3 * thickness, width: width, height: thickness))
        case 3:
            // A sine-ish wave, one period per cell, like a spell-check squiggle.
            let period = metrics.cellWidth / 2
            let amplitude: CGFloat = 1.5
            context.beginPath()
            context.move(to: CGPoint(x: x, y: base))
            var px = x
            var up = true
            while px < x + width {
                let next = min(px + period, x + width)
                context.addQuadCurve(
                    to: CGPoint(x: next, y: base),
                    control: CGPoint(x: (px + next) / 2, y: base + (up ? amplitude : -amplitude))
                )
                px = next
                up.toggle()
            }
            context.strokePath()
        case 4:
            var px = x
            while px < x + width {
                context.fill(CGRect(x: px, y: base, width: thickness, height: thickness))
                px += 2 * thickness
            }
        case 5:
            var px = x
            while px < x + width {
                context.fill(CGRect(x: px, y: base, width: 4, height: thickness))
                px += 7
            }
        default:
            context.fill(CGRect(x: x, y: base, width: width, height: thickness))
        }
    }

    /// Whether a glyph must fill its cell edge to edge.
    ///
    /// Box drawing and block elements have to meet their neighbours exactly
    /// or a line stops being a line, so those are stretched. Nothing else is:
    /// stretching a CJK glyph to fill two cells distorts the character, and
    /// the convention every terminal follows is to draw it at its natural
    /// size centred in the pair, blank margins and all.
    private func mustFillCell(_ ch: String) -> Bool {
        guard let scalar = ch.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x2500...0x259F,   // box drawing and block elements
             0x25A0...0x25A1,   // filled and hollow squares
             0xE0B0...0xE0D4:   // powerline separators
            return true
        default:
            return false
        }
    }

    /// Draw one glyph into the cells it owns.
    private func drawFitted(
        _ ch: String,
        style: Style,
        col: Int,
        cells: Int,
        baseline: CGFloat,
        in context: CGContext
    ) {
        let span = CGFloat(cells) * metrics.cellWidth
        let line = makeLine(ch, style: style)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = CGFloat(col) * metrics.cellWidth
        guard width > 0.01 else { return }

        if abs(width - span) < 0.5 {
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            return
        }

        guard mustFillCell(ch) else {
            // Centred at its natural size. The cells it owns stay its own,
            // so everything after it is still on the grid.
            context.textPosition = CGPoint(x: x + max((span - width) / 2, 0), y: baseline)
            CTLineDraw(line, context)
            return
        }

        // Scale the context around the cell's left edge, not the text
        // matrix: a scaled text matrix would move the origin as well and the
        // glyph would land somewhere else entirely.
        context.saveGState()
        context.translateBy(x: x, y: 0)
        context.scaleBy(x: span / width, y: 1)
        context.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Cells arrive as Unicode scalars, and a frame has tens of thousands of
    /// them. ASCII is nearly all of it in practice, so those come from a
    /// table instead of being built again for every cell of every frame.
    private static let ascii: [String] = (0..<128).map {
        String(UnicodeScalar(UInt8($0)))
    }

    public static func string(for scalar: UInt32) -> String {
        if scalar < 128 { return ascii[Int(scalar)] }
        guard let unicode = UnicodeScalar(scalar) else { return " " }
        return String(unicode)
    }

    private func makeLine(_ text: String, style: Style) -> CTLine {
        let face = metrics.face(bold: style.bold, italic: style.italic)
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: face.font,
            kCTForegroundColorAttributeName: style.fg,
        ]
        if face.emboldened {
            // A negative width fills and strokes, thickening every stem.
            let width = GlyphAtlas.syntheticBoldStrokeWidth(fontSize: CTFontGetSize(face.font))
            attributes[kCTStrokeWidthAttributeName] = -100 * width / CTFontGetSize(face.font)
            attributes[kCTStrokeColorAttributeName] = style.fg
        }
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes as CFDictionary
        )!
        return CTLineCreateWithAttributedString(attributed)
    }

    struct MarkedTextLayout: Equatable {
        struct Glyph: Equatable {
            let text: String
            let row: Int
            let col: Int
            let cells: Int
        }

        struct Line: Equatable {
            let row: Int
            let cellRange: Range<Int>
        }

        let glyphs: [Glyph]
        let lines: [Line]
    }

    /// Place a transient IME preedit in terminal cells.
    ///
    /// Unlike the upstream single-row preedit, this layout follows terminal
    /// wrapping: a glyph that no longer fits advances to column zero of the
    /// next row. If the preedit fills every row below the terminal cursor,
    /// retain the active tail and shift its visible row window upward.
    func markedTextLayout(
        _ text: String,
        cursorCol: Int,
        cols: Int,
        availableRows: Int
    ) -> MarkedTextLayout {
        guard cols > 0, availableRows > 0, !text.isEmpty else {
            return MarkedTextLayout(glyphs: [], lines: [])
        }

        let style = Style(foreground: defaultForeground)
        let source = text.map { character -> (text: String, cells: Int) in
            let grapheme = String(character)
            let measured = CGFloat(CTLineGetTypographicBounds(
                makeLine(grapheme, style: style), nil, nil, nil
            ))
            let cells = min(measured > metrics.cellWidth * 1.25 ? 2 : 1, cols)
            return (grapheme, cells)
        }
        let origin = min(max(cursorCol, 0), cols - 1)

        var logicalRow = 0
        var col = origin
        var positioned: [MarkedTextLayout.Glyph] = []
        positioned.reserveCapacity(source.count)
        for item in source {
            if col + item.cells > cols {
                logicalRow += 1
                col = 0
            }
            positioned.append(.init(
                text: item.text,
                row: logicalRow,
                col: col,
                cells: item.cells
            ))
            col += item.cells
        }

        guard let lastRow = positioned.last?.row else {
            return MarkedTextLayout(glyphs: [], lines: [])
        }
        let firstVisibleRow = max(0, lastRow - availableRows + 1)
        let glyphs = positioned.compactMap { glyph -> MarkedTextLayout.Glyph? in
            guard glyph.row >= firstVisibleRow else { return nil }
            return .init(
                text: glyph.text,
                row: glyph.row - firstVisibleRow,
                col: glyph.col,
                cells: glyph.cells
            )
        }

        var lines: [MarkedTextLayout.Line] = []
        for glyph in glyphs {
            let upperBound = glyph.col + glyph.cells
            if let last = lines.last, last.row == glyph.row {
                lines[lines.count - 1] = .init(
                    row: last.row,
                    cellRange: last.cellRange.lowerBound..<max(last.cellRange.upperBound, upperBound)
                )
            } else {
                lines.append(.init(row: glyph.row, cellRange: glyph.col..<upperBound))
            }
        }
        return MarkedTextLayout(glyphs: glyphs, lines: lines)
    }

    /// Draw in-progress IME composition using the same cell baseline and
    /// fitted glyph placement as committed terminal text. The ordinary
    /// terminal cursor is hidden by the host while this is present.
    public func drawMarkedText(
        _ text: String,
        cursorCol: Int,
        cols: Int,
        availableRows: Int,
        y: CGFloat,
        in context: CGContext
    ) {
        let layout = markedTextLayout(
            text,
            cursorCol: cursorCol,
            cols: cols,
            availableRows: availableRows
        )
        guard !layout.glyphs.isEmpty else { return }

        context.setFillColor(defaultBackground)
        for line in layout.lines {
            let lineY = y - CGFloat(line.row) * metrics.cellHeight
            let x = CGFloat(line.cellRange.lowerBound) * metrics.cellWidth
            let width = CGFloat(line.cellRange.count) * metrics.cellWidth
            context.fill(CGRect(x: x, y: lineY, width: width, height: metrics.cellHeight))
        }

        let style = Style(foreground: defaultForeground)
        for glyph in layout.glyphs {
            let baseline = y
                - CGFloat(glyph.row) * metrics.cellHeight
                + metrics.baseline
            drawFitted(
                glyph.text,
                style: style,
                col: glyph.col,
                cells: glyph.cells,
                baseline: baseline,
                in: context
            )
        }
        for line in layout.lines {
            let lineY = y - CGFloat(line.row) * metrics.cellHeight
            let x = CGFloat(line.cellRange.lowerBound) * metrics.cellWidth
            let width = CGFloat(line.cellRange.count) * metrics.cellWidth
            drawUnderline(
                style: 1,
                color: defaultForeground,
                x: x,
                y: lineY,
                width: width,
                in: context
            )
        }
    }

    /// Draw Kitty Graphics placements over the grid. The engine decodes and
    /// stores the images; this is the only place they become pixels.
    public func drawImages(
        _ placements: [FfiGraphicsPlacement],
        rows: Int,
        imageProvider: (UInt32) -> FfiStoredImage?,
        in context: CGContext
    ) {
        for placement in placements {
            guard let stored = imageProvider(placement.imageId),
                  let image = Self.makeImage(stored) else { continue }
            // A placement anchors at a cell; the image keeps its pixel size.
            let x = CGFloat(placement.col) * metrics.cellWidth
            let topY = CGFloat(rows - 1 - Int(placement.row)) * metrics.cellHeight
            let height = CGFloat(stored.height)
            let rect = CGRect(
                x: x,
                y: topY + metrics.cellHeight - height,
                width: CGFloat(stored.width),
                height: height
            )
            context.draw(image, in: rect)
        }
    }

    private static func makeImage(_ stored: FfiStoredImage) -> CGImage? {
        switch stored.format {
        case .png:
            guard let provider = CGDataProvider(data: Data(stored.pixels) as CFData) else {
                return nil
            }
            return CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        case .rgb, .rgba:
            let components = stored.format == .rgba ? 4 : 3
            let width = Int(stored.width)
            let height = Int(stored.height)
            guard width > 0, height > 0,
                  stored.pixels.count >= width * height * components,
                  let provider = CGDataProvider(data: Data(stored.pixels) as CFData) else {
                return nil
            }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8 * components,
                bytesPerRow: width * components,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: stored.format == .rgba
                    ? CGImageAlphaInfo.last.rawValue
                    : CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    /// Paint the selected span: full rows between the endpoints, partial
    /// rows at each end for linear, or min_col...max_col box for rectangular.
    private func drawSelection(
        _ selection: FfiSelectionRange,
        cols: Int,
        rows: Int,
        in context: CGContext
    ) {
        context.setFillColor(selectionColor)
        let r1 = Int(selection.startRow)
        let r2 = Int(selection.endRow)
        let startRow = min(r1, r2)
        let endRow = max(r1, r2)
        for row in startRow...endRow {
            guard row >= 0, row < rows else { continue }
            let first: Int
            let last: Int
            switch selection.mode {
            case .linear:
                first = row == startRow ? Int(selection.startCol) : 0
                last = row == endRow ? Int(selection.endCol) : cols - 1
            case .rectangular:
                let c1 = Int(selection.startCol)
                let c2 = Int(selection.endCol)
                first = min(c1, c2)
                last = max(c1, c2)
            }
            guard last >= first else { continue }
            let y = CGFloat(rows - 1 - row) * metrics.cellHeight
            context.fill(CGRect(
                x: CGFloat(first) * metrics.cellWidth,
                y: y,
                width: CGFloat(last - first + 1) * metrics.cellWidth,
                height: metrics.cellHeight
            ))
        }
    }

    private func drawCursor(
        in context: CGContext,
        row: Int,
        col: Int,
        rows: Int,
        style: FfiCursorStyle
    ) {
        let x = CGFloat(col) * metrics.cellWidth
        let y = CGFloat(rows - 1 - row) * metrics.cellHeight
        let thickness = cursorThickness ?? 2
        // Ember, not the foreground: the cursor is the one piece of terminal
        // chrome the brand owns, and a difference blend made it whatever
        // colour happened to be underneath.
        let fillColor = cursorColor.copy(alpha: CGFloat(cursorOpacity)) ?? cursorColor
        context.setFillColor(fillColor)
        switch style.shape {
        case .block:
            let cell = CGRect(x: x, y: y, width: metrics.cellWidth, height: metrics.cellHeight)
            if unfocused {
                // An unfocused pane shows an outline, so it is obvious at a
                // glance which one takes the keys.
                context.setStrokeColor(fillColor)
                context.setLineWidth(1)
                context.stroke(cell.insetBy(dx: 0.5, dy: 0.5))
            } else {
                context.fill(cell)
            }
        case .underline:
            context.fill(CGRect(x: x, y: y, width: metrics.cellWidth, height: thickness))
        case .bar:
            context.fill(CGRect(x: x, y: y, width: thickness, height: metrics.cellHeight))
        }
    }

    private func foreground(of cell: TerminalCell) -> CGColor {
        let alpha: CGFloat = cell.hidden ? 0 : (unfocused ? 0.75 : 1)
        return srgb(CGFloat(cell.fgR) / 255, CGFloat(cell.fgG) / 255, CGFloat(cell.fgB) / 255, alpha)
    }

    /// A cell's background for a margin, or nil for the default one: the
    /// view's own background already shows there, translucency included.
    private func marginColor(of cell: TerminalCell?) -> CGColor? {
        guard let color = background(of: cell), color != defaultBackground else { return nil }
        return color
    }

    private func background(of cell: TerminalCell?) -> CGColor? {
        guard let cell else { return nil }
        let (r, g, b) = cell.reverse
            ? (cell.fgR, cell.fgG, cell.fgB)
            : (cell.bgR, cell.bgG, cell.bgB)
        return srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1)
    }

    /// Same-color background runs, excluding the default frame clear.
    /// Within `selectedColumns`, `selection-invert-fg-bg` swaps in the
    /// cell's own (resolved) foreground as its background.
    public func backgroundRuns(
        for cells: [TerminalCell], selectedColumns: ClosedRange<Int>? = nil
    ) -> [(range: Range<Int>, color: CGColor)] {
        func color(at col: Int) -> CGColor? {
            guard col < cells.count else { return nil }
            let cell = cells[col]
            if selectionInvertFgBg, let selectedColumns, selectedColumns.contains(col) {
                let (r, g, b) = cell.reverse
                    ? (cell.bgR, cell.bgG, cell.bgB)
                    : (cell.fgR, cell.fgG, cell.fgB)
                return srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1)
            }
            return background(of: cell)
        }
        var runs: [(range: Range<Int>, color: CGColor)] = []
        var start = 0
        var runColor = color(at: 0)
        for col in 0...cells.count {
            let c = col < cells.count ? color(at: col) : nil
            if c != runColor || col == cells.count {
                if let runColor, runColor != defaultBackground { runs.append((start..<col, runColor)) }
                start = col
                runColor = c
            }
        }
        return runs
    }

}
