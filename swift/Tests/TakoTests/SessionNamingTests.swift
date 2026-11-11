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
import Testing
@testable import Tako

/// The names the owner agreed for sessions and their terminals.
struct SessionNamingTests {
    typealias N = SessionNaming
    private let home = NSHomeDirectory()

    @Test func oneTerminalKeepsTodaysTitle() {
        #expect(N.sessionName(override: nil, single: "claude · auth", terminals: [.init(title: "claude · auth", directory: "/tmp")]) == "claude · auth")
    }

    @Test func aGivenNameWinsUntilItIsCleared() {
        let two: [N.Terminal] = [.init(title: "a", directory: "/x"), .init(title: "b", directory: "/y")]
        #expect(N.sessionName(override: "deploy", single: "a", terminals: two) == "deploy")
        #expect(N.sessionName(override: "  ", single: "a", terminals: two) == "a +1", "blank is no name")
    }

    @Test func terminalsInOneProjectAreNamedByIt() {
        let tako = home + "/CLionProjects/tako"
        let terminals: [N.Terminal] = [.init(title: "fish", directory: tako), .init(title: "npm run dev", directory: tako + "/web")]
        #expect(N.sessionName(override: nil, single: "fish", terminals: terminals) == "tako")
        #expect(N.sessionName(override: nil, single: "fish", terminals: [.init(title: "fish", directory: tako), .init(title: "x", directory: tako)]) == "tako")
    }

    @Test func otherwiseTheFirstTerminalAndHowManyMore() {
        let spread: [N.Terminal] = [.init(title: "claude · auth", directory: home + "/a"), .init(title: "ssh", directory: home + "/b"),
                                    .init(title: "top", directory: nil)]
        #expect(N.sessionName(override: nil, single: "ssh", terminals: spread) == "claude · auth +2")
        // Sharing only home or / is no project.
        #expect(N.sharedFolder([home + "/a", home + "/b"]) == nil)
        #expect(N.sharedFolder(["/tmp/a", "/var/b"]) == nil)
        #expect(N.sharedFolder(["/Volumes/work/p", "/Volumes/work/p/q"]) == "p")
    }

    @Test func aTerminalWithNothingToSayIsTerminalN() {
        #expect(N.fallbackTerminalName(index: 0) == "Terminal 1")
        #expect(N.fallbackTerminalName(index: 2) == "Terminal 3")
    }
}
