import Foundation

/// A terminal event emitted by Tako to streaming subscribers (`takoctl events`).
struct TerminalEvent: Sendable, Equatable {
    let cursor: UInt64
    let timestamp: Double
    let type: String
    let pane: String?
    let tab: String?
    let window: String?
    let workspace: String?
    let payload: [String: JSON]

    init(
        cursor: UInt64,
        timestamp: Double = Date().timeIntervalSince1970,
        type: String,
        pane: String? = nil,
        tab: String? = nil,
        window: String? = nil,
        workspace: String? = "default",
        payload: [String: JSON] = [:]
    ) {
        self.cursor = cursor
        self.timestamp = timestamp
        self.type = type
        self.pane = pane?.lowercased()
        self.tab = tab
        self.window = window
        self.workspace = workspace
        self.payload = payload
    }

    /// Serializes the event as a single newline-delimited JSON line.
    func encoded() -> Data {
        var dict: [String: Any] = [
            "cursor": cursor,
            "timestamp": timestamp,
            "type": type,
        ]
        if let pane { dict["pane"] = pane }
        if let tab { dict["tab"] = tab }
        if let window { dict["window"] = window }
        if let workspace { dict["workspace"] = workspace }

        var dataDict: [String: Any] = [:]
        for (k, v) in payload {
            dict[k] = v.any
            dataDict[k] = v.any
        }
        dict["data"] = dataDict

        if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            var line = jsonData
            line.append(0x0A) // \n
            return line
        }

        // Fallback simple line
        return Data("{\"cursor\":\(cursor),\"timestamp\":\(timestamp),\"type\":\"\(type)\"}\n".utf8)
    }

    /// Checks if this event matches the subscriber's filter criteria.
    func matches(
        paneFilter: String?,
        tabFilter: String?,
        workspaceFilter: String?,
        typeFilter: Set<String>?
    ) -> Bool {
        if let typeFilter, !typeFilter.isEmpty {
            let matched = typeFilter.contains(type) ||
                          typeFilter.contains(type.lowercased()) ||
                          typeFilter.contains(where: { $0.caseInsensitiveCompare(type) == .orderedSame })
            if !matched { return false }
        }
        if let paneFilter, !paneFilter.isEmpty {
            guard let pane else { return false }
            let target = paneFilter.lowercased()
            if pane != target && !pane.starts(with: target) {
                return false
            }
        }
        if let tabFilter, !tabFilter.isEmpty {
            guard let tab else { return false }
            let target = tabFilter.lowercased()
            if tab.lowercased() != target && !tab.lowercased().starts(with: target) {
                return false
            }
        }
        if let workspaceFilter, !workspaceFilter.isEmpty {
            guard let workspace, workspace.caseInsensitiveCompare(workspaceFilter) == .orderedSame else { return false }
        }
        return true
    }
}
