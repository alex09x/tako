/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

/// Sweeps orphan, abandoned, or stale persistent sessions across ~/.tako-sessions.
/// A session is an orphan when its owner lock is unheld and it is not among the
/// live surfaces of this running Tako process.
enum SessionSweeper {
    /// Sweeps orphan sessions in the background.
    /// - Parameters:
    ///   - home: The root directory hosting `.tako-sessions` (usually `SessionPlaces.home`).
    ///   - activeNames: The set of session names currently owned by active windows.
    ///   - registry: The session runtime registry to find executables.
    static func sweepOrphans(
        home: URL = SessionPlaces.home,
        activeNames: Set<String>,
        registry: SessionRuntimeRegistry = SessionPlaces.registry
    ) {
        let base = home.appendingPathComponent(".tako-sessions", isDirectory: true)
        guard let runtimeDirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return
        }

        for dir in runtimeDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            sweepRuntimeDirectory(dir, activeNames: activeNames, registry: registry)
        }
    }

    private static func sweepRuntimeDirectory(
        _ dir: URL,
        activeNames: Set<String>,
        registry: SessionRuntimeRegistry
    ) {
        let runtimeID = (try? String(contentsOf: dir.appendingPathComponent("runtime-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runtimeExe = runtimeID.flatMap { try? registry.executable(for: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zmx")

        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in entries {
            let name = file.lastPathComponent
            // Only examine session names (32 hex characters)
            guard name.count == 32 && name.allSatisfy({ $0.isHexDigit }) else { continue }
            guard !activeNames.contains(name) else { continue }

            let ownerPath = dir.appendingPathComponent("\(name).owner").path
            let fd = Darwin.open(ownerPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { continue }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd)
                continue
            }

            defer {
                flock(fd, LOCK_UN)
                Darwin.close(fd)
            }

            // Session is unowned. Terminate it via runtime kill if possible.
            let env = ["ZMX_DIR": dir.path, "ZMX_NO_DETACH_KEY": "1"]
            if FileManager.default.isExecutableFile(atPath: runtimeExe.path) {
                _ = RuntimeCommand.run(runtimeExe, ["kill", name, "--force"], environment: env, timeout: 2)
            }

            // Clean up any remaining socket and owner files
            let socketPath = dir.appendingPathComponent(name).path
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: ownerPath)
            try? FileManager.default.removeItem(atPath: dir.appendingPathComponent("absent-\(name)").path)
        }
    }
}
