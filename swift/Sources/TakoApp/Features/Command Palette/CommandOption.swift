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
    /// Whether the command palette should dismiss automatically when this option is chosen.
    let dismissesOnAction: Bool
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
        dismissesOnAction: Bool = true,
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
        self.dismissesOnAction = dismissesOnAction
        self.action = action
    }

    static func == (lhs: CommandOption, rhs: CommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
