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
import AppKit
import TakoKit

/// Result of executing a project action.
struct ProjectActionResult: Equatable, Sendable {
    let actionId: String
    let target: ProjectActionTarget
    let effectiveCwd: String
    let isTrusted: Bool
    let executed: Bool
}

/// Orchestrates execution, target routing, and user approval for project actions (C3).
@MainActor
final class ProjectActionManager {
    static let shared = ProjectActionManager()

    /// Finds the TerminalController holding the given surface.
    static func controller(for surface: Tako.SurfaceView) -> BaseTerminalController? {
        if let controller = surface.window?.windowController as? BaseTerminalController {
            return controller
        }
        return TerminalController.all.first { $0.surfaceTree.contains(surface) }
    }

    /// Triggers an action from the UI (e.g. Command Palette), prompting for confirmation if untrusted.
    func trigger(
        _ action: ProjectAction,
        project: ProjectActionDiscovery.DiscoveredProject,
        from surface: Tako.SurfaceView
    ) {
        let status = ProjectActionTrustStore.shared.status(
            path: project.filePath,
            content: project.fileContent
        )

        if status.isTrusted {
            _ = try? execute(
                action: action,
                projectRoot: project.projectRoot,
                from: surface,
                isTrusted: true
            )
            return
        }

        // Untrusted or changed: prompt the user for approval
        guard let window = surface.window else { return }

        let cmdStr = action.effectiveCommand.joined(separator: " ")
        let message: String
        switch status {
        case .untrusted:
            message = "Approve project actions for \(project.projectRoot)?\n\nAction '\(action.title)' will run:\n\(cmdStr.isEmpty ? "(shell)" : cmdStr)"
        case .changed(let recorded, let current):
            message = "Project actions file has changed since approval.\n(Previously: \(recorded.prefix(8))..., current: \(current.prefix(8))...)\n\nApprove running '\(action.title)'?\n\(cmdStr.isEmpty ? "(shell)" : cmdStr)"
        case .trusted:
            message = ""
        }

        let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
        Task { @MainActor [weak self] in
            let confirmed = await TerminalDialogView.ask(
                in: window,
                title: "Approve Project Action?",
                message: message,
                confirm: "Approve & Run",
                cancel: "Cancel",
                theme: theme
            )
            guard confirmed == true else { return }
            ProjectActionTrustStore.shared.trust(
                path: project.filePath,
                content: project.fileContent
            )
            _ = try? self?.execute(
                action: action,
                projectRoot: project.projectRoot,
                from: surface,
                isTrusted: true
            )
        }
    }

    /// Resolves the executable binary path for an argv-based command without invoking a shell.
    ///
    /// - Parameters:
    ///   - executable: The program name or path (e.g. "printf", "cargo", "./build.sh", "/bin/ls").
    ///   - cwd: The working directory for relative paths containing '/'.
    ///   - pathEnv: Optional explicit PATH string; falls back to ProcessInfo PATH or standard system paths.
    /// - Returns: Absolute path to the executable if found, or nil if not found.
    static func resolveExecutable(_ executable: String, cwd: String, pathEnv: String?) -> String? {
        let expanded = (executable as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        if expanded.contains("/") {
            let path = (cwd as NSString).appendingPathComponent(expanded)
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        let searchPath = pathEnv ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        for dir in searchPath.split(separator: ":").map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(expanded)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Prepares the program argv for execution in a new split or tab.
    ///
    /// Preserves exact argv boundaries and literal arguments unless `action.shell == true` is explicitly requested.
    /// Fails closed when an executable cannot be resolved; never passes unvalidated executables to a launcher.
    static func resolveProgram(action: ProjectAction, effectiveCwd: String) throws -> [String] {
        let cmd = action.effectiveCommand
        guard !cmd.isEmpty else { return [] }

        if action.shell == true {
            return ["/bin/sh", "-c", cmd.joined(separator: " ")]
        }

        // Literal argv execution: resolve executable while strictly preserving all argument tokens
        guard let exe = cmd.first, !exe.isEmpty else { return cmd }
        if let resolvedPath = resolveExecutable(exe, cwd: effectiveCwd, pathEnv: action.env?["PATH"]) {
            var resolved = cmd
            resolved[0] = resolvedPath
            return resolved
        }

        throw ControlError(.notFound, "Executable not found: '\(exe)'")
    }

    /// Executes a project action against a source surface.
    ///
    /// - Parameters:
    ///   - action: The action specification to execute.
    ///   - projectRoot: Root directory of the project.
    ///   - surface: The surface invoking the action.
    ///   - isTrusted: Whether the project file is approved/trusted.
    ///   - app: Optional Tako.App override (useful for testing).
    /// - Returns: Execution result metadata.
    @discardableResult
    func execute(
        action: ProjectAction,
        projectRoot: String,
        from surface: Tako.SurfaceView,
        isTrusted: Bool,
        app: Tako.App? = nil
    ) throws -> ProjectActionResult {
        guard isTrusted else {
            return ProjectActionResult(
                actionId: action.id,
                target: action.effectiveTarget,
                effectiveCwd: projectRoot,
                isTrusted: false,
                executed: false
            )
        }

        let takoApp = app ?? Self.controller(for: surface)?.tako ?? (NSApp.delegate as? AppDelegate)?.tako
        let effectiveCwd: String = {
            if let customCwd = action.cwd, !customCwd.isEmpty {
                let expanded = (customCwd as NSString).expandingTildeInPath
                if (expanded as NSString).isAbsolutePath {
                    return expanded
                }
                return (projectRoot as NSString).appendingPathComponent(expanded)
            }
            return projectRoot
        }()

        var config = Tako.SurfaceConfiguration()
        config.workingDirectory = effectiveCwd
        if let env = action.env {
            config.environmentVariables = env
        }

        let cmd = action.effectiveCommand
        if (action.effectiveTarget == .split || action.effectiveTarget == .newTab) && !cmd.isEmpty {
            config.program = try Self.resolveProgram(action: action, effectiveCwd: effectiveCwd)
        }

        switch action.effectiveTarget {
        case .pane:
            // Send command into current pane
            if !cmd.isEmpty {
                let cmdString: String
                if action.shell == true {
                    cmdString = cmd.joined(separator: " ")
                } else {
                    cmdString = cmd.map { ResumeSessionStore.shellQuote($0) }.joined(separator: " ")
                }
                try? ControlInput.send(surface, text: cmdString, enter: true)
            }

        case .split:
            // Create split beside the surface
            let controller = Self.controller(for: surface)
            let direction: SplitTree<Tako.SurfaceView>.NewDirection = (action.effectiveDirection == .vertical) ? .down : .right
            _ = controller?.newSplit(at: surface, direction: direction, baseConfig: config)

        case .newTab:
            // Create new tab in window
            if let window = surface.window, let tako = takoApp {
                _ = TerminalController.newTab(tako, from: window, withBaseConfig: config)
            }
        }

        return ProjectActionResult(
            actionId: action.id,
            target: action.effectiveTarget,
            effectiveCwd: effectiveCwd,
            isTrusted: true,
            executed: true
        )
    }
}
