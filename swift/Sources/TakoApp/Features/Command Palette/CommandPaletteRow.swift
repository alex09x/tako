import SwiftUI

/// A single row in the command palette.
struct CommandRow: View {
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
struct ShortcutSymbolsView: View {
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
