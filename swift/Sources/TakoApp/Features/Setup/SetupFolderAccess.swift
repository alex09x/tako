/*
 * tako — User-selected folder access checks
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

struct SetupFolderAccessResult: Sendable {
    let folder: URL
    let status: TerminalPermissionStatus
    var readable: Bool { status == .allowed }
}

@MainActor
struct SetupFolderAccess {
    var folders: [URL] = [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory].compactMap {
        FileManager.default.urls(for: $0, in: .userDomainMask).first
    }
    var check: @Sendable (URL) -> SetupFolderAccessResult = { folder in
        // Opening the directory may trigger macOS consent. Never enumerate names
        // or open a file. Run only after the user presses Check file access.
        if let directory = opendir(folder.path) {
            closedir(directory)
            return SetupFolderAccessResult(folder: folder, status: .allowed)
        }
        let code = errno
        let status: TerminalPermissionStatus = code == EPERM || code == EACCES ? .notAllowed : .unknown
        return SetupFolderAccessResult(folder: folder, status: status)
    }

    func checkStandardFolders() async -> [SetupFolderAccessResult] {
        let checker = check
        let targets = folders
        return await Task.detached(priority: .userInitiated) { targets.map(checker) }.value
    }
}
