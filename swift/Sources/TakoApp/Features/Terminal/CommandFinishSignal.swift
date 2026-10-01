import AppKit
import Foundation
import UserNotifications

extension Tako {
    /// Upstream's duration syntax: numbers with `ms`, `s`, `m` or `h`,
    /// combinable (`1m30s`); a bare number is seconds. Nil for anything else.
    static func parseDuration(_ text: String) -> Duration? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        // Past this many milliseconds a value is not a usable threshold,
        // and converting it would trap.
        let limit = Double(Int64.max / 2)
        func duration(_ ms: Double) -> Duration? {
            ms.isFinite && ms >= 0 && ms <= limit ? .milliseconds(Int64(ms)) : nil
        }
        if let seconds = Double(s) { return duration(seconds * 1000) }
        var total: Double = 0
        var number = ""
        var unit = ""
        var parsedAny = false
        func flush() -> Bool {
            guard let value = Double(number), value.isFinite, value >= 0 else { return false }
            let ms: Double
            switch unit {
            case "ms": ms = value
            case "s": ms = value * 1000
            case "m": ms = value * 60_000
            case "h": ms = value * 3_600_000
            default: return false
            }
            total += ms
            number = ""
            unit = ""
            parsedAny = true
            return true
        }
        for ch in s {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(ch)
            } else if ch.isLetter {
                guard !number.isEmpty else { return nil }
                unit.append(ch)
            } else {
                return nil
            }
        }
        guard !number.isEmpty, flush(), parsedAny else { return nil }
        return duration(total)
    }

    /// Whether a finished command should signal under
    /// `notify-on-command-finish`. Only commands whose start the shell
    /// marked count -- `ran` is nil otherwise -- and only those that lasted
    /// at least `after`.
    static func commandFinishShouldSignal(
        mode: Config.NotifyOnCommandFinish,
        ran: TimeInterval?,
        after: Duration,
        focused: Bool
    ) -> Bool {
        guard let ran else { return false }
        let threshold = Double(after.components.seconds) + Double(after.components.attoseconds) / 1e18
        guard ran >= threshold else { return false }
        switch mode {
        case .never: return false
        case .unfocused: return !focused
        case .always: return true
        }
    }

    /// The system notification for a finished command: whether it worked,
    /// how long it ran, and where.
    static func commandFinishContent(
        exitCode: Int32?,
        ran: TimeInterval,
        title: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if let exitCode, exitCode != 0 {
            content.title = "Command failed (exit \(exitCode))"
        } else {
            content.title = "Command finished"
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = ran >= 60 ? [.hour, .minute, .second] : [.second]
        let duration = formatter.string(from: ran.rounded()) ?? "\(Int(ran))s"
        content.body = title.isEmpty ? "after \(duration)" : "\(title) -- after \(duration)"
        return content
    }
}
