import AppKit
import SwiftUI
import TakoKit

/// Full-window overview of every pane across tabs and windows as live thumbnails, coloured by status (B6).
///
/// Features:
/// - Real-time live status updates reflecting immediately on pane cards.
/// - Type-to-filter by title, working directory, or status.
/// - Keyboard navigation: Arrow keys to navigate, Return to jump, Escape to close.
/// - Fast opening meeting the < 150 ms budget for 30 panes.
struct PaneOverviewView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)

    @ObservedObject private var store = PaneOverviewStore.shared
    @FocusState private var isSearchFieldFocused: Bool

    // Grid layout: responsive adaptive columns
    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 16)
    ]

    init(
        isPresented: Binding<Bool>,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    ) {
        self._isPresented = isPresented
        self.backgroundColor = backgroundColor
    }

    var body: some View {
        ZStack {
            // Semi-transparent backdrop dismissing overview on click
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                }

            // Hidden buttons for reliable AppKit keyboard shortcuts
            ZStack {
                Group {
                    Button { store.selectPrevious(cols: 1) } label: { Color.clear }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { store.selectNext(cols: 1) } label: { Color.clear }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button { store.selectPrevious(cols: 2) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { store.selectNext(cols: 2) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { handleReturn() } label: { Color.clear }
                        .keyboardShortcut(.return, modifiers: [])
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                // Main Content Modal
                VStack(spacing: 0) {
                    headerView
                    Divider().background(Color(nsColor: Palette.hairline))
                    contentGridView
                    Divider().background(Color(nsColor: Palette.hairline))
                    footerLegendView
                }
                .frame(maxWidth: 1100, maxHeight: 760)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: Palette.modalBackground))
                        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: Palette.modalBorder), lineWidth: 1)
                )
                .padding(32)
            }
        }
        .onAppear {
            store.refresh()
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
        .onDisappear {
            store.stopObserving()
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return) {
            handleReturn()
            return .handled
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(nsColor: Tako.Brand.ember))

            Text("Pane Overview")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(Color(nsColor: Palette.activeText))

            Spacer()

            // Search filter field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(nsColor: Palette.dim))

                TextField("Filter by title, directory, or status…", text: $store.filterText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13, design: .monospaced))
                    .focused($isSearchFieldFocused)
                    .frame(minWidth: 260)

                if !store.filterText.isEmpty {
                    Button(action: { store.filterText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: Palette.dim))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: Palette.searchBackground))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: Palette.hairline), lineWidth: 1)
            )

            // Pane Count Badge
            let total = store.items.count
            let showing = store.filteredItems.count
            Text(showing == total ? "\(total) panes" : "\(showing) of \(total)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: Palette.badge))
                .foregroundColor(Color(nsColor: Palette.dim))
                .clipShape(Capsule())

            // Close button
            Button(action: { close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(nsColor: Palette.dim))
                    .padding(6)
                    .background(Color(nsColor: Palette.buttonBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Grid

    private var contentGridView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let currentItems = store.filteredItems
                if currentItems.isEmpty {
                    emptyStateView
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(currentItems.enumerated()), id: \.element.id) { index, item in
                            paneCard(item: item, isSelected: index == store.selectedIndex)
                                .id(index)
                                .onTapGesture {
                                    store.selectedIndex = index
                                    jump(to: item)
                                }
                        }
                    }
                    .padding(20)
                }
            }
            .onChange(of: store.selectedIndex) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(store.selectedIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Pane Card

    private func paneCard(item: PaneOverviewItem, isSelected: Bool) -> some View {
        let statusColor = Color(nsColor: item.statusColor)

        return VStack(alignment: .leading, spacing: 10) {
            // Card Top Row: Status badge and window/tab provenance
            HStack(spacing: 8) {
                // Status Pill
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(item.statusLabel.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(statusColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.15))
                .clipShape(Capsule())

                if let text = item.statusText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(nsColor: Palette.dim))
                        .lineLimit(1)
                }

                Spacer()

                // Window / Tab provenance tag
                Text("Tab \(item.tabIndex + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.dim))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: Palette.badge))
                    .cornerRadius(4)
            }

            // Pane Title
            Text(item.title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(nsColor: Palette.activeText))
                .lineLimit(1)

            // Live Thumbnail: Terminal Output Preview
            thumbnailView(item: item)

            // Card Footer: Working directory & running elapsed time
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: Palette.dim))

                Text(item.directoryDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.dim))
                    .lineLimit(1)

                Spacer()

                if let elapsed = item.elapsed {
                    Text(elapsed)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(nsColor: Tako.Brand.ember))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: Palette.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color(nsColor: Tako.Brand.ember) : statusColor.opacity(0.85),
                    lineWidth: isSelected ? 2.5 : 1.5
                )
        )
        .shadow(
            color: isSelected ? Color(nsColor: Tako.Brand.ember).opacity(0.35) : statusColor.opacity(0.15),
            radius: isSelected ? 8 : 4,
            x: 0,
            y: 2
        )
        .contentShape(Rectangle())
    }

    // MARK: - Thumbnail View

    private func thumbnailView(item: PaneOverviewItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if item.thumbnailLines.isEmpty {
                Text("~ $")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.dim))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(item.thumbnailLines.prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(nsColor: Palette.terminalText))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)

            // Progress bar if active
            if item.progressState != .none {
                progressBarView(state: item.progressState, value: item.progressValue)
                    .frame(height: 3)
                    .padding(.top, 4)
            }
        }
        .padding(8)
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: Palette.terminalBackground))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: Palette.hairline), lineWidth: 0.5)
        )
    }

    private func progressBarView(state: TakoTerminalNSView.ProgressState, value: Int?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let color: Color = switch state {
            case .normal: Color(nsColor: Tako.Brand.ok)
            case .error: Color(nsColor: Tako.Brand.error)
            case .paused: Color(nsColor: Tako.Brand.ember)
            case .indeterminate: Color(nsColor: Tako.Brand.ember)
            case .none: Color.clear
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.2))

                let fraction = min(max(Double(value ?? (state == .indeterminate ? 50 : 0)) / 100.0, 0.05), 1.0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: width * CGFloat(fraction))
            }
        }
    }

    // MARK: - Footer Legend

    private var footerLegendView: some View {
        HStack(spacing: 16) {
            legendItem(key: "↑/↓/←/→", description: "Navigate")
            legendItem(key: "↵", description: "Jump to Pane")
            legendItem(key: "esc", description: "Close")

            Spacer()

            if let selected = store.selectedItem {
                Text("Selected: \(selected.title)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.activeText))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func legendItem(key: String, description: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: Palette.badge))
                .foregroundColor(Color(nsColor: Palette.activeText))
                .cornerRadius(4)

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Palette.dim))
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(Color(nsColor: Palette.dim))

            Text("No panes found matching '\(store.filterText)'")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(nsColor: Palette.activeText))

            Button("Clear Filter") {
                store.filterText = ""
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - Actions

    private func handleReturn() {
        if let selected = store.selectedItem {
            jump(to: selected)
        }
    }

    private func jump(to item: PaneOverviewItem) {
        store.jump(to: item)
        isPresented = false
    }

    private func close() {
        store.stopObserving()
        isPresented = false
    }

    // MARK: - Theme Palette

    private enum Palette {
        static let modalBackground = NSColor(srgbRed: 0x1A / 255, green: 0x16 / 255, blue: 0x14 / 255, alpha: 0.98)
        static let modalBorder = NSColor(srgbRed: 0x36 / 255, green: 0x30 / 255, blue: 0x2B / 255, alpha: 1)
        static let cardBackground = NSColor(srgbRed: 0x22 / 255, green: 0x1D / 255, blue: 0x1A / 255, alpha: 1)
        static let terminalBackground = NSColor(srgbRed: 0x12 / 255, green: 0x0F / 255, blue: 0x0D / 255, alpha: 1)
        static let terminalText = NSColor(srgbRed: 0xD6 / 255, green: 0xCF / 255, blue: 0xC7 / 255, alpha: 1)
        static let activeText = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
        static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
        static let hairline = NSColor(srgbRed: 0x2E / 255, green: 0x28 / 255, blue: 0x24 / 255, alpha: 1)
        static let searchBackground = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
        static let badge = NSColor(srgbRed: 0x2D / 255, green: 0x26 / 255, blue: 0x22 / 255, alpha: 1)
        static let buttonBackground = NSColor(srgbRed: 0x2D / 255, green: 0x26 / 255, blue: 0x22 / 255, alpha: 1)
    }
}
