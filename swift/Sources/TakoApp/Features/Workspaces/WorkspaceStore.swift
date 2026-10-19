/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation


extension Notification.Name {
    public static let takoWorkspaceDidChange = Notification.Name("TakoWorkspaceDidChange")
    public static let takoTabsDidChange = Notification.Name("TakoTabsDidChange")
}

/// Central store for project workspaces (C1).
/// Manages workspace metadata, tab assignments, tab order, and attention aggregation.
@MainActor
public final class WorkspaceStore: ObservableObject {
    public static let shared = WorkspaceStore(isTesting: Tako.CustomTabGroup.suppressWindowOrderingForTesting)

    public static let defaultWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public struct WorkspaceTransition: Codable, Sendable {
        public let sequence: Int64
        public let fromId: UUID
        public let toId: UUID
        public let timestamp: TimeInterval

        public init(sequence: Int64, fromId: UUID, toId: UUID, timestamp: TimeInterval) {
            self.sequence = sequence
            self.fromId = fromId
            self.toId = toId
            self.timestamp = timestamp
        }
    }

    public struct TabTransition: Codable, Sendable {
        public let sequence: Int64
        public let workspaceId: UUID
        public let fromId: String
        public let toId: String
        public let timestamp: TimeInterval

        public init(sequence: Int64, workspaceId: UUID, fromId: String, toId: String, timestamp: TimeInterval) {
            self.sequence = sequence
            self.workspaceId = workspaceId
            self.fromId = fromId
            self.toId = toId
            self.timestamp = timestamp
        }
    }

    public private(set) var recentTransitions: [WorkspaceTransition] = []
    public internal(set) var recentTabTransitions: [TabTransition] = []
    var nextTransitionSequence: Int64 = 0
    let maxTransitionHistory = 50

    private var isLoading: Bool = false
    @Published public internal(set) var workspaces: [Workspace] = [] {
        didSet { indexTabs() }
    }
    /// Each tab's workspace and place in its order, kept with `workspaces`:
    /// the tab bar asks for every tab on every draw.
    var tabPlaces: [String: TabPlace] = [:]
    @Published public var activeWorkspaceId: UUID {
        didSet {
            guard !isLoading else { return }
            if oldValue != activeWorkspaceId {
                nextTransitionSequence += 1
                recentTransitions.append(WorkspaceTransition(
                    sequence: nextTransitionSequence,
                    fromId: oldValue,
                    toId: activeWorkspaceId,
                    timestamp: ProcessInfo.processInfo.systemUptime
                ))
                if recentTransitions.count > maxTransitionHistory {
                    recentTransitions.removeFirst(recentTransitions.count - maxTransitionHistory)
                }
                save()
                NotificationCenter.default.post(
                    name: .takoWorkspaceDidChange,
                    object: self,
                    userInfo: ["fromWorkspaceId": oldValue, "toWorkspaceId": activeWorkspaceId]
                )
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
        tabPlaces[tabIdentifier].flatMap { workspace(for: $0.workspace) }
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
        NotificationCenter.default.post(name: .takoTabsDidChange, object: self)
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

    // MARK: - Attention Count

    /// Aggregates attention count for the workspace across all open surfaces.
    public func attentionCount(for workspace: Workspace) -> Int {
        var count = 0
        let controllers = TerminalController.all
        for controller in controllers {
            guard let window = controller.window,
                  tabPlaces[window.stableTabIdentifier]?.workspace == workspace.id else { continue }
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
        isLoading = true
        defer { isLoading = false }

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
        recentTransitions.removeAll()
        recentTabTransitions.removeAll()
        nextTransitionSequence = 0
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
