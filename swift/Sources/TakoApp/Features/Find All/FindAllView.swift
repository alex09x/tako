import AppKit
import SwiftUI

/// Find in All Tabs: a query field over every open terminal's scrollback
/// and screen, results grouped by terminal and, where the shell marked its
/// commands, by the command that printed them. Return shows the chosen match
/// in its tab; Option-Command-C copies the excerpt shown.
struct FindAllView: View {
    @ObservedObject var search: CrossSessionSearch
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)

    @State private var selected: Int?
    @FocusState private var fieldFocused: Bool

    /// Results in display order, with where each terminal's group starts.
    private var groups: [(first: Int, results: [CrossSearchResult])] {
        var out: [(first: Int, results: [CrossSearchResult])] = []
        var index = 0
        for result in search.results {
            if let last = out.indices.last, out[last].results.first?.surfaceID == result.surfaceID {
                out[last].results.append(result)
            } else {
                out.append((index, [result]))
            }
            index += 1
        }
        return out
    }

    private var selectedResult: CrossSearchResult? {
        selected.flatMap { search.results.indices.contains($0) ? search.results[$0] : nil }
    }

    var body: some View {
        let scheme: ColorScheme = OSColor(backgroundColor).isLightColor ? .light : .dark
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Group {
                    Button { move(-1) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { move(1) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    // Command-C stays the field's own copy.
                    Button { copySelected() } label: { Color.clear }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                TextField("Find in all tabs…", text: $search.query)
                    .padding()
                    .font(.system(size: 18, weight: .light))
                    .frame(height: 44)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onExitCommand { close() }
                    .onSubmit { open(selectedResult ?? search.results.first) }
                    .onAppear {
                        DispatchQueue.main.async { fieldFocused = true }
                        // Whatever was found last time may no longer be so.
                        search.refresh()
                    }
                    .onDisappear { search.cancel() }
            }

            if let line = statusLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            if !search.results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.first) { group in
                                header(for: group.results[0])
                                ForEach(Array(group.results.enumerated()), id: \.element.id) { offset, result in
                                    let previous = offset > 0 ? group.results[offset - 1].command?.key : nil
                                    if let command = result.command, command.key != previous {
                                        commandHeader(command)
                                    }
                                    row(result, index: group.first + offset, indented: result.command != nil)
                                        .id(group.first + offset)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selected) { index in
                        if let index { proxy.scrollTo(index) }
                    }
                }
            }
        }
        .frame(maxWidth: 640)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(backgroundColor).blendMode(.color)
            }
            .compositingGroup()
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75)))
        .shadow(radius: 32, x: 0, y: 12)
        .padding()
        .environment(\.colorScheme, scheme)
        .onChange(of: search.results) { _ in selected = search.results.isEmpty ? nil : 0 }
    }

    private var statusLine: String? {
        if let notice = search.notice { return notice }
        switch search.status {
        case .idle: return nil
        case .searching: return "Searching…"
        case .done(let more):
            let count = search.results.count
            if count == 0 { return "No matches" }
            let shown = count == 1 ? "1 match" : "\(count) matches"
            return more ? "\(shown) shown; there are more -- narrow the search" : shown
        }
    }

    private func header(for result: CrossSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text([result.place, result.pane].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.weight(.semibold))
            if let dir = result.currentDirectory {
                // The terminal's directory now, not where the line was printed.
                Text("now in \(dir)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// The command a run of matches came from: its line, how it ended, where
    /// and when it started -- only what the shell and the clock reported.
    private func commandHeader(_ command: CommandHeading) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(command.title)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(command.details())
                .font(.caption2)
                .foregroundStyle(outcomeColor(command.outcome))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal)
        .padding(.leading, 8)
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    private func outcomeColor(_ outcome: CommandHeading.Outcome) -> Color {
        switch outcome {
        case .failed: return .red
        case .succeeded: return .green
        default: return .secondary
        }
    }

    private func row(_ result: CrossSearchResult, index: Int, indented: Bool = false) -> some View {
        Text(highlighted(result.hit))
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.leading, indented ? 16 : 0)
            .padding(.vertical, 3)
            .background(index == selected ? Color.accentColor.opacity(0.3) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { open(result) }
            .contextMenu {
                // What the list shows -- up to about 120 characters around
                // the match, not necessarily the whole line.
                Button("Copy Excerpt") { copy(result) }
            }
    }

    /// The match this result stands for, marked within its context. The
    /// engine says which text it is; nothing is searched again here.
    private func highlighted(_ hit: FfiSearchHit) -> AttributedString {
        var matched = AttributedString(hit.matched)
        matched.font = .system(.body, design: .monospaced).bold()
        matched.backgroundColor = Color.yellow.opacity(0.35)
        return AttributedString(hit.before) + matched + AttributedString(hit.after)
    }

    private func move(_ step: Int) {
        guard !search.results.isEmpty else { return }
        let count = search.results.count
        selected = ((selected ?? (step > 0 ? -1 : count)) + step + count) % count
    }

    /// The panel stays until the match is selected, so a result that turned
    /// out stale leaves the notice and the refreshed list in view.
    private func open(_ result: CrossSearchResult?) {
        guard let result else { return }
        search.reveal(result) { selected in
            if selected { close() }
        }
    }

    private func copySelected() {
        if let result = selectedResult { copy(result) }
    }

    private func copy(_ result: CrossSearchResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.hit.before + result.hit.matched + result.hit.after, forType: .string)
    }

    private func close() {
        fieldFocused = false
        isPresented = false
    }
}
