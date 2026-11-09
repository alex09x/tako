/*
 * tako — A pane's own name, set by «Rename» in its header menu
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine

extension Notification.Name {
    /// A pane's own name changed (object: the pane's UUID).
    static let takoPaneTitleDidChange = Notification.Name("takoPaneTitleDidChange")
}

/// The names people give panes, keyed by the pane's stable UUID (the one
/// session restore and scoped appearance use) in `PaneTitles.json` beside
/// `Appearance.json`. A name is shown over the program's title, and never
/// replaces it: the program and OSC title stay what they are, and removing
/// the name shows them again. Session snapshots are not touched, so old ones
/// restore as before; a pane without a name here simply has none.
@MainActor
final class PaneTitleStore: ObservableObject {
    /// Tests get a private file: they never write where the app keeps its names.
    static let shared = PaneTitleStore(fileURL: NSClassFromString("XCTestCase") == nil
        ? SessionPlaces.support.appendingPathComponent("PaneTitles.json")
        : FileManager.default.temporaryDirectory.appendingPathComponent("tako-pane-titles-\(UUID().uuidString).json"))

    /// Longest name kept; longer input is cut, not refused.
    static let maxLength = 120

    let fileURL: URL
    @Published private(set) var titles: [String: String] = [:]
    private(set) var loadError: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    func title(for id: UUID) -> String? { titles[Self.key(id)] }

    /// Sets the pane's name; an empty one removes it (the program's title shows again).
    func setTitle(_ raw: String?, for id: UUID) {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
        let name = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxLength))
        guard titles[Self.key(id)] != name else { return }
        titles[Self.key(id)] = name
        save()
        NotificationCenter.default.post(name: .takoPaneTitleDidChange, object: id)
        SessionSidebarStore.shared.objectWillChange.send()
        Tako.TabBarController.refreshAll()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            titles = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // An unreadable file names no pane; it is kept until a name is set.
            loadError = error.localizedDescription
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(titles).write(to: fileURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension Tako.SurfaceView {
    /// The pane's own name, if someone gave it one.
    var paneTitleOverride: String? { PaneTitleStore.shared.title(for: id) }

    /// The pane's own name, else what it would show without one.
    func paneDisplayTitle(_ fallback: () -> String) -> String { paneTitleOverride ?? fallback() }
}
