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

extension Tako.SurfaceView {
    public func terminalView(
        _ view: TakoTerminalNSView,
        didUpdateProgramStatus event: TerminalProgramStatusEvent
    ) {
        applyProgramStatusEvent(event)
    }

    func acknowledgeProgramStatusOutcome() {
        withdrawAllProgramStatusNotifications()
        notifyProgramStatusAcknowledged()
    }

    func withdrawProgramStatusNotifications(forRecordIDs recordIDs: Set<String>) {
        guard !recordIDs.isEmpty else { return }
        for recordID in recordIDs {
            crab.activeProgramStatusNotificationIDs.remove(recordID)
            if crab.lastProgramStatusNotificationKey?.id == recordID {
                crab.lastProgramStatusNotificationKey = nil
            }
            closeStructuredNotification(
                id: "osc7501-\(id.uuidString)-\(recordID)",
                reportClose: false
            )
        }
    }

    func withdrawAllProgramStatusNotifications() {
        let active = crab.activeProgramStatusNotificationIDs
        guard !active.isEmpty else { return }
        withdrawProgramStatusNotifications(forRecordIDs: active)
    }

    func applyProgramStatusEvent(_ event: TerminalProgramStatusEvent) {
        let snapshot = event.snapshot
        if event.isLiveTransition,
           let prev = crab.lastProgramStatusSnapshot,
           snapshot.revision < prev.revision {
            return
        }
        if window != nil {
            crab.isFocused = isBeingLookedAt
        }
        let previousStatus = crab.paneStatus
        let previousText = crab.statusText
        let previousUnread = crab.unread

        // A restored table brings state back; its status changes are not announced (toasts).
        crab.announcesStatusChanges = event.isLiveTransition
        crab.applyProgramStatusSnapshot(snapshot)
        crab.announcesStatusChanges = true
        syncProgressReportFromProgramStatus(snapshot)
        applyProgramStatusProgressBar(from: snapshot)

        if crab.isFocused {
            withdrawAllProgramStatusNotifications()
        } else if !crab.activeProgramStatusNotificationIDs.isEmpty {
            let stillNotifiable = Set(
                snapshot.records
                    .filter { [.blocked, .done, .error].contains($0.state) }
                    .map(\.id)
            )
            let resolved = crab.activeProgramStatusNotificationIDs.subtracting(stillNotifiable)
            withdrawProgramStatusNotifications(forRecordIDs: resolved)
        }

        if event.isLiveTransition, !crab.isFocused, let effective = snapshot.effective {
            maybePostProgramStatusNotification(for: effective)
        }

        if crab.paneStatus != previousStatus
            || crab.statusText != previousText
            || crab.unread != previousUnread {
            (NSApp?.delegate as? AppDelegate)?.setDockBadge()
            Tako.TabBarController.requestRefresh()
            publishEvent(
                type: "status",
                payload: [
                    "status": .string(crab.paneStatus.rawValue),
                    "status_text": crab.statusText.map(JSON.string) ?? .null,
                    "unread": .bool(crab.unread)
                ]
            )
        }
    }

    private func syncProgressReportFromProgramStatus(_ snapshot: TerminalProgramStatusSnapshot) {
        let nextReport: Tako.Action.ProgressReport?
        if let effective = snapshot.effective {
            switch effective.state {
            case .working:
                if let pct = effective.progress {
                    nextReport = .init(state: .set, progress: pct)
                } else {
                    nextReport = .init(state: .indeterminate, progress: nil)
                }
            case .blocked:
                nextReport = .init(state: .pause, progress: effective.progress ?? 100)
            case .error:
                nextReport = .init(state: .error, progress: 100)
            case .done, .idle:
                nextReport = nil
            }
        } else {
            nextReport = nil
        }
        if progressReport != nextReport {
            progressReport = nextReport
        }
    }

    private func maybePostProgramStatusNotification(for effective: TerminalProgramStatusRecord) {
        guard [.blocked, .done, .error].contains(effective.state) else { return }
        let key = Tako.ProgramStatusNotificationKey(
            id: effective.id,
            state: effective.state,
            kind: effective.kind,
            title: effective.title,
            msg: effective.msg
        )
        guard crab.lastProgramStatusNotificationKey != key else { return }
        crab.lastProgramStatusNotificationKey = key
        crab.activeProgramStatusNotificationIDs.insert(effective.id)

        let appLabel = effective.resolvedApp ?? effective.app
        let notifTitle = Self.programStatusNotificationTitle(for: effective, appLabel: appLabel)
        let notifBody = effective.msg ?? effective.displayMessage ?? self.title
        let urgency: UInt8 = (effective.state == .done) ? 1 : 2
        let event: ActivityEvent? = switch effective.state {
        case .blocked: .needsYou
        case .done: .done
        case .error: .failed
        default: nil
        }

        postStructuredNotification(
            id: "osc7501-\(id.uuidString)-\(effective.id)",
            title: notifTitle,
            body: notifBody,
            appName: appLabel,
            urgency: urgency,
            actions: [],
            reportActivation: false,
            focus: true,
            reportClose: false,
            timeoutMs: nil,
            onlyWhenUnfocused: true,
            activitySound: .forProgramNow(event, lookedAt: isBeingLookedAt, muted: AttentionManager.shared.isMuted(surfaceId: id),
                                          preferences: DesktopPresentation.shared.preferences)
        )
    }

    private static func programStatusNotificationTitle(
        for record: TerminalProgramStatusRecord,
        appLabel: String?
    ) -> String {
        if let explicitTitle = record.title, !explicitTitle.isEmpty {
            if let appLabel, !appLabel.isEmpty {
                return "\(appLabel): \(explicitTitle)"
            }
            return explicitTitle
        }
        let prefix = (appLabel?.isEmpty == false) ? appLabel! : nil
        switch record.state {
        case .blocked:
            switch record.kind {
            case .permission:
                return prefix.map { "\($0) needs permission" } ?? "Permission required"
            case .auth:
                return prefix.map { "\($0) needs authentication" } ?? "Authentication required"
            case .question, .none:
                return prefix.map { "\($0) needs input" } ?? "Input required"
            }
        case .done:
            return prefix.map { "\($0) finished" } ?? "Task finished"
        case .error:
            return prefix.map { "\($0) reported an error" } ?? "Task failed"
        case .working, .idle:
            return prefix ?? "Tako"
        }
    }
}
