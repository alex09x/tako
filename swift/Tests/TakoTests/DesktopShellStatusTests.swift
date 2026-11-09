/*
 * tako — Shell scheme, status visibility/motion and sidebar counter tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

/// Touches process-wide state (LivingTokens.isLight, LivingAnimationState):
/// serialized, and every test puts the state back.
@Suite(.serialized)
@MainActor
struct DesktopShellStatusTests {
    private func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB)!
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    private func prefs(_ values: [String: String]) -> DesktopPreferences { DesktopPreferences { values[$0] } }

    @Test func shellRolesFollowTheSchemeAndStatusColoursDoNot() {
        let before = Tako.LivingTokens.isLight
        defer { Tako.LivingTokens.isLight = before }
        Tako.LivingTokens.isLight = false
        #expect(hex(Tako.LivingTokens.body) == "#14100e", "dark shell keeps the 1b values")
        #expect(hex(Tako.LivingTokens.textActive) == "#faf7f2")
        Tako.LivingTokens.isLight = true
        // The frozen reference's light shell (tokens-light.json).
        #expect(hex(Tako.LivingTokens.body) == "#efede7")
        #expect(hex(Tako.LivingTokens.surfaceActive) == "#eae7e2")
        #expect(hex(Tako.LivingTokens.hairline) == "#d9d7d1")
        #expect(hex(Tako.LivingTokens.textActive) == "#262320")
        #expect(hex(Tako.LivingTokens.textInactive) == "#5c5a56")
        // Status and accent colours are the same in every scheme.
        #expect(hex(Tako.LivingTokens.dim) == "#8a7f76")
        #expect(hex(Tako.LivingTokens.claw) == "#ff7a3d")
        #expect(hex(Tako.LivingTokens.error) == "#d54e53")
        #expect(hex(Tako.LivingTokens.ok) == "#7bd88f")
    }

    @Test func aTestsOwnPresentationNeverFlipsTheProcessShell() {
        let before = Tako.LivingTokens.isLight
        defer { Tako.LivingTokens.isLight = before }
        let local = DesktopPresentation(observe: false, systemIsDark: true)
        local.apply(prefs(["app-appearance": "light"]))
        #expect(!local.isDark)
        #expect(Tako.LivingTokens.isLight == before)
    }

    @Test func statusSettingsChangeOnlyWhatIsDrawn() {
        let anim = LivingAnimationState.shared
        defer { anim.applyStatusPreferences(prefs([:])) }
        anim.applyStatusPreferences(prefs([:]))
        #expect(anim.displayedStatus(.waiting) == .waiting)
        #expect(!anim.statusRests(reduceMotion: false))
        #expect(anim.statusRests(reduceMotion: true), "Reduce Motion always rests")

        anim.applyStatusPreferences(prefs(["status-animate": "false"]))
        #expect(anim.displayedStatus(.working) == .working, "same colours")
        #expect(anim.statusRests(reduceMotion: false), "without motion")

        anim.applyStatusPreferences(prefs(["status-show": "false"]))
        #expect(anim.displayedStatus(.waiting) == .idle)
        #expect(anim.displayedStatus(.failed) == .idle)
        let idle = hex(Tako.tabStatusColor(for: Tako.PaneStatus.idle.dotKey))
        #expect(hex(FloatingPaneGeometry.statusNSColor(for: .error)) == idle, "the header dot stays calm")
        #expect(hex(FloatingPaneGeometry.statusNSColor(for: .needsApproval)) == idle)

        anim.applyStatusPreferences(prefs([:]))
        #expect(hex(FloatingPaneGeometry.statusNSColor(for: .error)) != idle)
    }

    @Test func sidebarCountsSortPaneStatusesAndNameEnabledCounters() {
        typealias S = SessionSidebarStore
        #expect(S.attentionKind(.waitingForInput) == .waiting)
        #expect(S.attentionKind(.needsApproval) == .waiting, "question and approval are one status")
        #expect(S.attentionKind(.error) == .error)
        #expect(S.attentionKind(.done) == .done)
        #expect(S.attentionKind(.working) == .other && S.attentionKind(.idle) == .other)

        let a = UUID(), b = UUID(), c = UUID()
        let all = prefs([:])
        // b appears twice (a session row and its pane row) and counts once.
        let counts = SidebarAttentionCounts(panes: [(a, .waiting), (b, .waiting), (b, .waiting), (c, .done)],
                                            unread: [c], preferences: all)
        #expect(counts.waiting == 2 && counts.errors == 0 && counts.unreadDone == 1)
        #expect(SessionSidebarCountsLabel.value(counts, all) == "waiting=2 error=0 done=1")
        let noErrors = prefs(["sidebar-count-error": "false"])
        #expect(SessionSidebarCountsLabel.value(counts, noErrors) == "waiting=2 done=1")
    }
}
