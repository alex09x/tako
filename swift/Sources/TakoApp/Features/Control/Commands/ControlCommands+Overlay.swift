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
    /// Handles `takoctl overlay open|close|status|reload` (D1).
    static func overlayCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "overlay")
        let sub = (try? ControlInput.text(request.args, "subcommand")) ?? "status"

        switch sub {
        case "open":
            guard let file = request.args["file"]?.string, !file.isEmpty else {
                throw ControlError(.invalid, "missing \"file\" argument")
            }
            let typeStr = request.args["type"]?.string
            let splitDir = request.args["split"]?.string
            let surfacePwd = surface.pwd

            let targetPane: Tako.SurfaceView
            if let dir = splitDir {
                // Open overlay in a new split pane beside target
                let createdPane = try ControlLayout.split(surface, args: [
                    "direction": .string(dir),
                    "label": .string("overlay: \(file)")
                ])
                targetPane = createdPane
            } else {
                targetPane = surface
            }

            do {
                let state = try OverlayStore.shared.openOverlay(
                    paneId: targetPane.id,
                    path: file,
                    typeString: typeStr,
                    split: splitDir,
                    surfacePwd: surfacePwd
                )
                var dict: [String: JSON] = [
                    "id": .string(targetPane.id.uuidString.lowercased()),
                    "target": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(true),
                    "file": .string(state.fileURL.path),
                    "title": .string(state.title),
                    "type": .string(state.fileType.rawValue),
                    "sandboxed": .string(state.sandboxedDirectory.path),
                ]
                if let s = splitDir {
                    dict["split"] = .string(s)
                }
                return dict
            } catch {
                throw ControlError(.invalid, error.localizedDescription)
            }

        case "close":
            let closed = OverlayStore.shared.closeOverlay(paneId: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "closed": .bool(closed)
            ]

        case "status":
            if let state = OverlayStore.shared.overlay(for: surface.id) {
                var dict: [String: JSON] = [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(true),
                    "file": .string(state.fileURL.path),
                    "title": .string(state.title),
                    "type": .string(state.fileType.rawValue),
                    "sandboxed": .string(state.sandboxedDirectory.path),
                ]
                if let s = state.splitDirection {
                    dict["split"] = .string(s)
                }
                return dict
            } else {
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(false)
                ]
            }

        case "reload":
            OverlayStore.shared.reloadOverlay(paneId: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "reloaded": .bool(true)
            ]

        default:
            throw ControlError(.invalid, "unknown overlay subcommand: \(sub)")
        }
    }
}
