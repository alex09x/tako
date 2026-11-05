/*
 * tako — User-selected folder access checks
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

struct SetupFolderAccessResult: Sendable {
    let folder: URL
    let readable: Bool
    let message: String
}

@MainActor
struct SetupFolderAccess {
    var choose: () async -> URL? = {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("SetupFolderChooser")
        panel.setAccessibilityIdentifier("SetupFolderChooser")
        panel.title = "Choose a folder to check"
        panel.message = "Check whether this copy of Tako can read the folder you choose. This does not grant access to every folder or terminal program."
        panel.prompt = "Check folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let host = NSApp.keyWindow {
                panel.beginSheetModal(for: host, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }
    var check: @Sendable (URL) -> SetupFolderAccessResult = { folder in
        do {
            // Only the folder explicitly selected by the user. Names are discarded,
            // never logged or returned; no private location is probed implicitly.
            _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return SetupFolderAccessResult(folder: folder, readable: true,
                message: "Tako can read the selected folder: \(folder.path). Terminal programs must be checked separately.")
        } catch {
            return SetupFolderAccessResult(folder: folder, readable: false,
                message: "Tako couldn't read the selected folder: \(error.localizedDescription)")
        }
    }

    func chooseAndCheck() async -> SetupFolderAccessResult? {
        guard let folder = await choose(), folder.isFileURL else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let checker = check
        return await Task.detached(priority: .userInitiated) { checker(folder) }.value
    }
}
