import AppKit
import SwiftUI

/// Per-window panel listing notifications with pane, time and text (B4).
/// Allows navigating notifications, jumping to the corresponding pane with Return/click,
/// and marking notifications read.
public struct NotificationCenterView: View {
    @ObservedObject var store: NotificationStore = .shared
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)

    @State private var selectedIndex: Int?
    @FocusState private var isPanelFocused: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    public init(
        isPresented: Binding<Bool>,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor),
        store: NotificationStore = .shared
    ) {
        self._isPresented = isPresented
        self.backgroundColor = backgroundColor
        self.store = store
    }

    public var body: some View {
        let scheme: ColorScheme = OSColor(backgroundColor).isLightColor ? .light : .dark

        VStack(alignment: .leading, spacing: 0) {
            // Hidden buttons for keyboard navigation
            ZStack {
                Group {
                    Button { moveSelection(-1) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { moveSelection(1) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { store.markAllRead() } label: { Color.clear }
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                // Header
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .foregroundColor(Color(nsColor: Tako.Brand.ember))

                    Text("Notifications")
                        .font(.headline)

                    let unreadCount = store.totalUnreadCount()
                    if unreadCount > 0 {
                        Text("\(unreadCount) unread")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: Tako.Brand.ember).opacity(0.2))
                            .foregroundColor(Color(nsColor: Tako.Brand.ember))
                            .clipShape(Capsule())
                    } else {
                        Text("All caught up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if unreadCount > 0 {
                        Button("Mark All Read") {
                            store.markAllRead()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    if !store.records.isEmpty {
                        Button("Clear") {
                            store.clear()
                            selectedIndex = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Close (Esc)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider()

            if store.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No Notifications")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(store.records.enumerated()), id: \.element.id) { index, record in
                                notificationRow(record, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        selectedIndex = index
                                        jumpToRecord(record)
                                    }

                                if index < store.records.count - 1 {
                                    Divider()
                                        .padding(.leading, 32)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selectedIndex) { idx in
                        if let idx { proxy.scrollTo(idx) }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("↑/↓ Navigate · ⏎ Jump to Pane · Esc Close")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.1))
        }
        .frame(maxWidth: 580)
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
        .onExitCommand { close() }
        .onSubmit {
            if let idx = selectedIndex, store.records.indices.contains(idx) {
                jumpToRecord(store.records[idx])
            } else if let first = store.records.first {
                jumpToRecord(first)
            }
        }
        .onAppear {
            if selectedIndex == nil && !store.records.isEmpty {
                selectedIndex = store.records.firstIndex(where: { $0.unread }) ?? 0
            }
        }
    }

    private func notificationRow(_ record: NotificationRecord, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Unread indicator dot
            Circle()
                .fill(record.unread ? Color(nsColor: Tako.Brand.claw) : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.paneTitle.isEmpty ? "Terminal" : record.paneTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(record.unread ? .primary : .secondary)

                    if record.urgency == 2 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }

                    Spacer()

                    Text(formattedTime(record.time))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !record.title.isEmpty {
                    Text(record.title)
                        .font(.subheadline.weight(record.unread ? .bold : .medium))
                        .foregroundColor(record.unread ? .primary : .secondary)
                }

                if !record.body.isEmpty {
                    Text(record.body)
                        .font(.callout)
                        .foregroundStyle(record.unread ? .primary : .secondary)
                        .lineLimit(3)
                }
            }
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
    }

    private func formattedTime(_ date: Date) -> String {
        let elapsed = abs(date.timeIntervalSinceNow)
        if elapsed < 60 {
            return "just now"
        } else if elapsed < 3600 * 24 {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        } else {
            return Self.timeFormatter.string(from: date)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !store.records.isEmpty else { return }
        let count = store.records.count
        selectedIndex = ((selectedIndex ?? (delta > 0 ? -1 : count)) + delta + count) % count
    }

    private func jumpToRecord(_ record: NotificationRecord) {
        if let surface = findSurface(for: record.surfaceId) {
            NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: surface)
            store.markRead(surfaceId: record.surfaceId)
            close()
        } else {
            // Surface may have closed; mark as read anyway
            store.markNotificationRead(id: record.id)
        }
    }

    private func findSurface(for id: UUID) -> Tako.SurfaceView? {
        for controller in TerminalController.all {
            if let surface = controller.surfaceTree.first(where: { $0.id == id }) {
                return surface
            }
        }
        return nil
    }

    private func close() {
        isPresented = false
    }
}
