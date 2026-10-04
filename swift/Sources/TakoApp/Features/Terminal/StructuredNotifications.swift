import AppKit
import Foundation
import UserNotifications

extension Tako {
    public static let notificationIdKey = "notif_id"
    public static let notificationPaneTitleKey = "pane_title"
    public static let notificationPwdKey = "pwd"
    public static let notificationProjectKey = "project"
    public static let notificationCommandKey = "command"
    public static let notificationReportActivationKey = "report_activation"
    public static let notificationReportCloseKey = "report_close"
    public static let notificationFocusKey = "focus"
    public static let notificationUrgencyKey = "urgency"
    public static let notificationOnlyWhenUnfocusedKey = "only_unfocused"
    public static let notificationTimestampKey = "timestamp"
    public static let notificationCoalescedCountKey = "coalesced_count"

    /// Test hook for simulating macOS Focus / Do Not Disturb mode.
    public static var isFocusModeActive: () -> Bool = { false }

    /// Test hook for observing posted notification requests.
    public static var onNotificationPosted: ((UNNotificationRequest) -> Void)?

    /// Test hook for observing removed notification identifiers.
    public static var onNotificationRemoved: (([String]) -> Void)?

    /// Sanitizes notification text by removing C0 and C1 control characters and ANSI escape sequences,
    /// trimming whitespace, and capping length.
    public static func sanitizeNotificationText(_ text: String, maxLength: Int = 1024) -> String {
        var result = ""
        var chars = text.makeIterator()
        while let ch = chars.next() {
            if ch == "\u{1b}" {
                // Strip CSI / OSC sequences
                if let next = chars.next() {
                    if next == "[" {
                        while let c = chars.next(), !(c >= "@" && c <= "~") {}
                    } else if next == "]" {
                        while let c = chars.next(), c != "\u{07}" && c != "\\" {}
                    }
                }
                continue
            }
            let u = ch.unicodeScalars.first?.value ?? 0
            // Allow normal characters, newlines (0x0A), and tabs (0x09)
            if (u < 0x20 && u != 0x0a && u != 0x09) || (u >= 0x7f && u <= 0x9f) {
                continue
            }
            result.append(ch)
            if result.count >= maxLength {
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Derives a clean project name from a working directory path, falling back to pane title or "Terminal".
    public static func projectFromWorkingDirectory(_ pwd: String?, fallbackTitle: String = "Terminal") -> String {
        guard let pwd = pwd, !pwd.isEmpty else {
            return fallbackTitle.isEmpty ? "Terminal" : fallbackTitle
        }
        let url = URL(fileURLWithPath: pwd)
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" {
            return fallbackTitle.isEmpty ? "Terminal" : fallbackTitle
        }
        return last
    }

    /// Builds a rich UNMutableNotificationContent for a structured or standard notification.
    public static func buildNotificationContent(
        title: String,
        body: String,
        appName: String? = nil,
        surfaceId: UUID,
        paneTitle: String,
        pwd: String?,
        command: String?,
        id: String? = nil,
        urgency: UInt8 = 1,
        actions: [String] = [],
        reportActivation: Bool = false,
        focus: Bool = true,
        reportClose: Bool = false,
        onlyWhenUnfocused: Bool = false,
        coalescedCount: Int? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()

        let sanitizedTitle = sanitizeNotificationText(title)
        let sanitizedBody = sanitizeNotificationText(body)
        let project = projectFromWorkingDirectory(pwd, fallbackTitle: paneTitle)

        if let appName = appName, !appName.isEmpty {
            content.title = sanitizeNotificationText(appName)
            if !sanitizedTitle.isEmpty {
                content.subtitle = sanitizedTitle
            } else if let command = command, !command.isEmpty {
                content.subtitle = "\(project) — \(sanitizeNotificationText(command))"
            } else {
                content.subtitle = project
            }
        } else if !sanitizedTitle.isEmpty {
            content.title = sanitizedTitle
            if let command = command, !command.isEmpty {
                content.subtitle = "\(project) — \(sanitizeNotificationText(command))"
            } else {
                content.subtitle = project
            }
        } else {
            content.title = project
            if let command = command, !command.isEmpty {
                content.subtitle = sanitizeNotificationText(command)
            }
        }

        content.body = sanitizedBody

        if urgency == 2 {
            content.sound = .defaultCritical
        } else if urgency == 1 {
            content.sound = .default
        } else {
            content.sound = nil
        }

        if !actions.isEmpty {
            let catId = "tako-cat-\(id ?? UUID().uuidString)"
            let unActions = actions.enumerated().map { idx, btnTitle in
                UNNotificationAction(
                    identifier: "btn_\(idx + 1)",
                    title: sanitizeNotificationText(btnTitle),
                    options: [.foreground]
                )
            }
            let category = UNNotificationCategory(
                identifier: catId,
                actions: unActions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            if let center = AppDelegate.notificationCenterProvider() {
                center.getNotificationCategories { existing in
                    var updated = existing
                    updated.insert(category)
                    center.setNotificationCategories(updated)
                }
            }
            content.categoryIdentifier = catId
        } else {
            content.categoryIdentifier = Tako.userNotificationCategory
        }

        var userInfo: [AnyHashable: Any] = [
            Tako.notificationSurfaceKey: surfaceId.uuidString,
            Tako.notificationPaneTitleKey: paneTitle,
            Tako.notificationProjectKey: project,
            Tako.notificationUrgencyKey: urgency,
            Tako.notificationReportActivationKey: reportActivation,
            Tako.notificationFocusKey: focus,
            Tako.notificationReportCloseKey: reportClose,
            Tako.notificationOnlyWhenUnfocusedKey: onlyWhenUnfocused,
            Tako.notificationTimestampKey: Date().timeIntervalSince1970
        ]

        if let id = id {
            userInfo[Tako.notificationIdKey] = id
        }
        if let pwd = pwd {
            userInfo[Tako.notificationPwdKey] = pwd
        }
        if let command = command {
            userInfo[Tako.notificationCommandKey] = command
        }
        if let count = coalescedCount {
            userInfo[Tako.notificationCoalescedCountKey] = count
        }

        content.userInfo = userInfo
        return content
    }

    /// Evaluates whether a notification should be presented in the foreground,
    /// respecting macOS Focus and `only_when_unfocused`.
    public static func shouldPresent(
        userInfo: [AnyHashable: Any],
        surfaceLookedAt: Bool = false
    ) -> Bool {
        if userInfo[Tako.notificationFromControlKey] as? Bool == true {
            return true
        }

        let urgency = (userInfo[Tako.notificationUrgencyKey] as? UInt8) ?? 1

        if Tako.isFocusModeActive() && urgency < 2 {
            return false
        }

        let onlyWhenUnfocused = userInfo[Tako.notificationOnlyWhenUnfocusedKey] as? Bool ?? false
        if onlyWhenUnfocused && surfaceLookedAt {
            return false
        }
        if surfaceLookedAt && urgency == 0 {
            return false
        }

        if userInfo[Tako.notificationIdKey] != nil || userInfo[Tako.notificationUrgencyKey] != nil {
            return true
        }

        return false
    }

    /// Dispatches user activation or dismissal on a notification back to the pane surface.
    @MainActor
    public static func dispatchNotificationResponse(
        surface: SurfaceView,
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) {
        let notifId = userInfo[Tako.notificationIdKey] as? String
        let reportActivation = userInfo[Tako.notificationReportActivationKey] as? Bool ?? false
        let reportClose = userInfo[Tako.notificationReportCloseKey] as? Bool ?? false
        let shouldFocus = userInfo[Tako.notificationFocusKey] as? Bool ?? true

        if actionIdentifier == UNNotificationDismissActionIdentifier {
            if reportClose {
                let replyId = notifId ?? "0"
                let reply = "\u{1b}]99;i=\(replyId):p=close;\u{1b}\\"
                surface.writePtyReply(reply)
            }
            return
        }

        if shouldFocus {
            NSApp.activate(ignoringOtherApps: true)
            ControlLayout.focus(surface)
        }

        if reportActivation {
            let replyId = notifId ?? "0"
            var actionArg = ""
            if actionIdentifier.hasPrefix("btn_") {
                actionArg = String(actionIdentifier.dropFirst(4))
            }
            let reply = "\u{1b}]99;i=\(replyId);\(actionArg)\u{1b}\\"
            surface.writePtyReply(reply)
        }
    }

    @MainActor
    public static func dispatchNotificationResponse(
        surface: SurfaceView,
        response: UNNotificationResponse
    ) {
        dispatchNotificationResponse(
            surface: surface,
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
    }
}

/// Thread-safe rate limiter and coalescer for desktop notifications.
@MainActor
public final class NotificationCoalescer {
    public static let shared = NotificationCoalescer()

    public struct Record {
        public var lastTime: Date
        public var lastTitle: String
        public var lastBody: String
        public var burstCount: Int
        public var windowStart: Date
    }

    public var burstLimit: Int = 4
    public var burstWindow: TimeInterval = 1.0
    public var deduplicationWindow: TimeInterval = 2.0

    private var records: [UUID: Record] = [:]

    public func reset() {
        records.removeAll()
    }

    public enum Action: Equatable {
        case postNormal
        case duplicateSuppressed
        case coalesce(count: Int)
    }

    public func process(
        surfaceId: UUID,
        title: String,
        body: String,
        now: Date = Date()
    ) -> Action {
        if var rec = records[surfaceId] {
            if rec.lastTitle == title && rec.lastBody == body && now.timeIntervalSince(rec.lastTime) < deduplicationWindow {
                rec.lastTime = now
                records[surfaceId] = rec
                return .duplicateSuppressed
            }

            if now.timeIntervalSince(rec.windowStart) < burstWindow {
                rec.burstCount += 1
                rec.lastTime = now
                rec.lastTitle = title
                rec.lastBody = body
                records[surfaceId] = rec
                if rec.burstCount > burstLimit {
                    return .coalesce(count: rec.burstCount)
                }
                return .postNormal
            } else {
                rec.windowStart = now
                rec.burstCount = 1
                rec.lastTime = now
                rec.lastTitle = title
                rec.lastBody = body
                records[surfaceId] = rec
                return .postNormal
            }
        } else {
            records[surfaceId] = Record(
                lastTime: now,
                lastTitle: title,
                lastBody: body,
                burstCount: 1,
                windowStart: now
            )
            return .postNormal
        }
    }
}
