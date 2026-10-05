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
import Combine

/// Central store managing in-terminal artifact and document overlays (D1).
///
/// Ensures strict sandboxing of local file access to the pane's working directory,
/// automatically watches files on disk for live reloading, and coordinates overlay
/// presentation across panes and splits.
@MainActor
public final class OverlayStore: ObservableObject {
    public static let shared = OverlayStore()

    /// Active overlays keyed by target pane ID.
    @Published public private(set) var overlays: [UUID: OverlayState] = [:]

    /// Reload tokens changed on file modification to trigger SwiftUI view refreshes.
    @Published public private(set) var reloadTokens: [UUID: UUID] = [:]

    /// Active file watchers keyed by pane ID.
    private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var fileDescriptors: [UUID: Int32] = [:]

    public init() {
        NetworkSandbox.shared.warmUp()
    }

    /// Resets all overlays and cleans up file watchers (for tests/teardown).
    public func reset() {
        for (paneId, _) in overlays {
            stopWatching(paneId: paneId)
        }
        overlays.removeAll()
        reloadTokens.removeAll()
    }

    /// Retrieves the active overlay for a pane, if any.
    public func overlay(for paneId: UUID) -> OverlayState? {
        overlays[paneId]
    }

    /// Whether an overlay is active on the given pane.
    public func hasOverlay(paneId: UUID) -> Bool {
        overlays[paneId] != nil
    }

    /// Opens an overlay for a file on the specified pane.
    @discardableResult
    public func openOverlay(
        paneId: UUID,
        path: String,
        typeString: String? = nil,
        split: String? = nil,
        surfacePwd: String? = nil
    ) throws -> OverlayState {
        // Expand tilde and standardize path
        let expanded = (path as NSString).expandingTildeInPath
        let resolvedPath: String = {
            if expanded.hasPrefix("/") {
                return (expanded as NSString).standardizingPath
            } else if let pwd = surfacePwd, !pwd.isEmpty {
                return ((pwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
            } else {
                return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
            }
        }()

        let rawFileURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL

        // Validate file exists before symlink resolution
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rawFileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw NSError(
                domain: "TakoOverlay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "File does not exist or is a directory: \(path)"]
            )
        }

        // Canonicalize working directory and file path (resolving all symlinks)
        let pwdPath = (surfacePwd != nil && !surfacePwd!.isEmpty) ? surfacePwd! : FileManager.default.currentDirectoryPath
        let sandboxedDirectory = URL(fileURLWithPath: pwdPath).resolvingSymlinksInPath().standardizedFileURL
        let canonicalFileURL = rawFileURL.resolvingSymlinksInPath().standardizedFileURL

        // Strict sandboxing check: file MUST remain beneath the pane working directory
        let canonicalFilePath = canonicalFileURL.path
        let canonicalSandboxPath = sandboxedDirectory.path
        let isContained = canonicalFilePath == canonicalSandboxPath ||
            canonicalFilePath.hasPrefix(canonicalSandboxPath.hasSuffix("/") ? canonicalSandboxPath : canonicalSandboxPath + "/")

        let rawFilePath = rawFileURL.path
        let rawContained = rawFilePath == canonicalSandboxPath ||
            rawFilePath.hasPrefix(canonicalSandboxPath.hasSuffix("/") ? canonicalSandboxPath : canonicalSandboxPath + "/")

        guard isContained && rawContained else {
            throw NSError(
                domain: "TakoOverlay",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Security refusal: path '\(path)' is outside pane working directory sandbox '\(sandboxedDirectory.path)'"]
            )
        }

        let fileURL = canonicalFileURL

        // Determine file type
        let fileType: OverlayFileType = {
            if let ts = typeString?.trimmingCharacters(in: .whitespaces).lowercased(),
               let explicit = OverlayFileType(rawValue: ts) {
                return explicit
            }
            return OverlayFileType.infer(from: fileURL)
        }()

        // Stop prior watcher if this pane had an active overlay
        stopWatching(paneId: paneId)

        let modDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date

        let state = OverlayState(
            paneId: paneId,
            fileURL: fileURL,
            fileType: fileType,
            sandboxedDirectory: sandboxedDirectory,
            splitDirection: split,
            title: fileURL.lastPathComponent,
            lastModified: modDate
        )

        overlays[paneId] = state
        reloadTokens[paneId] = UUID()

        // Start file watcher for live reloading
        startWatching(paneId: paneId, fileURL: fileURL)

        return state
    }

    /// Closes the active overlay on the given pane.
    @discardableResult
    public func closeOverlay(paneId: UUID) -> Bool {
        guard overlays[paneId] != nil else { return false }
        stopWatching(paneId: paneId)
        overlays.removeValue(forKey: paneId)
        reloadTokens.removeValue(forKey: paneId)
        return true
    }

    /// Forces a manual reload of the active overlay for the pane.
    public func reloadOverlay(paneId: UUID) {
        guard var state = overlays[paneId] else { return }
        let modDate = (try? FileManager.default.attributesOfItem(atPath: state.fileURL.path)[.modificationDate]) as? Date
        state.lastModified = modDate
        overlays[paneId] = state
        reloadTokens[paneId] = UUID()
    }

    // MARK: - File Watching & Live Reloading

    private func startWatching(paneId: UUID, fileURL: URL) {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        fileDescriptors[paneId] = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleFileChanged(paneId: paneId)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        fileWatchers[paneId] = source
        source.resume()
    }

    private func stopWatching(paneId: UUID) {
        if let source = fileWatchers.removeValue(forKey: paneId) {
            source.cancel()
        }
        fileDescriptors.removeValue(forKey: paneId)
    }

    private func handleFileChanged(paneId: UUID) {
        guard overlays[paneId] != nil else { return }
        reloadOverlay(paneId: paneId)
    }
}
