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

/// Coordinates saving and applying declarative layouts, converting between
/// `LayoutDocument` and live AppKit window/tab/split hierarchies.
@MainActor
enum LayoutManager {

    struct ApplyResult: Sendable {
        let windowsCreated: Int
        let tabsCreated: Int
        let panesCreated: Int
        let programsStarted: Int
        let programsSuppressed: Int
        let isTrusted: Bool
    }

    // MARK: - Capture (Save)

    /// Captures the layout of `window` (or the active/front window) into a `LayoutDocument`.
    static func capture(window: NSWindow? = nil) throws -> LayoutDocument {
        let targetWindow: NSWindow = try {
            if let window { return window }
            if let key = NSApp.keyWindow, key.windowController is BaseTerminalController { return key }
            if let main = NSApp.mainWindow, main.windowController is BaseTerminalController { return main }
            if let first = TerminalController.all.first?.window { return first }
            throw ControlError(.notFound, "no terminal window found to capture layout")
        }()

        let group = Tako.CustomTabGroup.group(for: targetWindow)
        let tabWindows = group.windows.filter { $0.windowController is BaseTerminalController }
        guard !tabWindows.isEmpty else {
            throw ControlError(.notFound, "window has no terminal tabs")
        }

        let selectedIndex = group.selectedWindow.flatMap { s in tabWindows.firstIndex { $0 === s } } ?? 0

        var tabs: [LayoutTab] = []
        for tabWindow in tabWindows {
            guard let controller = tabWindow.windowController as? BaseTerminalController else { continue }
            let title = controller.titleOverride ?? tabWindow.title
            let color = (tabWindow as? TerminalWindow).flatMap { $0.tabColor == .none ? nil : $0.tabColor.name }
            let rootNode = convertToLayoutNode(controller.surfaceTree.root)
            tabs.append(LayoutTab(title: title.isEmpty ? nil : title, color: color, root: rootNode))
        }

        let frame = LayoutFrame(targetWindow.frame)
        let windowDoc = LayoutWindow(
            title: targetWindow.title.isEmpty ? nil : targetWindow.title,
            frame: frame,
            selectedTab: selectedIndex,
            tabs: tabs
        )

        return LayoutDocument(version: 1, name: targetWindow.title, windows: [windowDoc])
    }

    private static func convertToLayoutNode(_ node: SplitTree<Tako.SurfaceView>.Node?) -> LayoutNode {
        guard let node else {
            return .leaf(LayoutPane())
        }
        switch node {
        case .leaf(let surface):
            let cwd = surface.pwd
            let title = surface.title
            let command = surface.runProgram
            return .leaf(LayoutPane(
                title: title.isEmpty ? nil : title,
                cwd: cwd,
                env: nil,
                command: command,
                argv: nil,
                shell: false
            ))
        case .split(let split):
            let dir = LayoutSplitDirection(from: split.direction)
            let left = convertToLayoutNode(split.left)
            let right = convertToLayoutNode(split.right)
            return .split(LayoutSplit(direction: dir, ratio: split.ratio, left: left, right: right))
        }
    }

    // MARK: - Apply

    /// Applies a declarative layout document, recreating windows, tabs, splits,
    /// working directories, titles, and programs.
    ///
    /// When `isTrusted` is false:
    /// - An unapproved project layout NEVER starts a program (roadmap C2 guarantee).
    /// - Working directories, titles, environments, and shell sessions are faithfully created.
    static func apply(
        document: LayoutDocument,
        isTrusted: Bool,
        app: Tako.App? = nil
    ) throws -> ApplyResult {
        let takoApp = app ?? (NSApp.delegate as? AppDelegate)?.tako
        guard let tako = takoApp else {
            throw ControlError(.internalError, "no Tako app instance available")
        }

        let windowsToApply = document.effectiveWindows
        guard !windowsToApply.isEmpty else {
            throw ControlError(.invalid, "layout document contains no windows or tabs")
        }

        var totalTabs = 0
        var totalPanes = 0
        var programsStarted = 0
        var programsSuppressed = 0

        for windowDoc in windowsToApply {
            guard !windowDoc.tabs.isEmpty else { continue }

            var anchorWindow: NSWindow?
            var selectedWindow: NSWindow?

            for (tabIndex, tabDoc) in windowDoc.tabs.enumerated() {
                var tabPaneCount = 0
                var tabProgStarted = 0
                var tabProgSuppressed = 0

                let rootNode = buildSplitTreeNode(
                    tabDoc.root,
                    app: tako,
                    isTrusted: isTrusted,
                    paneCount: &tabPaneCount,
                    programsStarted: &tabProgStarted,
                    programsSuppressed: &tabProgSuppressed
                )

                totalPanes += tabPaneCount
                programsStarted += tabProgStarted
                programsSuppressed += tabProgSuppressed

                let tree = SplitTree<Tako.SurfaceView>(root: rootNode, zoomed: nil)
                let controller = TerminalController(tako, withSurfaceTree: tree)
                guard let window = controller.window else { continue }

                if let title = tabDoc.title, !title.isEmpty {
                    controller.titleOverride = title
                }
                if let colorName = tabDoc.color, let color = TerminalTabColor(named: colorName) {
                    (window as? TerminalWindow)?.tabColor = color
                }

                controller.showWindow(nil)

                if let anchor = anchorWindow {
                    Tako.CustomTabGroup.join(window, to: anchor, select: false)
                } else {
                    if let frame = windowDoc.frame {
                        window.setFrame(LayoutRecorder.onScreen(frame.asRect), display: true)
                    }
                    anchorWindow = window
                }

                if tabIndex == (windowDoc.selectedTab ?? 0) {
                    selectedWindow = window
                }

                totalTabs += 1
            }

            if let anchor = anchorWindow, let selected = selectedWindow {
                Tako.CustomTabGroup.group(for: anchor).select(selected)
                selected.makeKeyAndOrderFront(nil)
            }
        }

        return ApplyResult(
            windowsCreated: windowsToApply.count,
            tabsCreated: totalTabs,
            panesCreated: totalPanes,
            programsStarted: programsStarted,
            programsSuppressed: programsSuppressed,
            isTrusted: isTrusted
        )
    }

    private static func buildSplitTreeNode(
        _ node: LayoutNode,
        app: Tako.App,
        isTrusted: Bool,
        paneCount: inout Int,
        programsStarted: inout Int,
        programsSuppressed: inout Int
    ) -> SplitTree<Tako.SurfaceView>.Node {
        switch node {
        case .leaf(let pane):
            paneCount += 1
            var config = Tako.SurfaceConfiguration()
            if let cwd = pane.cwd, !cwd.isEmpty {
                config.workingDirectory = (cwd as NSString).expandingTildeInPath
            }
            let hasExecutableWork = (pane.effectiveCommand?.isEmpty == false) || (pane.env?.isEmpty == false)
            if hasExecutableWork {
                if isTrusted {
                    programsStarted += 1
                    if let env = pane.env {
                        config.environmentVariables = env
                    }
                    if let cmd = pane.effectiveCommand, !cmd.isEmpty {
                        if pane.shell == true {
                            config.program = ["/bin/sh", "-c", cmd.joined(separator: " ")]
                        } else {
                            config.program = cmd
                        }
                    }
                } else {
                    programsSuppressed += 1
                    // Program and environment suppressed because layout is untrusted
                }
            }

            let surface = Tako.SurfaceView(app, baseConfig: config)
            if let title = pane.title, !title.isEmpty {
                surface.title = title
            }
            return .leaf(view: surface)

        case .split(let split):
            let leftNode = buildSplitTreeNode(
                split.left,
                app: app,
                isTrusted: isTrusted,
                paneCount: &paneCount,
                programsStarted: &programsStarted,
                programsSuppressed: &programsSuppressed
            )
            let rightNode = buildSplitTreeNode(
                split.right,
                app: app,
                isTrusted: isTrusted,
                paneCount: &paneCount,
                programsStarted: &programsStarted,
                programsSuppressed: &programsSuppressed
            )
            return .split(SplitTree.Node.Split(
                direction: split.direction.asSplitTreeDirection,
                ratio: split.ratio,
                left: leftNode,
                right: rightNode
            ))
        }
    }

    // MARK: - Project Layout Discovery

    /// Discovers candidate layout files inside a project directory.
    static func findProjectLayout(in directory: String) -> URL? {
        let expanded = (directory as NSString).expandingTildeInPath
        let candidates = [
            ".tako/layout.json",
            "tako-layout.json",
            ".tako-layout.json",
            "layout.json"
        ]
        let base = URL(fileURLWithPath: expanded, isDirectory: true)
        for rel in candidates {
            let candidateURL = base.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        return nil
    }
}
