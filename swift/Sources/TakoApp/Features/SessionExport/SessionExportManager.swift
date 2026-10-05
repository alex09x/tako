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

/// Coordinates exporting and importing Tako terminal sessions (C9).
@MainActor
final class SessionExportManager {
    static let shared = SessionExportManager()

    private init() {}

    /// Inspects an exported session file, validating its schema version and returning an overview (C9).
    func inspectSession(from url: URL) throws -> SessionInfo {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionExportError.fileNotFound(url.path)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let file: SessionExportFile
        do {
            file = try decoder.decode(SessionExportFile.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            throw SessionExportError.invalidSessionFile(context.debugDescription)
        } catch {
            // Check if it's an unsupported newer version
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ver = json["formatVersion"] as? Int,
               ver > SessionExportFile.currentFormatVersion {
                throw SessionExportError.unsupportedFormatVersion(got: ver, supported: SessionExportFile.currentFormatVersion)
            }
            throw SessionExportError.invalidSessionFile(error.localizedDescription)
        }

        guard file.formatVersion <= SessionExportFile.currentFormatVersion else {
            throw SessionExportError.unsupportedFormatVersion(
                got: file.formatVersion,
                supported: SessionExportFile.currentFormatVersion
            )
        }

        var totalPanes = 0
        var totalResumes = 0
        for w in file.windows {
            totalPanes += w.panes.count
            totalResumes += w.panes.filter { $0.resume != nil }.count
        }

        return SessionInfo(
            formatVersion: file.formatVersion,
            exportedAt: file.exportedAt,
            takoVersion: file.takoVersion,
            windowCount: file.windows.count,
            paneCount: totalPanes,
            resumeCount: totalResumes
        )
    }

    /// Exports active windows/panes to a structured session file (C9).
    func exportSession(
        window: NSWindow? = nil,
        to url: URL,
        takoVersion: String = "0.1.7"
    ) throws -> SessionExportFile {
        let controllers: [TerminalController]
        if let window {
            if let tc = TerminalController.all.first(where: { $0.window === window }) {
                controllers = [tc]
            } else if let tc = window.windowController as? TerminalController {
                controllers = [tc]
            } else {
                controllers = []
            }
        } else {
            controllers = TerminalController.all
        }

        guard !controllers.isEmpty else {
            throw SessionExportError.emptySession
        }

        var exportedWindows: [ExportedWindow] = []

        for c in controllers {
            let winId: UUID = {
                if let str = (c.window as? TerminalWindow)?.stableTabIdentifier,
                   let u = UUID(uuidString: str) {
                    return u
                }
                return UUID()
            }()
            let tree = c.surfaceTree

            guard let root = tree.root else { continue }
            let layoutNode = root.toExportedNode()

            var exportedPanes: [ExportedPane] = []
            for surface in tree {
                let tail = surface.core.textTail(maxLines: 10000, maxBytes: 4 * 1024 * 1024)
                let cleanScrollback = ControlSequenceSanitizer.dropControlSequences(from: tail.text)

                var resumeExport: ExportedResume? = nil
                if let record = ResumeSessionStore.shared.record(for: surface.id) {
                    resumeExport = ExportedResume(argv: record.argv, cwd: record.cwd)
                }

                let pane = ExportedPane(
                    id: surface.id,
                    pwd: surface.pwd,
                    title: surface.title,
                    scrollback: cleanScrollback,
                    resume: resumeExport
                )
                exportedPanes.append(pane)
            }

            let tabColorStr = (c.window as? TerminalWindow)?.tabColor.name
            let expWin = ExportedWindow(
                id: winId,
                titleOverride: c.titleOverride,
                tabColor: tabColorStr,
                layout: layoutNode,
                panes: exportedPanes
            )
            exportedWindows.append(expWin)
        }

        guard !exportedWindows.isEmpty else {
            throw SessionExportError.emptySession
        }

        let exportFile = SessionExportFile(
            formatVersion: SessionExportFile.currentFormatVersion,
            exportedAt: Date(),
            takoVersion: takoVersion,
            windows: exportedWindows
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(exportFile)
        try data.write(to: url, options: .atomic)

        return exportFile
    }

    /// Imports a session file, restoring layouts, sanitized scrollback, and untrusted resume records (C9).
    func importSession(
        from url: URL,
        in app: Tako.App? = nil
    ) throws -> [TerminalController] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionExportError.fileNotFound(url.path)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let file: SessionExportFile
        do {
            file = try decoder.decode(SessionExportFile.self, from: data)
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ver = json["formatVersion"] as? Int,
               ver > SessionExportFile.currentFormatVersion {
                throw SessionExportError.unsupportedFormatVersion(got: ver, supported: SessionExportFile.currentFormatVersion)
            }
            throw SessionExportError.invalidSessionFile(error.localizedDescription)
        }

        guard file.formatVersion <= SessionExportFile.currentFormatVersion else {
            throw SessionExportError.unsupportedFormatVersion(
                got: file.formatVersion,
                supported: SessionExportFile.currentFormatVersion
            )
        }

        let effectiveApp = app ?? (NSApp?.delegate as? AppDelegate)?.tako ?? Tako.App()
        var createdControllers: [TerminalController] = []

        for windowData in file.windows {
            var surfaceMap: [UUID: Tako.SurfaceView] = [:]

            for paneData in windowData.panes {
                // Sanitize untrusted scrollback by dropping any escape/control sequences
                let cleanScrollback = ControlSequenceSanitizer.dropControlSequences(from: paneData.scrollback)
                let workingDir = paneData.pwd

                var base = Tako.SurfaceConfiguration()
                base.isRestored = true
                base.workingDirectory = workingDir

                let surface = Tako.SurfaceView(effectiveApp, baseConfig: base, uuid: paneData.id)

                // Feed sanitized clean text into display buffer (never writes to PTY)
                if !cleanScrollback.isEmpty {
                    surface.core.feed(bytes: Data(cleanScrollback.utf8))
                }

                // Register resume record with isImported = true (NEVER runs automatically)
                if let resume = paneData.resume {
                    let record = ResumeSessionRecord(
                        argv: resume.argv,
                        cwd: resume.cwd,
                        isImported: true
                    )
                    ResumeSessionStore.shared.set(record: record, for: surface.id)
                    surface.checkAndApplyResumeOnRestore(restoredDir: workingDir)
                }

                surfaceMap[paneData.id] = surface
            }

            guard let rootNode = windowData.layout.toSplitTreeNode(surfaces: surfaceMap) else {
                continue
            }

            let splitTree = SplitTree<Tako.SurfaceView>(root: rootNode, zoomed: nil)
            let controller = TerminalController(effectiveApp, withSurfaceTree: splitTree)

            if let titleOverride = windowData.titleOverride {
                controller.titleOverride = titleOverride
            }

            if let tabColorStr = windowData.tabColor,
               let color = TerminalTabColor(named: tabColorStr),
               let window = controller.window as? TerminalWindow {
                window.tabColor = color
            }

            controller.window?.makeKeyAndOrderFront(nil)
            createdControllers.append(controller)
        }

        return createdControllers
    }
}

// MARK: - SplitTree Node Conversions

extension SplitTree.Node where ViewType == Tako.SurfaceView {
    func toExportedNode() -> ExportedLayoutNode {
        switch self {
        case .leaf(let surface):
            return .leaf(paneId: surface.id)
        case .split(let split):
            let dir = split.direction == .horizontal ? "horizontal" : "vertical"
            return .split(
                direction: dir,
                ratio: split.ratio,
                left: split.left.toExportedNode(),
                right: split.right.toExportedNode()
            )
        }
    }
}

extension ExportedLayoutNode {
    func toSplitTreeNode(surfaces: [UUID: Tako.SurfaceView]) -> SplitTree<Tako.SurfaceView>.Node? {
        switch self {
        case .leaf(let id):
            guard let surface = surfaces[id] else { return nil }
            return .leaf(view: surface)
        case .split(let dir, let ratio, let left, let right):
            guard let leftNode = left.toSplitTreeNode(surfaces: surfaces),
                  let rightNode = right.toSplitTreeNode(surfaces: surfaces) else {
                return nil
            }
            let direction: SplitTree<Tako.SurfaceView>.Direction = dir == "horizontal" ? .horizontal : .vertical
            return .split(.init(direction: direction, ratio: ratio, left: leftNode, right: rightNode))
        }
    }
}
