/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

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
                    if let selectedOption {
                        if selectedOption.dismissesOnAction {
                            isPresented = false
                        }
                        selectedOption.action()
                    } else {
                        isPresented = false
                    }

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
                    if option.dismissesOnAction {
                        isPresented = false
                    }
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
                    LazyVStack(alignment: .leading, spacing: 0) {
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
