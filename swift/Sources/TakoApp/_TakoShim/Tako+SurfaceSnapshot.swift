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
import SwiftUI

extension Tako.SurfaceView {
        func exportSnapshotState(maxBytes: UInt64, unlessGeneration generation: UInt64?) -> SnapshotExport {
            guard !self.isSecureInput && !SecureInput.shared.isSecure(for: self) else {
                return .tooLarge
            }
            let current = generationLock.withLock { contentGeneration }
            guard current != generation else { return .unchanged }
            guard let blob = try? core.checkpointExport(flags: 0, maxBytes: maxBytes) else { return .tooLarge }
            return .exported(blob, generation: current)
        }

        /// Full scrollback text, recomputed on demand. Upstream caches it
        /// because Shortcuts and Accessibility can ask for it repeatedly.
        func showSnapshot(_ snapshot: SessionSnapshot) {
            guard (try? core.checkpointImport(blob: snapshot.checkpoint)) != nil else { return }
            // Painted at the saved size; the first layout resizes it to the
            // window like any other grid. Resizing here, before there is a
            // frame, would squeeze the saved screen into a 1x1 grid.
            if core.modes().alternateScreen {
                core.feed(bytes: Data(SessionSnapshot.leaveAlternateScreen))
            }
            core.feed(bytes: Data(SessionSnapshot.separator(
                savedAt: snapshot.savedAt, cursorRow: core.cursorRow(), cursorCol: core.cursorCol())))
        }

        /// The process ended. A persistent session's client may end on
        /// purpose (a reattach check); only otherwise is the surface closed.
        func childDidExit(_ process: PTY?) {
            // Only the current process decides: one replaced since (a
            // reattach check, a session that started anew) is history.
            guard let process, process === pty else { return }
            self.progressReport = nil
            self.crab.progressReported(state: 0, value: nil)
            self.updateProgressBar(state: .none, progress: nil)
            (NSApp.delegate as? AppDelegate)?.setDockBadge()
            Tako.TabBarController.refreshAll()
            if persistence?.clientExited(self) == true { return }
            onExit?(self)
        }

        /// The app this surface belongs to, for the session code.
        // MARK: - Resume Agent Sessions (Track C6)

        public func checkAndApplyResumeOnRestore(restoredDir: String?) {
            guard let record = ResumeSessionStore.shared.record(for: id) else { return }
            let dir = record.cwd.isEmpty ? (restoredDir ?? "") : record.cwd
            if !record.isImported && ResumeTrustStore.shared.isApproved(argv: record.argv, cwd: dir) {
                executeResume(record: record)
            } else {
                showResumeBanner(record: record, dir: dir)
            }
        }

        public func showResumeBanner(record: ResumeSessionRecord, dir: String) {
            guard resumeBannerHostingView == nil else { return }
            let cmdLine = record.argv.joined(separator: " ")
            let banner = ResumeBannerView(
                command: cmdLine,
                cwd: dir,
                isImported: record.isImported,
                onResume: { [weak self] alwaysAllow in
                    guard let self else { return }
                    if alwaysAllow {
                        let cmdString = record.argv.map { ResumeSessionStore.shellQuote($0) }.joined(separator: " ")
                        ResumeTrustStore.shared.approve(prefix: cmdString, cwd: dir)
                    }
                    self.dismissResumeBanner()
                    self.executeResume(record: record)
                },
                onDismiss: { [weak self] in
                    self?.dismissResumeBanner()
                }
            )
            let hosting = NSHostingView(rootView: banner)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                hosting.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            ])
            self.resumeBannerHostingView = hosting
        }

        public func dismissResumeBanner() {
            resumeBannerHostingView?.removeFromSuperview()
            resumeBannerHostingView = nil
        }

        public func executeResume(record: ResumeSessionRecord) {
            guard !record.argv.isEmpty else { return }
            let cmdString = record.argv.map { ResumeSessionStore.shellQuote($0) }.joined(separator: " ")
            sendText(cmdString + "\n")
        }

        static func decodeRestorationConfig(
            savedID: String?,
            savedPwd: String?,
            persistent: Bool
        ) -> (Tako.App?, Tako.SurfaceConfiguration, UUID) {
            let app = (NSApp?.delegate as? AppDelegate)?.tako
            let uuid = savedID.flatMap(UUID.init(uuidString:))
            var base = Tako.SurfaceConfiguration()
            base.isRestored = uuid != nil
            base.hadPersistentSession = persistent
            base.workingDirectory = Self.restoredWorkingDirectory(
                savedPwd, fallback: app.map { Tako.resolvedWorkingDirectory($0.config) })
            if let uuid, app?.config.windowSaveContent ?? true {
                base.restoredSnapshot = SessionSnapshotStore.shared.read(id: uuid)
            }
            return (app, base, uuid ?? UUID())
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(describing: id), forKey: .id)
            try container.encodeIfPresent(pwd, forKey: .pwd)
            if hadPersistentSession { try container.encode(true, forKey: .persistent) }
        }

        /// Where a restored surface's new shell starts: the directory its old
        /// shell reported, if it still exists; otherwise the configured one,
        /// or home. Never the focused tab's -- that would put a restored tab
        /// somewhere it never was.
        static func restoredWorkingDirectory(_ saved: String?, fallback: String?) -> String {
            var isDirectory: ObjCBool = false
            if let saved, FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return saved
            }
            return fallback ?? NSHomeDirectory()
        }

}
