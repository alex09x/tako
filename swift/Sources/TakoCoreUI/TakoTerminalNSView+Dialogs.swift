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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    nonisolated(unsafe) public static var openURL: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    nonisolated(unsafe) public static var presentAlert: @MainActor (_ alert: NSAlert, _ window: NSWindow?) -> Void = { alert, window in
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    public static func reportSaveError(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        alert.messageText = "Failed to Save Output"
        alert.informativeText = error.localizedDescription
        DispatchQueue.main.async {
            presentAlert(alert, window)
        }
    }

    nonisolated(unsafe) public static var saveFilePanel: @MainActor (
        _ text: String,
        _ suggestedFilename: String,
        _ window: NSWindow?,
        _ completion: @escaping (URL?) -> Void
    ) -> Void = { text, suggestedFilename, window, completion in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.prompt = "Save"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let targetURL = panel.url else {
                completion(nil)
                return
            }
            do {
                try text.write(to: targetURL, atomically: true, encoding: .utf8)
                completion(targetURL)
            } catch {
                reportSaveError(error, window: window)
                completion(nil)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    nonisolated(unsafe) public static var confirmOpenURL: @MainActor (
        _ url: URL,
        _ warning: LinkSecurityWarning,
        _ window: NSWindow?,
        _ completion: @escaping (Bool) -> Void
    ) -> Void = { url, warning, window, completion in
        let alert = NSAlert()
        switch warning {
        case .unsafeScheme(let scheme):
            alert.messageText = "Open External Application?"
            alert.informativeText = "This link uses the \"\(scheme)\" protocol:\n\n\(url.absoluteString)\n\nOpening it will launch an external application."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
        case .urlMismatch(let displayedText, let targetURL):
            alert.messageText = "Suspicious Link Destination"
            alert.informativeText = "The visible link text appears to point to:\n\(displayedText)\n\nHowever, the real destination is:\n\(targetURL.absoluteString)\n\nAre you sure you want to open this link?"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Anyway")
        case .unconfirmedDestination(let targetURL):
            alert.messageText = "Open Link?"
            alert.informativeText = "Are you sure you want to open this link?\n\n\(targetURL.absoluteString)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                switch warning {
                case .unsafeScheme, .unconfirmedDestination:
                    completion(response == .alertFirstButtonReturn)
                case .urlMismatch:
                    completion(response == .alertSecondButtonReturn)
                }
            }
        } else {
            let response = alert.runModal()
            switch warning {
            case .unsafeScheme, .unconfirmedDestination:
                completion(response == .alertFirstButtonReturn)
            case .urlMismatch:
                completion(response == .alertSecondButtonReturn)
            }
        }
    }
}
#endif
