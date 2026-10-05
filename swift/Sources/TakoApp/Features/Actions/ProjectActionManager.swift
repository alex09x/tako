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
        if !cmd.isEmpty {
            if action.shell == true {
                config.program = ["/bin/sh", "-c", cmd.joined(separator: " ")]
            } else {
                config.program = cmd
            }
        }

        switch action.effectiveTarget {
        case .pane:
            // Send command into current pane
            if !cmd.isEmpty {
                let cmdString = cmd.joined(separator: " ")
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
