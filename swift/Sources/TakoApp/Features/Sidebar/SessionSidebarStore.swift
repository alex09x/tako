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
import Combine
import Foundation
import TakoKit

/// Manages persistence, state, and item derivation for the session sidebar (B5).
@MainActor
final class SessionSidebarStore: ObservableObject {
    static let shared = SessionSidebarStore()

    static let isShowingKey = "tako.session_sidebar_is_showing"
    static let optInGitKey = "tako.session_sidebar_opt_in_git"
    static let optInPortsKey = "tako.session_sidebar_opt_in_ports"
    static let descriptionsKey = "tako.session_sidebar_descriptions"

    private let defaults: UserDefaults

    /// Whether the session sidebar is open in terminal windows.
    @Published var isShowing: Bool {
        didSet {
            defaults.set(isShowing, forKey: Self.isShowingKey)
            if !isShowing {
                surfaceSubscriptions.removeAll()
                surfaceLastStatus.removeAll()
            }
        }
    }

    /// Opt-in: read local git branch and dirty status from working directory.
    /// OFF by default to respect resource and latency budgets.
    @Published var optInGit: Bool {
        didSet {
            defaults.set(optInGit, forKey: Self.optInGitKey)
            invalidateCaches()
            objectWillChange.send()
        }
    }

    /// Opt-in: inspect local TCP listening ports for running pane processes.
    /// OFF by default to avoid unnecessary process inspection.
    @Published var optInPorts: Bool {
        didSet {
            defaults.set(optInPorts, forKey: Self.optInPortsKey)
            invalidateCaches()
            objectWillChange.send()
        }
    }

    private var defaultFilterNeedsAttention: Bool = false
    private var defaultFilterText: String = ""
    private var groupFilterTexts: [ObjectIdentifier: String] = [:]
    private var groupNeedsAttention: [ObjectIdentifier: Bool] = [:]

    /// Whether the sidebar view is filtered to only items needing attention for the specified window's tab group.
    func filterNeedsAttention(for window: NSWindow?) -> Bool {
        guard let window else { return defaultFilterNeedsAttention }
        let group = Tako.CustomTabGroup.group(for: window)
        return groupNeedsAttention[ObjectIdentifier(group)] ?? defaultFilterNeedsAttention
    }

    /// Sets whether the sidebar view is filtered to only items needing attention for the specified window's tab group.
    func setFilterNeedsAttention(_ enabled: Bool, for window: NSWindow?) {
        guard let window else {
            defaultFilterNeedsAttention = enabled
            objectWillChange.send()
            return
        }
        let group = Tako.CustomTabGroup.group(for: window)
        groupNeedsAttention[ObjectIdentifier(group)] = enabled
        objectWillChange.send()
    }

    /// Filter text for title, working directory, or description search for the specified window's tab group.
    func filterText(for window: NSWindow?) -> String {
        guard let window else { return defaultFilterText }
        let group = Tako.CustomTabGroup.group(for: window)
        return groupFilterTexts[ObjectIdentifier(group)] ?? defaultFilterText
    }

    /// Sets filter text for title, working directory, or description search for the specified window's tab group.
    func setFilterText(_ text: String, for window: NSWindow?) {
        guard let window else {
            defaultFilterText = text
            objectWillChange.send()
            return
        }
        let group = Tako.CustomTabGroup.group(for: window)
        groupFilterTexts[ObjectIdentifier(group)] = text
        objectWillChange.send()
    }

    /// Global fallback filter needs attention (for tests or global binding).
    var filterNeedsAttention: Bool {
        get { defaultFilterNeedsAttention }
        set {
            defaultFilterNeedsAttention = newValue
            objectWillChange.send()
        }
    }

    /// Global fallback filter text (for tests or global binding).
    var filterText: String {
        get { defaultFilterText }
        set {
            defaultFilterText = newValue
            objectWillChange.send()
        }
    }

    /// User-editable descriptions keyed by surface ID or window identifier.
    @Published var descriptions: [String: String] = [:] {
        didSet {
            defaults.set(descriptions, forKey: Self.descriptionsKey)
        }
    }

    // In-memory caches to avoid redundant filesystem/process inspections during rendering.
    // Refreshed only on explicit invalidation, directory change, command completion, or opt-in toggle.
    var gitCache: [String: LocalGitInspection.GitInfo?] = [:]
    var dirToRepoRoot: [String: String] = [:]
    var repoRootToDirs: [String: Set<String>] = [:]
    var gitRepoGenerations: [String: Int] = [:]
    var portsCache: [Int: [Int]] = [:]
    var pendingGitInspections: Set<String> = []
    var pendingPortsInspections: Set<Int> = []
    var globalCacheEpoch: Int = 0
    var gitGenerations: [String: Int] = [:]
    var portsGenerations: [Int: Int] = [:]

    var surfaceSubscriptions: [UUID: [AnyCancellable]] = [:]
    var surfaceLastStatus: [UUID: Tako.PaneStatus] = [:]

    init(defaults: UserDefaults = .tako) {
        self.defaults = defaults
        self.isShowing = defaults.bool(forKey: Self.isShowingKey)
        self.optInGit = defaults.bool(forKey: Self.optInGitKey)
        self.optInPorts = defaults.bool(forKey: Self.optInPortsKey)
        self.descriptions = defaults.dictionary(forKey: Self.descriptionsKey) as? [String: String] ?? [:]

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            MainActor.assumeIsolated {
                guard let self, let win = notif.object as? NSWindow else { return }
                let closedSurfaces = self.surfaces(in: win)
                for s in closedSurfaces {
                    self.surfaceSubscriptions.removeValue(forKey: s.id)
                    self.surfaceLastStatus.removeValue(forKey: s.id)
                }
                let group = Tako.CustomTabGroup.group(for: win)
                if group.windows.allSatisfy({ $0 === win }) {
                    self.groupFilterTexts.removeValue(forKey: ObjectIdentifier(group))
                    self.groupNeedsAttention.removeValue(forKey: ObjectIdentifier(group))
                }
            }
        }
    }

    /// Sets or updates a custom user description for a tab.
    func setDescription(_ text: String, for id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            descriptions.removeValue(forKey: id)
        } else {
            descriptions[id] = trimmed
        }
    }

    /// Clears a user description.
    func clearDescription(for id: String) {
        descriptions.removeValue(forKey: id)
    }

    /// Retrieves user description for an identifier.
    func description(for id: String) -> String? {
        descriptions[id]
    }
}
