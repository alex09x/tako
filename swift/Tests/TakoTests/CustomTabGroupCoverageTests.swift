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
import Testing
@testable import Tako

// MARK: - CustomTabGroup

@Suite(.serialized)
@MainActor
struct CustomTabGroupCoverageTests {
    @Test func freshWindowGetsASingleWindowGroup() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }

        let group = Tako.CustomTabGroup.group(for: window)
        #expect(group.windows == [window])
        #expect(group.selectedWindow === window)
        // Asking again returns the same group instance.
        #expect(Tako.CustomTabGroup.group(for: window) === group)
    }

    @Test func joinAddsToAnchorsGroupAndSelects() {
        let anchor = makeWindow(title: "anchor")
        let joined = makeWindow(title: "joined")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(joined)
        }

        Tako.CustomTabGroup.join(joined, to: anchor, select: true)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows == [anchor, joined])
        #expect(group.selectedWindow === joined)
        #expect(joined.frame == anchor.frame)
    }

    @Test func joinWithoutSelectingOrdersOutTheNewWindow() {
        let anchor = makeWindow(title: "anchor")
        let joined = makeWindow(title: "joined")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(joined)
        }

        Tako.CustomTabGroup.join(joined, to: anchor, select: false)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.selectedWindow === anchor)
        #expect(!joined.isVisible)
    }

    @Test func joinTwiceIsANoOpForMembershipButCanReselect() {
        let anchor = makeWindow(title: "anchor")
        let joined = makeWindow(title: "joined")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(joined)
        }

        Tako.CustomTabGroup.join(joined, to: anchor, select: false)
        Tako.CustomTabGroup.join(joined, to: anchor, select: true)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows == [anchor, joined])
        #expect(group.selectedWindow === joined)
    }

    @Test func insertAtClampedIndex() {
        let anchor = makeWindow(title: "anchor")
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            for window in [anchor, a, b] { Tako.CustomTabGroup.leave(window) }
        }

        Tako.CustomTabGroup.insert(a, into: anchor, at: 0, select: false)
        Tako.CustomTabGroup.insert(b, into: anchor, at: 99, select: true)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows == [a, anchor, b])
        #expect(group.selectedWindow === b)
    }

    @Test func insertExistingWindowIsANoOp() {
        let anchor = makeWindow(title: "anchor")
        let a = makeWindow(title: "a")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(a)
        }

        Tako.CustomTabGroup.insert(a, into: anchor, at: 0, select: false)
        Tako.CustomTabGroup.insert(a, into: anchor, at: 1, select: false)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows.count == 2)
    }

    @Test func leaveRemovesAndSelectsTheFollowingNeighbor() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        let c = makeWindow(title: "c")
        defer {
            for window in [a, b, c] { Tako.CustomTabGroup.leave(window) }
        }

        Tako.CustomTabGroup.join(b, to: a, select: false)
        Tako.CustomTabGroup.join(c, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        group.select(b)
        #expect(group.selectedWindow === b)

        Tako.CustomTabGroup.leave(b)
        #expect(group.windows == [a, c])
        #expect(group.selectedWindow === c)
    }

    @Test func leaveTheLastTabFallsBackToTheNewLastTab() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }

        Tako.CustomTabGroup.join(b, to: a, select: true)
        Tako.CustomTabGroup.leave(b)
        let group = Tako.CustomTabGroup.group(for: a)
        #expect(group.windows == [a])
        #expect(group.selectedWindow === a)
    }

    @Test func leaveOfAnUnregisteredWindowIsANoOp() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        let stray = makeWindow(title: "stray")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        Tako.CustomTabGroup.leave(stray) // Never joined/grouped -- must not crash or affect an unrelated group.

        #expect(group.windows == [a, b])
        #expect(group.selectedWindow === a)
    }

    @Test func leaveOfANonSelectedTabKeepsTheCurrentSelection() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        #expect(group.selectedWindow === a)
        Tako.CustomTabGroup.leave(b)
        #expect(group.selectedWindow === a)
    }

    @Test func moveReordersWithinTheGroup() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        let c = makeWindow(title: "c")
        defer {
            for window in [a, b, c] { Tako.CustomTabGroup.leave(window) }
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        Tako.CustomTabGroup.join(c, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        Tako.CustomTabGroup.move(c, to: 0, in: group)
        #expect(group.windows == [c, a, b])

        // Same index is a no-op.
        Tako.CustomTabGroup.move(c, to: 0, in: group)
        #expect(group.windows == [c, a, b])

        // Out of range clamps rather than crashing.
        Tako.CustomTabGroup.move(c, to: 99, in: group)
        #expect(group.windows == [a, b, c])
    }

    @Test func moveOfAWindowNotInTheGroupIsANoOp() {
        let a = makeWindow(title: "a")
        let stray = makeWindow(title: "stray")
        defer {
            Tako.CustomTabGroup.leave(a)
        }
        let group = Tako.CustomTabGroup.group(for: a)
        Tako.CustomTabGroup.move(stray, to: 0, in: group)
        #expect(group.windows == [a])
    }

    @Test func selectIgnoresAWindowOutsideTheGroup() {
        let a = makeWindow(title: "a")
        let stray = makeWindow(title: "stray")
        defer { Tako.CustomTabGroup.leave(a) }
        let group = Tako.CustomTabGroup.group(for: a)
        group.select(stray)
        #expect(group.selectedWindow === a)
    }

    @Test func selectingTheAlreadySelectedWindowJustRaisesIt() {
        let a = makeWindow(title: "a")
        defer { Tako.CustomTabGroup.leave(a) }
        let group = Tako.CustomTabGroup.group(for: a)
        group.select(a)
        #expect(group.selectedWindow === a)
    }

    @Test func syncFrameOnlyPropagatesFromTheSelectedWindow() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: true)
        let group = Tako.CustomTabGroup.group(for: a)

        // b is selected: resizing the non-selected window a must not
        // propagate.
        let untouched = b.frame
        a.setFrame(NSRect(x: 1, y: 1, width: 50, height: 50), display: false)
        group.syncFrame(from: a)
        #expect(b.frame == untouched)

        let resized = NSRect(x: 5, y: 5, width: 300, height: 150)
        b.setFrame(resized, display: false)
        group.syncFrame(from: b)
        #expect(a.frame == resized)
    }

    @Test func rapidSelectIncrementsFocusGenerationAndUpdatesSelection() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        let gen0 = group.focusGeneration
        group.select(b)
        let gen1 = group.focusGeneration
        #expect(gen1 > gen0)
        #expect(group.selectedWindow === b)
        group.select(a)
        let gen2 = group.focusGeneration
        #expect(gen2 > gen1)
        #expect(group.selectedWindow === a)
    }

    @Test func syncWithActiveWorkspaceTwoGroupWorkflow() {
        let a = makeWindow(title: "wsA")
        let b = makeWindow(title: "wsB")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
            Tako.CustomTabGroup.resetForTesting()
            WorkspaceStore.shared.resetForTesting()
        }
        WorkspaceStore.shared.resetForTesting()
        Tako.CustomTabGroup.resetForTesting()

        let wsB = WorkspaceStore.shared.createWorkspace(name: "Beta")
        WorkspaceStore.shared.assignTab(tabIdentifier: a.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        WorkspaceStore.shared.assignTab(tabIdentifier: b.stableTabIdentifier, to: wsB.id)

        // Separate groups (standard multi-workspace topology)
        let groupA = Tako.CustomTabGroup.group(for: a)
        let groupB = Tako.CustomTabGroup.group(for: b)
        #expect(groupA !== groupB)

        let frameA = NSRect(x: 100, y: 200, width: 400, height: 300)
        let frameB = NSRect(x: 200, y: 350, width: 500, height: 350)
        a.setFrame(frameA, display: false)
        b.setFrame(frameB, display: false)
        let actualA = a.frame
        let actualB = b.frame
        #expect(actualA != actualB)

        // 1. By default (syncWindowFrame == false), switching to Workspace B retains Window B's frame
        #expect(groupB.syncWindowFrame == false)
        #expect(WorkspaceStore.shared.switchWorkspace(to: wsB.id))
        #expect(groupA.selectedWindow == nil)
        #expect(groupB.selectedWindow === b)
        #expect(b.frame == actualB)

        // 2. When syncWindowFrame is enabled, the transition coordinator captures departing frame
        // from departing groupA's selected window and syncs groupB without manual injection.
        groupB.syncWindowFrameOverride = true
        #expect(WorkspaceStore.shared.switchWorkspace(to: WorkspaceStore.defaultWorkspaceId))
        #expect(groupA.selectedWindow === a)

        #expect(WorkspaceStore.shared.switchWorkspace(to: wsB.id))
        #expect(groupB.selectedWindow === b)
        #expect(b.frame == actualA)
    }

    @Test func syncFrameMixedGroupPreservesIndependentFramesWhenDisabled() {
        let a = makeWindow(title: "wsA")
        let b = makeWindow(title: "wsB")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
            Tako.CustomTabGroup.resetForTesting()
            WorkspaceStore.shared.resetForTesting()
        }
        WorkspaceStore.shared.resetForTesting()
        Tako.CustomTabGroup.resetForTesting()

        let wsB = WorkspaceStore.shared.createWorkspace(name: "Beta")
        WorkspaceStore.shared.assignTab(tabIdentifier: a.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        WorkspaceStore.shared.assignTab(tabIdentifier: b.stableTabIdentifier, to: wsB.id)

        // Join into same group (mixed-workspace group)
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        let frameA = NSRect(x: 100, y: 200, width: 400, height: 300)
        let frameB = NSRect(x: 200, y: 350, width: 500, height: 350)
        a.setFrame(frameA, display: false)
        b.setFrame(frameB, display: false)
        let actualB = b.frame

        // 1. When disabled, resizing window A does NOT alter window B's geometry
        #expect(group.syncWindowFrame == false)
        let resizedA = NSRect(x: 120, y: 220, width: 450, height: 320)
        a.setFrame(resizedA, display: false)
        group.syncFrame(from: a)
        #expect(b.frame == actualB)

        // 2. When enabled, syncFrame copies window A's frame to window B
        group.syncWindowFrameOverride = true
        group.syncFrame(from: a)
        #expect(b.frame == a.frame)
    }

    @Test func workspaceSwitchUpdatesSelectionAcrossIndependentGroupsOffscreen() {
        let (ctrlA1, winA1) = TerminalTestSupport.loaded()
        let (ctrlA2, winA2) = TerminalTestSupport.loaded()
        let (ctrlB, winB) = TerminalTestSupport.loaded()
        defer {
            for (c, w) in [(ctrlA1, winA1), (ctrlA2, winA2), (ctrlB, winB)] {
                TerminalTestSupport.tearDown(c, w)
                Tako.CustomTabGroup.leave(w)
            }
            Tako.CustomTabGroup.resetForTesting()
            WorkspaceStore.shared.resetForTesting()
        }
        WorkspaceStore.shared.resetForTesting()
        Tako.CustomTabGroup.resetForTesting()
        #expect(Tako.CustomTabGroup.suppressWindowOrderingForTesting)

        // Two separate window groups in Workspace A (default workspace)
        let groupA1 = Tako.CustomTabGroup.group(for: winA1)
        let groupA2 = Tako.CustomTabGroup.group(for: winA2)
        #expect(groupA1 !== groupA2)
        WorkspaceStore.shared.assignTab(tabIdentifier: winA1.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        WorkspaceStore.shared.assignTab(tabIdentifier: winA2.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)

        // One window group in Workspace B
        let wsB = WorkspaceStore.shared.createWorkspace(name: "Beta")
        let groupB = Tako.CustomTabGroup.group(for: winB)
        #expect(groupB !== groupA1 && groupB !== groupA2)
        WorkspaceStore.shared.assignTab(tabIdentifier: winB.stableTabIdentifier, to: wsB.id)

        // Workspace A active: both groupA1 and groupA2 have their respective windows selected
        #expect(groupA1.selectedWindow === winA1)
        #expect(groupA2.selectedWindow === winA2)

        // Switch to Workspace B: groupA1 and groupA2 clear selection, groupB selects winB
        #expect(WorkspaceStore.shared.switchWorkspace(to: wsB.id))
        #expect(groupA1.selectedWindow == nil)
        #expect(groupA2.selectedWindow == nil)
        #expect(groupB.selectedWindow === winB)

        // Switch back to Workspace A: both destination groups restore their selected windows offscreen
        #expect(WorkspaceStore.shared.switchWorkspace(to: WorkspaceStore.defaultWorkspaceId))
        #expect(groupA1.selectedWindow === winA1)
        #expect(groupA2.selectedWindow === winA2)
        #expect(groupB.selectedWindow == nil)
    }
}

