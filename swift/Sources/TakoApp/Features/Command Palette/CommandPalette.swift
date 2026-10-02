import SwiftUI

struct CommandOption: Identifiable, Hashable {
    /// Unique identifier for this option.
    let id = UUID()
    /// The primary text displayed for this command.
    let title: String
    /// Secondary text displayed below the title.
    let subtitle: String?
    /// Tooltip text shown on hover.
    let description: String?
    /// Keyboard shortcut symbols to display.
    let symbols: [String]?
    /// SF Symbol name for the leading icon.
    let leadingIcon: String?
    /// Color for the leading indicator circle.
    let leadingColor: Color?
    /// Badge text displayed as a pill.
    let badge: String?
    /// Whether to visually emphasize this option.
    let emphasis: Bool
    /// Sort key for stable ordering when titles are equal.
    let sortKey: AnySortKey?
    /// The action to perform when this option is selected.
    let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        symbols: [String]? = nil,
        leadingIcon: String? = nil,
        leadingColor: Color? = nil,
        badge: String? = nil,
        emphasis: Bool = false,
        sortKey: AnySortKey? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.symbols = symbols
        self.leadingIcon = leadingIcon
        self.leadingColor = leadingColor
        self.badge = badge
        self.emphasis = emphasis
        self.sortKey = sortKey
        self.action = action
    }

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var options: [CommandOption]
    @State private var rawQuery = ""
    @State private var selectedIndex: UInt?
    @State private var hoveredOptionID: UUID?

    init(
        isPresented: Binding<Bool>,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor),
        options: [CommandOption],
        // Seeds `rawQuery`/`selectedIndex` without driving real keyboard
        // input through the hosted query TextField: both are private
        // @State, so nothing outside this file can otherwise set an
        // initial query or selection to exercise `filteredOptions`'
        // matching/sorting or `selectedOption`'s bounds handling.
        initialQuery: String = "",
        initialSelectedIndex: UInt? = nil
    ) {
        self._isPresented = isPresented
        self.backgroundColor = backgroundColor
        self.options = options
        self._rawQuery = State(initialValue: initialQuery)
        self._selectedIndex = State(initialValue: initialSelectedIndex)
    }

    var query: String {
        rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The options that we should show, taking into account any filtering from
    // the query. Options with matching leadingColor are ranked higher.
    var filteredOptions: [CommandOption] {
        if query.isEmpty {
            return options
        } else {
            // Filter by title/subtitle match OR color match
            let filtered = options.filter {
                $0.title.matchedIndices(for: query) != nil ||
                ($0.subtitle?.matchedIndices(for: query) != nil) ||
                colorMatchScore(for: $0.leadingColor, query: query) > 0
            }

            // Sort by color match score (higher scores first), then maintain original order
            return filtered.sorted { a, b in
                let scoreA = colorMatchScore(for: a.leadingColor, query: query)
                let scoreB = colorMatchScore(for: b.leadingColor, query: query)
                return scoreA > scoreB
            }
        }
    }

    var selectedOption: CommandOption? {
        guard let selectedIndex else { return nil }
        return if selectedIndex < filteredOptions.count {
            filteredOptions[Int(selectedIndex)]
        } else {
            filteredOptions.last
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TUIHeader(title: "Commands")
            CommandPaletteQuery(query: $rawQuery) { event in
                switch event {
                case .exit:
                    isPresented = false

                case .submit:
                    isPresented = false
                    selectedOption?.action()

                case .move(.up):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt(filteredOptions.count)
                    selectedIndex = (current == 0)
                        ? UInt(filteredOptions.count - 1)
                        : current - 1

                case .move(.down):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt.max
                    selectedIndex = (current >= UInt(filteredOptions.count - 1))
                        ? 0
                        : current + 1

                case .move:
                    // Unknown, ignore
                    break
                }
            }
            .onChange(of: query) { newValue in
                // If the user types a query then we want to make sure the first
                // value is selected. If the user clears the query and we were selecting
                // the first, we unset any selection.
                if !newValue.isEmpty {
                    if selectedIndex == nil {
                        selectedIndex = 0
                    }
                } else {
                    if let selectedIndex, selectedIndex == 0 {
                        self.selectedIndex = nil
                    }
                }
            }

            TUIRule()

            CommandTable(
                options: filteredOptions,
                query: query,
                selectedIndex: $selectedIndex,
                hoveredOptionID: $hoveredOptionID) { option in
                    isPresented = false
                    option.action()
            }

            TUIRule()
            Text("↑↓ select · ⏎ run · esc")
                .font(TUIFont.regular)
                .foregroundStyle(Color(nsColor: TakoTUI.dim))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: 560)
        // Drawn as the terminal UI is (see `TakoTUI`): Ink, a frame from
        // Rust to Ember with corners of half a cell.
        .background(Color(nsColor: TakoTUI.ink))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(LinearGradient(colors: [Color(nsColor: TakoTUI.rust), Color(nsColor: TakoTUI.ember)],
                                       startPoint: .leading, endPoint: .trailing), lineWidth: 1.25)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .padding()
        .environment(\.colorScheme, .dark)
        .tint(Color(nsColor: TakoTUI.ember))
        .onChange(of: isPresented) { newValue in
            if !newValue {
                // This is optional, since most of the time
                // there will be a delay before the next use.
                // To keep behavior the same as before, we reset it.
                rawQuery = ""
            }
        }
    }

    /// Returns a score (0.0 to 1.0) indicating how well a color matches a search query color name.
    /// Returns 0 if no color name in the query matches, or if the color is nil.
    private func colorMatchScore(for color: Color?, query: String) -> Double {
        guard let color = color else { return 0 }

        let queryLower = query.lowercased()
        let nsColor = NSColor(color)

        var bestScore: Double = 0
        for name in NSColor.colorNames {
            guard queryLower.contains(name),
                  let systemColor = NSColor(named: name) else { continue }

            let distance = nsColor.distance(to: systemColor)
            // Max distance in weighted RGB space is ~3.0, so normalize and invert
            // Use a threshold to determine "close enough" matches
            let maxDistance: Double = 1.5
            if distance < maxDistance {
                let score = 1.0 - (distance / maxDistance)
                bestScore = max(bestScore, score)
            }
        }

        return bestScore
    }
}

/// The text field for building the query for the command palette.
private struct CommandPaletteQuery: View {
    @Binding var query: String
    var onEvent: ((KeyboardEvent) -> Void)?
    @FocusState private var isTextFieldFocused: Bool

    init(query: Binding<String>, onEvent: ((KeyboardEvent) -> Void)? = nil) {
        _query = query
        self.onEvent = onEvent
    }

    enum KeyboardEvent {
        case exit
        case submit
        case move(MoveCommandDirection)
    }

    var body: some View {
        ZStack {
            Group {
                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.downArrow, modifiers: [])

                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("p"), modifiers: [.control])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("n"), modifiers: [.control])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                Text("› ")
                    .font(TUIFont.bold)
                    .foregroundStyle(Color(nsColor: TakoTUI.claw))
            TextField("", text: $query, prompt: Text("Run a command…").foregroundColor(Color(nsColor: TakoTUI.dim)))
                .font(TUIFont.regular)
                .foregroundStyle(Color(nsColor: TakoTUI.bright))
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
                .onChange(of: isTextFieldFocused) { focused in
                    if !focused {
                        onEvent?(.exit)
                    }
                }
                .onExitCommand { onEvent?(.exit) }
                .onMoveCommand { onEvent?(.move($0)) }
                .onSubmit { onEvent?(.submit) }
                .onAppear {
                    // Grab focus on the first appearance.
                    // Debug and Release build using Xcode 26.4,
                    // has same issue again
                    // SearchOverlay works magically as expected, I don't know
                    // why it's different here, but dispatching to next loop fixes it
                    DispatchQueue.main.async {
                        isTextFieldFocused = true
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
    }
}

private struct CommandTable: View {
    var options: [CommandOption]
    var query: String
    @Binding var selectedIndex: UInt?
    @Binding var hoveredOptionID: UUID?
    var action: (CommandOption) -> Void

    var body: some View {
        if options.isEmpty {
            Text("No matches")
                .font(TUIFont.regular)
                .foregroundStyle(Color(nsColor: TakoTUI.dim))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.1.id) { index, option in
                            CommandRow(
                                option: option,
                                query: query,
                                isSelected: {
                                    if let selected = selectedIndex {
                                        return selected == index ||
                                            (selected >= options.count &&
                                                index == options.count - 1)
                                    } else {
                                        return false
                                    }
                                }(),
                                hoveredID: $hoveredOptionID
                            ) {
                                action(option)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
                .onChange(of: selectedIndex) { _ in
                    guard let selectedIndex,
                          selectedIndex < options.count else { return }
                    proxy.scrollTo(
                        options[Int(selectedIndex)].id)
                }
            }
        }
    }
}

/// A single row in the command palette.
private struct CommandRow: View {
    let option: CommandOption
    var query: String
    var isSelected: Bool
    @Binding var hoveredID: UUID?
    var action: () -> Void

    private var highlightedTitle: Text {
        guard !query.isEmpty,
              let indices = option.title.matchedIndices(for: query) else {
            return Text(option.title)
                .font(isSelected || option.emphasis ? TUIFont.bold : TUIFont.regular)
        }

        var attributed = AttributedString(option.title)
        attributed[attributed.startIndex...].font = isSelected || option.emphasis ? TUIFont.bold : TUIFont.regular

        // Matched letters in Claw, bold; on the Ember selection, in Ink.
        for idx in indices {
            let offset = option.title.distance(from: option.title.startIndex, to: idx)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: 1)
            attributed[attrStart..<attrEnd].font = TUIFont.bold
            attributed[attrStart..<attrEnd].foregroundColor = isSelected ? Color(nsColor: TakoTUI.deep) : Color(nsColor: TakoTUI.claw)
        }

        return Text(attributed)
    }

    private func highlightedSubtitle(_ subtitle: String) -> Text {
        guard !query.isEmpty,
              option.title.matchedIndices(for: query) == nil,
              let indices = subtitle.matchedIndices(for: query) else {
            return Text(subtitle)
        }

        var attributed = AttributedString(subtitle)

        for idx in indices {
            let offset = subtitle.distance(from: subtitle.startIndex, to: idx)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: 1)
            attributed[attrStart..<attrEnd].font = TUIFont.bold
            attributed[attrStart..<attrEnd].foregroundColor = Color(nsColor: TakoTUI.claw)
        }

        return Text(attributed)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let color = option.leadingColor {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }

                if let icon = option.leadingIcon {
                    Image(systemName: icon)
                        .foregroundStyle(Color(nsColor: isSelected ? TakoTUI.deep : (option.emphasis ? TakoTUI.claw : TakoTUI.muted)))
                        .font(.system(size: 14, weight: .medium))
                }

                VStack(alignment: .leading, spacing: 0) {
                    highlightedTitle
                        .foregroundStyle(Color(nsColor: isSelected ? TakoTUI.deep : TakoTUI.text))

                    if let subtitle = option.subtitle {
                        highlightedSubtitle(subtitle)
                            .font(TUIFont.small)
                            .foregroundStyle(Color(nsColor: isSelected ? TakoTUI.ink : TakoTUI.dim))
                    }
                }

                Spacer()

                if let badge = option.badge, !badge.isEmpty {
                    Text(badge)
                        .font(TUIFont.small)
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: isSelected ? TakoTUI.ink : TakoTUI.field))
                        .foregroundStyle(Color(nsColor: TakoTUI.claw))
                }

                if let symbols = option.symbols {
                    ShortcutSymbolsView(symbols: symbols)
                        .font(TUIFont.regular)
                        .foregroundStyle(Color(nsColor: isSelected ? TakoTUI.deep : TakoTUI.muted))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            // A row of cells: the selection filled with Ember, a hovered
            // row on the selection colour -- no rounded corners.
            .background(
                isSelected
                    ? Color(nsColor: TakoTUI.ember)
                    : (hoveredID == option.id ? Color(nsColor: TakoTUI.selection) : Color.clear)
            )
        }
        .help(option.description ?? "")
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? option.id : nil
        }
    }
}

/// A row of Text representing a shortcut.
private struct ShortcutSymbolsView: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .frame(minWidth: 13)
            }
        }
    }
}

extension String {
    /// Returns the character indices that match `query`, trying a substring match first,
    /// then falling back to initials matching (first letter of each word).
    /// - Returns: `nil` if neither matches.
    func matchedIndices(for query: String) -> [String.Index]? {
        guard !query.isEmpty else { return nil }

        // Prefer substring match.
        if let range = self.range(of: query, options: .caseInsensitive) {
            return Array(self[range].indices)
        }

        // Fall back to initials match.
        let words = self.split(whereSeparator: \.isWhitespace)
        var queryIndex = query.startIndex
        var matched: [String.Index] = []

        for word in words {
            guard queryIndex < query.endIndex else { break }

            if word.first?.lowercased() == query[queryIndex].lowercased() {
                matched.append(word.startIndex)
                queryIndex = query.index(after: queryIndex)
            }
        }

        return queryIndex == query.endIndex ? matched : nil
    }
}

/// The terminal's font for the palette's terminal-style rows.
@MainActor
enum TUIFont {
    private static var theme: TerminalTheme? { (NSApp.delegate as? AppDelegate)?.tako.config.theme }
    static var regular: Font { Font(TakoTUI.font(theme)) }
    static var bold: Font { Font(TakoTUI.font(theme, bold: true)) }
    static var small: Font {
        let f = TakoTUI.font(theme)
        return Font(NSFont(descriptor: f.fontDescriptor, size: max(f.pointSize - 2, 10)) ?? f)
    }
}

/// `╭─ Title ╱╱╱╱╱─╮` without its frame: the title in Claw, then hatching
/// shaded from Rust to Ember to the edge.
struct TUIHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 0) {
            Text(" \(title) ")
                .font(TUIFont.bold)
                .foregroundStyle(Color(nsColor: TakoTUI.claw))
                .fixedSize()
            Text(String(repeating: "╱", count: 120))
                .font(TUIFont.regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(LinearGradient(colors: [Color(nsColor: TakoTUI.rust), Color(nsColor: TakoTUI.ember)],
                                                startPoint: .leading, endPoint: .trailing))
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

/// A rule between parts of a terminal-style panel: `├────┤` in the dim colour.
struct TUIRule: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: TakoTUI.dim).opacity(0.6))
            .frame(height: 1)
    }
}
