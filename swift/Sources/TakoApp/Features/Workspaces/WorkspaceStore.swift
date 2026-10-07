import AppKit
import Foundation

extension Notification.Name {
    public static let takoWorkspaceDidChange = Notification.Name("TakoWorkspaceDidChange")
}

/// Central store for project workspaces (C1).
/// Manages workspace metadata, tab assignments, tab order, and attention aggregation.
@MainActor
public final class WorkspaceStore: ObservableObject {
    public static let shared = WorkspaceStore()

    public static let defaultWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Published public private(set) var workspaces: [Workspace] = []
    @Published public var activeWorkspaceId: UUID {
        didSet {
            if oldValue != activeWorkspaceId {
                save()
                NotificationCenter.default.post(name: .takoWorkspaceDidChange, object: self)
            }
        }
    }

    private let storeURL: URL
    private var isTesting: Bool = false

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundle = Bundle.main.bundleIdentifier ?? "com.alex09x.tako"
        return base.appendingPathComponent(bundle).appendingPathComponent("Workspaces", isDirectory: true)
    }

    public init(storeURL: URL? = nil, isTesting: Bool = false) {
        self.isTesting = isTesting
        let targetURL = storeURL ?? Self.defaultDirectory.appendingPathComponent("workspaces.json")
        self.storeURL = targetURL
        self.activeWorkspaceId = Self.defaultWorkspaceId

        load()
    }

    // MARK: - Properties

    public var activeWorkspace: Workspace {
        workspace(for: activeWorkspaceId) ?? workspaces.first ?? makeDefaultWorkspace()
    }

    public func workspace(for id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    public func workspace(named name: String) -> Workspace? {
        workspaces.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func workspace(forTab tabIdentifier: String) -> Workspace? {
        workspaces.first { $0.tabIdentifiers.contains(tabIdentifier) }
    }

    // MARK: - Workspace Operations

    @discardableResult
    public func createWorkspace(
        name: String,
        rootDirectory: String? = nil,
        color: String? = nil,
        icon: String? = nil
    ) -> Workspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Workspace \(workspaces.count + 1)" : trimmed

        // De-duplicate name if needed
        var uniqueName = finalName
        var counter = 2
        while workspace(named: uniqueName) != nil {
            uniqueName = "\(finalName) \(counter)"
            counter += 1
        }

        let newWs = Workspace(
            id: UUID(),
            name: uniqueName,
            rootDirectory: rootDirectory,
            color: color ?? "blue",
            icon: icon ?? "folder"
        )
        workspaces.append(newWs)
        save()
        NotificationCenter.default.post(name: .takoWorkspaceDidChange, object: self)
        return newWs
    }

    public func updateWorkspace(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index] = workspace
        save()
        NotificationCenter.default.post(name: .takoWorkspaceDidChange, object: self)
    }

    @discardableResult
    public func deleteWorkspace(id: UUID) -> Bool {
        guard id != Self.defaultWorkspaceId, workspaces.count > 1 else { return false }
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return false }

        let removed = workspaces.remove(at: index)

        // Reassign any orphaned tabs to the default workspace
        if !removed.tabIdentifiers.isEmpty, let defaultIndex = workspaces.firstIndex(where: { $0.id == Self.defaultWorkspaceId }) {
            workspaces[defaultIndex].tabIdentifiers.append(contentsOf: removed.tabIdentifiers)
        }

        if activeWorkspaceId == id {
            activeWorkspaceId = Self.defaultWorkspaceId
        }

        save()
        NotificationCenter.default.post(name: .takoWorkspaceDidChange, object: self)
        return true
    }

    @discardableResult
    public func switchWorkspace(to id: UUID) -> Bool {
        guard workspace(for: id) != nil else { return false }
        guard activeWorkspaceId != id else { return true }
        activeWorkspaceId = id
        return true
    }

    @discardableResult
    public func switchWorkspace(named name: String) -> Bool {
        guard let ws = workspace(named: name) else { return false }
        return switchWorkspace(to: ws.id)
    }

    public func nextWorkspace() {
        guard workspaces.count > 1 else { return }
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == activeWorkspaceId }) else {
            activeWorkspaceId = workspaces[0].id
            return
        }
        let nextIndex = (currentIndex + 1) % workspaces.count
        activeWorkspaceId = workspaces[nextIndex].id
    }

    public func previousWorkspace() {
        guard workspaces.count > 1 else { return }
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == activeWorkspaceId }) else {
            activeWorkspaceId = workspaces[0].id
            return
        }
        let prevIndex = (currentIndex - 1 + workspaces.count) % workspaces.count
        activeWorkspaceId = workspaces[prevIndex].id
    }

    // MARK: - Tab Management

    public func assignTab(tabIdentifier: String, to workspaceId: UUID, at index: Int? = nil) {
        guard workspace(for: workspaceId) != nil else { return }

        for i in 0..<workspaces.count {
            workspaces[i].tabIdentifiers.removeAll { $0 == tabIdentifier }
            if workspaces[i].activeTabIdentifier == tabIdentifier {
                workspaces[i].activeTabIdentifier = workspaces[i].tabIdentifiers.first
            }
        }

        if let targetIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            if let index, index >= 0, index <= workspaces[targetIndex].tabIdentifiers.count {
                workspaces[targetIndex].tabIdentifiers.insert(tabIdentifier, at: index)
            } else {
                workspaces[targetIndex].tabIdentifiers.append(tabIdentifier)
            }
            if workspaces[targetIndex].activeTabIdentifier == nil {
                workspaces[targetIndex].activeTabIdentifier = tabIdentifier
            }
        }

        save()
        NotificationCenter.default.post(name: .takoWorkspaceDidChange, object: self)
    }

    public func removeTab(tabIdentifier: String) {
        var changed = false
        for i in 0..<workspaces.count {
            if let idx = workspaces[i].tabIdentifiers.firstIndex(of: tabIdentifier) {
                workspaces[i].tabIdentifiers.remove(at: idx)
                if workspaces[i].activeTabIdentifier == tabIdentifier {
                    workspaces[i].activeTabIdentifier = workspaces[i].tabIdentifiers.first
                }
                changed = true
            }
        }
        if changed {
            save()
            NotificationCenter.default.post(name: .takoWorkspaceDidChange, object: self)
        }
    }

    public func reorderTabs(in workspaceId: UUID, newOrder: [String]) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        var ordered: [String] = []
        for id in newOrder {
            if !ordered.contains(id) {
                ordered.append(id)
            }
        }
        // Append any unmentioned tabs to the end
        for id in workspaces[index].tabIdentifiers where !ordered.contains(id) {
            ordered.append(id)
        }
        workspaces[index].tabIdentifiers = ordered
        save()
        NotificationCenter.default.post(name: .takoWorkspaceDidChange, object: self)
    }

    public func setActiveTab(tabIdentifier: String, in workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        workspaces[index].activeTabIdentifier = tabIdentifier
        save()
    }

    // MARK: - Attention Count

    /// Aggregates attention count for the workspace across all open surfaces.
    public func attentionCount(for workspace: Workspace) -> Int {
        var count = 0
        let tabIds = Set(workspace.tabIdentifiers)
        let controllers = TerminalController.all
        for controller in controllers {
            guard let window = controller.window,
                  tabIds.contains(window.stableTabIdentifier) else { continue }
            for surface in controller.surfaceTree {
                if AttentionManager.shared.hasUnseenAttention(surface: surface) {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Persistence

    private struct StoredData: Codable {
        var activeWorkspaceId: UUID
        var workspaces: [Workspace]
    }

    public func load() {
        if isTesting {
            if workspaces.isEmpty {
                let def = makeDefaultWorkspace()
                workspaces = [def]
                activeWorkspaceId = def.id
            }
            return
        }

        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(StoredData.self, from: data),
              !stored.workspaces.isEmpty
        else {
            let def = makeDefaultWorkspace()
            workspaces = [def]
            activeWorkspaceId = def.id
            save()
            return
        }

        workspaces = stored.workspaces
        activeWorkspaceId = workspace(for: stored.activeWorkspaceId) != nil ? stored.activeWorkspaceId : (workspaces.first?.id ?? Self.defaultWorkspaceId)
    }

    public func save() {
        guard !isTesting else { return }
        do {
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stored = StoredData(activeWorkspaceId: activeWorkspaceId, workspaces: workspaces)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stored)
            try data.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch {
            NSLog("WorkspaceStore: Failed to save workspaces: \(error)")
        }
    }

    public func resetForTesting() {
        let def = makeDefaultWorkspace()
        workspaces = [def]
        activeWorkspaceId = def.id
    }

    private func makeDefaultWorkspace() -> Workspace {
        Workspace(
            id: Self.defaultWorkspaceId,
            name: "Default",
            color: "blue",
            icon: "terminal"
        )
    }
}
