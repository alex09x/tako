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

extension ControlCommands {
    /// `takoctl session`: session export, import, and file inspection (C9).
    static func sessionCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "session command requires an action (export, import, info)")
        }()

        switch action {
        case "export":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "session export requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)

            // Resolve target window if requested
            let targetWindow: NSWindow? = {
                if let winId = request.args["window"]?.string, !winId.isEmpty {
                    if let found = all.first(where: {
                        $0.windowID.lowercased().hasPrefix(winId.lowercased()) ||
                        $0.stableTabID.lowercased().hasPrefix(winId.lowercased())
                    }) {
                        return found.controller?.window
                    }
                }
                if let targetSurface = try? target(request, all) {
                    return targetSurface.window ?? all.first(where: { $0.surface === targetSurface })?.controller?.window
                }
                return nil
            }()

            do {
                let file = try SessionExportManager.shared.exportSession(window: targetWindow, to: url)
                var paneCount = 0
                var resumeCount = 0
                for w in file.windows {
                    paneCount += w.panes.count
                    resumeCount += w.panes.filter { $0.resume != nil }.count
                }
                return [
                    "exported": .bool(true),
                    "path": .string(path),
                    "windows": .number(Double(file.windows.count)),
                    "panes": .number(Double(paneCount)),
                    "resumes": .number(Double(resumeCount)),
                    "format_version": .number(Double(file.formatVersion))
                ]
            } catch let err as SessionExportError {
                switch err {
                case .emptySession:
                    throw ControlError(.notFound, err.localizedDescription)
                default:
                    throw ControlError(.invalid, err.localizedDescription)
                }
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        case "import":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "session import requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let effectiveApp = all.first?.controller?.tako ?? (NSApp?.delegate as? AppDelegate)?.tako

            do {
                let controllers = try SessionExportManager.shared.importSession(from: url, in: effectiveApp)
                return [
                    "imported": .bool(true),
                    "path": .string(path),
                    "windows": .number(Double(controllers.count))
                ]
            } catch let err as SessionExportError {
                switch err {
                case .unsupportedFormatVersion:
                    throw ControlError(.disabled, err.localizedDescription)
                case .invalidSessionFile, .emptySession:
                    throw ControlError(.invalid, err.localizedDescription)
                case .fileNotFound:
                    throw ControlError(.notFound, err.localizedDescription)
                }
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        case "info":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "session info requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)

            do {
                let info = try SessionExportManager.shared.inspectSession(from: url)
                let formatter = ISO8601DateFormatter()
                return [
                    "format_version": .number(Double(info.formatVersion)),
                    "exported_at": .string(formatter.string(from: info.exportedAt)),
                    "tako_version": .string(info.takoVersion),
                    "windows": .number(Double(info.windowCount)),
                    "panes": .number(Double(info.paneCount)),
                    "resumes": .number(Double(info.resumeCount))
                ]
            } catch let err as SessionExportError {
                switch err {
                case .unsupportedFormatVersion:
                    throw ControlError(.disabled, err.localizedDescription)
                case .invalidSessionFile, .emptySession:
                    throw ControlError(.invalid, err.localizedDescription)
                case .fileNotFound:
                    throw ControlError(.notFound, err.localizedDescription)
                }
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        default:
            throw ControlError(.invalid, "unknown session subcommand: \(action)")
        }
    }
}
