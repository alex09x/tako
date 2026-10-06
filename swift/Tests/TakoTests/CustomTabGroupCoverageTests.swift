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

@Suite
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
}

