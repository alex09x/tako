import AppKit
import Foundation

/// A persistent record of a notification posted by or on behalf of a terminal pane.
public struct NotificationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var surfaceId: UUID
    public var paneTitle: String
    public var time: Date
    public var title: String
    public var body: String
    public var unread: Bool
    public var urgency: UInt8

    public init(
        id: String = UUID().uuidString,
        surfaceId: UUID,
        paneTitle: String,
        time: Date = Date(),
        title: String,
        body: String,
        unread: Bool = true,
        urgency: UInt8 = 1
    ) {
        self.id = id
        self.surfaceId = surfaceId
        self.paneTitle = paneTitle
        self.time = time
        self.title = title
        self.body = body
        self.unread = unread
        self.urgency = urgency
    }
}

extension Notification.Name {
    /// Posted when the notification store modifies records or unread states.
    public static let takoNotificationStoreDidChange = Notification.Name("takoNotificationStoreDidChange")
}

/// Centralized, persistent store for terminal notifications and their unread state (B4).
@MainActor
public final class NotificationStore: ObservableObject {
    public static let shared = NotificationStore()

    public static let userDefaultsKey = "tako.notification_records"

    /// Maximum notification history to retain.
    public var maxRecords: Int = 500

    @Published public private(set) var records: [NotificationRecord] = [] {
        didSet {
            saveToDefaults()
            updateDockBadge()
            NotificationCenter.default.post(name: .takoNotificationStoreDidChange, object: self)
            Tako.TabBarController.refreshAll()
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .tako) {
        self.defaults = defaults
        loadFromDefaults()
    }

    /// Loads persisted notification records from UserDefaults.
    public func loadFromDefaults() {
        guard let data = defaults.data(forKey: Self.userDefaultsKey) else { return }
        do {
            let decoder = JSONDecoder()
            let loaded = try decoder.decode([NotificationRecord].self, from: data)
            self.records = loaded
        } catch {
            Tako.logger.error("Failed to load notifications from defaults: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persists notification records to UserDefaults so unread state survives relaunch.
    public func saveToDefaults() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(records)
            defaults.set(data, forKey: Self.userDefaultsKey)
        } catch {
            Tako.logger.error("Failed to save notifications to defaults: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records an incoming notification.
    public func addNotification(
        id: String?,
        surfaceId: UUID,
        paneTitle: String,
        title: String,
        body: String,
        urgency: UInt8 = 1,
        unread: Bool = true,
        time: Date = Date()
    ) {
        let recordId = id?.isEmpty == false ? id! : UUID().uuidString

        // If a record with this id and surfaceId already exists, update it.
        if let idx = records.firstIndex(where: { $0.id == recordId && $0.surfaceId == surfaceId }) {
            records[idx].paneTitle = paneTitle
            records[idx].title = title
            records[idx].body = body
            records[idx].time = time
            records[idx].urgency = urgency
            records[idx].unread = unread
            return
        }

        let record = NotificationRecord(
            id: recordId,
            surfaceId: surfaceId,
            paneTitle: paneTitle,
            time: time,
            title: title,
            body: body,
            unread: unread,
            urgency: urgency
        )

        records.insert(record, at: 0)

        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
    }

    /// Marks all unread notifications for a specific surface as read.
    public func markRead(surfaceId: UUID) {
        var changed = false
        for idx in records.indices where records[idx].surfaceId == surfaceId && records[idx].unread {
            records[idx].unread = false
            changed = true
        }
        if changed {
            saveToDefaults()
            updateDockBadge()
            NotificationCenter.default.post(name: .takoNotificationStoreDidChange, object: self)
            Tako.TabBarController.refreshAll()
        }
    }

    /// Marks a specific notification record as read.
    public func markNotificationRead(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id && $0.unread }) else { return }
        records[idx].unread = false
    }

    /// Marks all unread notifications across all panes as read.
    public func markAllRead() {
        var changed = false
        for idx in records.indices where records[idx].unread {
            records[idx].unread = false
            changed = true
        }
        if changed {
            saveToDefaults()
            updateDockBadge()
            NotificationCenter.default.post(name: .takoNotificationStoreDidChange, object: self)
            Tako.TabBarController.refreshAll()
        }
    }

    /// Clears all recorded notifications.
    public func clear() {
        records.removeAll()
    }

    /// Returns the most recent unread notification record.
    public func latestUnread() -> NotificationRecord? {
        records.first(where: { $0.unread })
    }

    /// Number of unread notifications for a specific surface.
    public func unreadCount(for surfaceId: UUID) -> Int {
        records.reduce(0) { $0 + ($1.surfaceId == surfaceId && $1.unread ? 1 : 0) }
    }

    /// Total number of unread notifications across all surfaces.
    public func totalUnreadCount() -> Int {
        records.reduce(0) { $0 + ($1.unread ? 1 : 0) }
    }

    /// Records for a specific surface.
    public func records(for surfaceId: UUID) -> [NotificationRecord] {
        records.filter { $0.surfaceId == surfaceId }
    }

    /// Hook for observing dock badge updates in tests or headless mode.
    public var onDockBadgeUpdate: ((String?) -> Void)?

    /// Updates the dock badge label based on unread count or delegates to AppDelegate.
    public func updateDockBadge() {
        let unread = totalUnreadCount()
        let label = unread > 0 ? (unread > 99 ? "99+" : "\(unread)") : nil
        onDockBadgeUpdate?(label)
        if let appDelegate = NSApp?.delegate as? AppDelegate {
            appDelegate.setDockBadge()
        }
    }
}
