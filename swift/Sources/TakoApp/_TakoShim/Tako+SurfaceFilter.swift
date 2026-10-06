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
import UserNotifications

extension Tako.SurfaceView {
        /// Whether attention notifications and rings are muted for this pane (B7).
        /// When muted, the pane stops raising attention without losing its status or progress.
        public var isAttentionMuted: Bool {
            get { AttentionManager.shared.isMuted(surfaceId: id) }
            set {
                AttentionManager.shared.setMuted(newValue, for: id)
                objectWillChange.send()
            }
        }

        public func toggleAttentionMute() {
            AttentionManager.shared.toggleMute(for: id)
            objectWillChange.send()
        }

        public func writePtyReply(_ text: String) {
            if let onPtyReply = onPtyReply {
                onPtyReply(text)
            } else if selfTestCapturing {
                selfTestBytes += [UInt8](text.utf8)
            } else {
                pty?.write(Data(text.utf8))
            }
        }

        public func postStructuredNotification(
            id: String?,
            title: String,
            body: String,
            appName: String?,
            urgency: UInt8,
            actions: [String],
            reportActivation: Bool,
            focus: Bool,
            reportClose: Bool,
            timeoutMs: UInt64?,
            onlyWhenUnfocused: Bool
        ) {
            let action = NotificationCoalescer.shared.process(
                surfaceId: self.id,
                title: title,
                body: body
            )

            switch action {
            case .duplicateSuppressed:
                return

            case .coalesce(let count):
                let reqId = "tako-notif-coalesced-\(self.id.uuidString)"
                let coalesceTitle = title.isEmpty ? "Notifications Coalesced" : title
                let coalesceBody = "\(count) notifications from this pane were coalesced."
                NotificationStore.shared.addNotification(
                    id: id,
                    surfaceId: self.id,
                    paneTitle: self.title,
                    title: coalesceTitle,
                    body: coalesceBody,
                    urgency: urgency,
                    unread: !self.isBeingLookedAt
                )
                let content = Tako.buildNotificationContent(
                    title: coalesceTitle,
                    body: coalesceBody,
                    appName: appName,
                    surfaceId: self.id,
                    paneTitle: self.title,
                    pwd: self.pwd,
                    command: self.activeRunningCommandText ?? self.runProgram?.joined(separator: " "),
                    id: id,
                    urgency: urgency,
                    actions: actions,
                    reportActivation: reportActivation,
                    focus: focus,
                    reportClose: reportClose,
                    onlyWhenUnfocused: onlyWhenUnfocused,
                    coalescedCount: count
                )
                let request = UNNotificationRequest(identifier: reqId, content: content, trigger: nil)
                AppDelegate.notificationCenterProvider()?.add(request)
                Tako.onNotificationPosted?(request)
                return

            case .postNormal:
                NotificationStore.shared.addNotification(
                    id: id,
                    surfaceId: self.id,
                    paneTitle: self.title,
                    title: title,
                    body: body,
                    urgency: urgency,
                    unread: !self.isBeingLookedAt
                )

                let reqId: String
                if let id = id, !id.isEmpty {
                    reqId = "tako-notif-\(self.id.uuidString)-\(id)"
                } else {
                    reqId = "tako-notif-\(self.id.uuidString)-\(UUID().uuidString)"
                }

                let content = Tako.buildNotificationContent(
                    title: title,
                    body: body,
                    appName: appName,
                    surfaceId: self.id,
                    paneTitle: self.title,
                    pwd: self.pwd,
                    command: self.activeRunningCommandText ?? self.runProgram?.joined(separator: " "),
                    id: id,
                    urgency: urgency,
                    actions: actions,
                    reportActivation: reportActivation,
                    focus: focus,
                    reportClose: reportClose,
                    onlyWhenUnfocused: onlyWhenUnfocused
                )

                let request = UNNotificationRequest(identifier: reqId, content: content, trigger: nil)
                AppDelegate.notificationCenterProvider()?.add(request)
                Tako.onNotificationPosted?(request)

                if let timeoutMs = timeoutMs, timeoutMs > 0 {
                    let delay = Double(timeoutMs) / 1000.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self else { return }
                        AppDelegate.notificationCenterProvider()?.removeDeliveredNotifications(withIdentifiers: [reqId])
                        AppDelegate.notificationCenterProvider()?.removePendingNotificationRequests(withIdentifiers: [reqId])
                        Tako.onNotificationRemoved?([reqId])
                        if reportClose {
                            let replyId = id ?? "0"
                            let reply = "\u{1b}]99;i=\(replyId):p=close;\u{1b}\\"
                            self.writePtyReply(reply)
                        }
                    }
                }
            }

            self.publishEvent(
                type: "notification",
                payload: [
                    "id": id.map(JSON.string) ?? .null,
                    "title": .string(title),
                    "body": .string(body),
                    "urgency": .number(Double(urgency)),
                    "action": .string("posted")
                ]
            )
        }

        public func closeStructuredNotification(id: String, reportClose: Bool) {
            let reqId = "tako-notif-\(self.id.uuidString)-\(id)"
            AppDelegate.notificationCenterProvider()?.removeDeliveredNotifications(withIdentifiers: [reqId])
            AppDelegate.notificationCenterProvider()?.removePendingNotificationRequests(withIdentifiers: [reqId])
            Tako.onNotificationRemoved?([reqId])
            if reportClose {
                let reply = "\u{1b}]99;i=\(id):p=close;\u{1b}\\"
                writePtyReply(reply)
            }
            self.publishEvent(
                type: "notification",
                payload: [
                    "id": .string(id),
                    "action": .string("closed")
                ]
            )
        }

        /// How many finished commands signalled; for tests.
        // MARK: - Output Filtering / Focus Mode (E5)

        public func openOutputFilter() {
            let total = Int(core.scrollbackLen() + core.rows())
            let state = OutputFilterState(
                query: outputFilterQuery,
                isRegex: outputFilterIsRegex,
                matchCount: outputFilterMatchingLines.count,
                totalCount: total
            )
            outputFilterState = state
            onOutputFilterChanged = { [weak self, weak state] active, matchCount, totalCount in
                guard let self, let state else { return }
                DispatchQueue.main.async {
                    state.matchCount = matchCount
                    state.totalCount = totalCount
                    self.objectWillChange.send()
                }
            }
            if !state.query.isEmpty {
                setOutputFilter(query: state.query, isRegex: state.isRegex)
            }
            objectWillChange.send()
        }

        public func updateOutputFilter(query: String, isRegex: Bool) {
            setOutputFilter(query: query, isRegex: isRegex)
            outputFilterState?.matchCount = outputFilterMatchingLines.count
            outputFilterState?.totalCount = Int(core.scrollbackLen() + core.rows())
            objectWillChange.send()
        }

        public func closeOutputFilter() {
            clearOutputFilter()
            outputFilterState = nil
            onOutputFilterChanged = nil
            objectWillChange.send()
        }

        func cancelPendingSearchHitRefresh() {
            searchHitDebounceItem?.cancel()
            searchHitDebounceItem = nil
            searchHitBurstStartTime = 0
        }

        /// Bounded-delay debounced search hit refresh to prevent walking all scrollback
        /// on every live output batch while avoiding starvation during continuous output.
        func scheduleSearchHitRefresh() {
            guard let searchState, !searchState.needle.isEmpty else {
                cancelPendingSearchHitRefresh()
                if !searchHitRetainedRows.isEmpty {
                    searchHitRetainedRows = []
                }
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            let maxInterval: TimeInterval = 0.35
            let debounceDelay: TimeInterval = 0.15

            if searchHitDebounceItem != nil {
                if now - searchHitBurstStartTime >= maxInterval {
                    // Maximum interval reached: let the pending item execute without postponing it,
                    // preventing starvation when a process emits high-frequency output.
                    return
                }
                searchHitDebounceItem?.cancel()
            } else {
                searchHitBurstStartTime = now
            }

            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.searchHitDebounceItem = nil
                    self?.searchHitBurstStartTime = 0
                    self?.refreshSearchHitRows()
                }
            }
            searchHitDebounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: item)
        }

        func updateActiveRegexTriggers(config: Tako.Config? = nil) {
            let activeConfig = config ?? owningApp?.config
            guard activeConfig?.passiveRegexTriggers ?? true else {
                regexTriggers = []
                return
            }
            if let cfg = config {
                PassiveTriggerStore.shared.setConfigTriggers(cfg.triggers)
            }
            regexTriggers = PassiveTriggerStore.shared.allTriggers
        }


        func setupAttentionObservation() {
            crab.$paneStatus.dropFirst().sink { [weak self] status in
                guard let self else { return }
                if status == .error || status == .needsApproval || status == .waitingForInput {
                    AttentionManager.shared.recordAttentionEvent(for: self.id)
                }
            }.store(in: &attentionCancellables)

            crab.$unread.dropFirst().sink { [weak self] isUnread in
                guard let self else { return }
                if isUnread {
                    AttentionManager.shared.recordAttentionEvent(for: self.id)
                }
            }.store(in: &attentionCancellables)

            crab.$state.dropFirst().sink { [weak self] state in
                guard let self else { return }
                if state == .attention {
                    AttentionManager.shared.recordAttentionEvent(for: self.id)
                }
            }.store(in: &attentionCancellables)
        }

        func setupPassiveRegexTriggers() {
            onTriggerMatched = { [weak self] trigger, matchedText, row in
                guard let self else { return }
                PassiveTriggerStore.shared.handleMatch(
                    surfaceId: self.id,
                    paneTitle: self.title,
                    pwd: self.pwd,
                    trigger: trigger,
                    matchedText: matchedText,
                    isUnfocused: !self.isBeingLookedAt
                )
            }
            triggersObserver = NotificationCenter.default.addObserver(
                forName: .passiveTriggersDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.updateActiveRegexTriggers() }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.updateActiveRegexTriggers() }
                    }
                }
            }
            updateActiveRegexTriggers()
        }
}
