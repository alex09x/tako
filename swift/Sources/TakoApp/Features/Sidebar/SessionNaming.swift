/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// What a session and its terminals are called in the sidebar (agreed with
/// the owner 2026-11-11):
/// - A name someone gave wins, and stays until they ask for the automatic one.
/// - One terminal: what runs in it, or its folder (today's title).
/// - Two or more: the folder they share, when they are all in one; otherwise
///   the first terminal's name and how many more there are ("claude · auth +1").
/// - A terminal with nothing to say for itself is "Terminal N", never "Pane N".
enum SessionNaming {
    struct Terminal: Equatable {
        /// What the terminal would be called on its own (program, title or folder).
        let title: String
        /// Its working directory, if the shell reported one.
        let directory: String?
    }

    static func sessionName(override: String?, single: String, terminals: [Terminal]) -> String {
        if let own = override?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty { return own }
        guard terminals.count > 1, let first = terminals.first else { return single }
        if let shared = sharedFolder(terminals.map(\.directory)) { return shared }
        return "\(first.title) +\(terminals.count - 1)"
    }

    /// The last path component of the one directory every terminal is in, or
    /// the deepest folder they all sit under that is more than home or `/`.
    static func sharedFolder(_ directories: [String?]) -> String? {
        let dirs = directories.compactMap { $0 }.map { ($0 as NSString).standardizingPath }
        guard dirs.count == directories.count, let first = dirs.first else { return nil }
        var common = (first as NSString).pathComponents
        for dir in dirs.dropFirst() {
            let parts = (dir as NSString).pathComponents
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        let path = NSString.path(withComponents: common)
        let home = (NSHomeDirectory() as NSString).standardizingPath
        guard common.count > 1, path != home, path != "/" , !home.hasPrefix(path + "/") else { return nil }
        return (path as NSString).lastPathComponent
    }

    static func fallbackTerminalName(index: Int) -> String { "Terminal \(index + 1)" }
}

extension Tako.SurfaceView {
    /// The terminal's name in the sidebar: its own, else what it shows
    /// (title, then folder), else "Terminal N".
    @MainActor func sidebarTitle(index: Int) -> String {
        if let own = paneTitleOverride { return own }
        if !titleText.isEmpty { return titleText }
        if !title.isEmpty { return title }
        if let d = pwd, !d.isEmpty { return Tako.titleForDirectory(d) }
        return SessionNaming.fallbackTerminalName(index: index)
    }
}
