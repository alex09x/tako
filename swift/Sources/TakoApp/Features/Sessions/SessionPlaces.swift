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

/// Where session state lives. TAKO_SESSIONS_HOME moves the namespace for the
/// isolated e2e profile; records and runtimes follow the app's own
/// Application Support, which a separate bundle id keeps apart.
enum SessionPlaces {
    static var support: URL { SessionSnapshotStore.shared.directory.deletingLastPathComponent() }
    static var records: SessionRecordStore {
        SessionRecordStore(directory: support.appendingPathComponent("SessionRecords", isDirectory: true))
    }
    static var registry: SessionRuntimeRegistry { SessionRuntimeRegistry(root: support) }
    static var home: URL {
        ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
