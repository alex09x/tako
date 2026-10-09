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
import TakoKit

/// Target pane execution destination for a project action (C3).
enum ProjectActionTarget: String, Codable, Equatable, Sendable {
    case pane = "pane"
    case split = "split"
    case newTab = "new-tab"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        switch raw {
        case "pane", "current", "current-pane", "self":
            self = .pane
        case "split", "split-pane":
            self = .split
        case "new-tab", "tab", "newtab":
            self = .newTab
        default:
            self = .split
        }
    }
}

/// Split direction when target is .split.
enum ProjectActionSplitDirection: String, Codable, Equatable, Sendable {
    case horizontal = "horizontal" // side by side (right)
    case vertical = "vertical"     // stacked (down)
}

/// A project-local action (build, test, start dev server, start an agent).
struct ProjectAction: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var description: String?
    var command: [String]?
    var argv: [String]?
    var shell: Bool?
    var cwd: String?
    var env: [String: String]?
    var target: ProjectActionTarget?
    var direction: ProjectActionSplitDirection?

    init(
        id: String,
        title: String,
        description: String? = nil,
        command: [String]? = nil,
        argv: [String]? = nil,
        shell: Bool? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        target: ProjectActionTarget? = nil,
        direction: ProjectActionSplitDirection? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.command = command
        self.argv = argv
        self.shell = shell
        self.cwd = cwd
        self.env = env
        self.target = target
        self.direction = direction
    }

    /// Effective argument vector (command or argv).
    var effectiveCommand: [String] {
        if let command, !command.isEmpty { return command }
        if let argv, !argv.isEmpty { return argv }
        return []
    }

    /// Effective execution target. Defaults to .split.
    var effectiveTarget: ProjectActionTarget {
        target ?? .split
    }

    /// Effective split direction. Defaults to .horizontal.
    var effectiveDirection: ProjectActionSplitDirection {
        direction ?? .horizontal
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case command
        case argv
        case shell
        case cwd
        case env
        case target
        case direction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        if let cmdList = try? container.decodeIfPresent([String].self, forKey: .command) {
            self.command = cmdList
        } else if let single = try? container.decodeIfPresent(String.self, forKey: .command) {
            self.command = [single]
        } else {
            self.command = nil
        }
        self.argv = try container.decodeIfPresent([String].self, forKey: .argv)
        self.shell = try container.decodeIfPresent(Bool.self, forKey: .shell)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.env = try container.decodeIfPresent([String: String].self, forKey: .env)
        self.target = try container.decodeIfPresent(ProjectActionTarget.self, forKey: .target)
        self.direction = try container.decodeIfPresent(ProjectActionSplitDirection.self, forKey: .direction)
    }
}

/// A project file containing project-local actions.
struct ProjectActionFile: Codable, Equatable, Sendable {
    var version: Int?
    var name: String?
    var actions: [ProjectAction]

    init(version: Int? = 1, name: String? = nil, actions: [ProjectAction]) {
        self.version = version
        self.name = name
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey {
        case version
        case name
        case actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.actions = try container.decodeIfPresent([ProjectAction].self, forKey: .actions) ?? []
    }
}

/// Discovers project action files from a working directory or surface.
enum ProjectActionDiscovery {
    struct DiscoveredProject: Equatable, Sendable {
        let projectRoot: String
        let filePath: String
        let fileContent: String
        let file: ProjectActionFile
    }

    static let candidateFiles = [
        ".tako/actions.json",
        "tako-actions.json",
        ".tako.json"
    ]

    /// Searches upward from the given path to find a project action file.
    static func find(at directoryPath: String) -> DiscoveredProject? {
        let expanded = (directoryPath as NSString).expandingTildeInPath
        var current = URL(fileURLWithPath: expanded).standardized
        let fileManager = FileManager.default

        while true {
            for candidate in candidateFiles {
                let candidateURL = current.appendingPathComponent(candidate)
                if fileManager.fileExists(atPath: candidateURL.path) {
                    if let content = try? String(contentsOf: candidateURL, encoding: .utf8),
                       let data = content.data(using: .utf8),
                       let file = try? JSONDecoder().decode(ProjectActionFile.self, from: data),
                       !file.actions.isEmpty {
                        return DiscoveredProject(
                            projectRoot: current.path,
                            filePath: candidateURL.path,
                            fileContent: content,
                            file: file
                        )
                    }
                }
            }

            // Stop at filesystem root or .git root
            if current.path == "/" { break }
            let gitURL = current.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitURL.path) {
                // We checked the git root; don't walk above the repo
                break
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        return nil
    }

    /// Discovers project actions for a surface based on its working directory or active workspace.
    @MainActor
    static func find(for surface: Tako.SurfaceView) -> DiscoveredProject? {
        if let pwd = surface.pwd, !pwd.isEmpty {
            if let discovered = find(at: pwd) {
                return discovered
            }
        }
        if let cwd = surface.workingDirectory, !cwd.isEmpty {
            if let discovered = find(at: cwd) {
                return discovered
            }
        }
        if let root = WorkspaceStore.shared.activeWorkspace.rootDirectory, !root.isEmpty {
            if let discovered = find(at: root) {
                return discovered
            }
        }
        return nil
    }
}
