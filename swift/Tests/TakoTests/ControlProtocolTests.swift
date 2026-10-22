/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation
import Testing
@testable import Tako

@Suite
struct ControlProtocolTests {
    @Test func requestsParse() throws {
        let r = try ControlRequest.parse(Data(#"{"cmd":"tree","args":{"target":"ab"},"from":"\#(a.uuidString)"}"#.utf8))
        #expect(r.cmd == "tree")
        #expect(r.args["target"] == .string("ab"))
        #expect(r.from == a)
        #expect(try ControlRequest.parse(Data(#"{"cmd":"version"}"#.utf8)).from == nil)
    }

    @Test func badRequestsAreRefusedNotGuessed() {
        for bad in [#"nope"#, #"[1]"#, #"{"args":{}}"#, #"{"cmd":"tree","args":[]}"#,
                    #"{"cmd":"tree","from":"not-a-uuid"}"#, #"{"cmd":"tree","from":5}"#] {
            #expect(throws: ControlError.self) { try ControlRequest.parse(Data(bad.utf8)) }
        }
        let huge = Data(repeating: 0x20, count: ControlProtocol.maxRequestBytes + 1)
        #expect(throws: ControlError.self) { try ControlRequest.parse(huge) }
    }

    @Test func responsesAreOneJSONLine() throws {
        let ok = ControlResponse.ok(["id": .string("x")]).encoded()
        #expect(ok.last == 0x0A)
        let failure = ControlResponse.failure(ControlError(.ambiguous, "two", candidates: ["p", "q"])).encoded()
        let object = try JSONSerialization.jsonObject(with: failure) as! [String: Any]
        #expect(object["ok"] as? Bool == false)
        let error = object["error"] as! [String: Any]
        #expect(error["code"] as? String == "ambiguous")
        #expect(error["candidates"] as? [String] == ["p", "q"])
    }

    @Test func targetsResolveToOnePaneOrFail() throws {
        let panes = [a, a2, b]
        func resolve(_ target: String?, from: UUID? = nil, active: UUID? = b) throws -> UUID {
            let args: [String: JSON] = target.map { ["target": .string($0)] } ?? [:]
            return try ControlTarget.from(args, requestFrom: from).resolve(panes: panes, requestFrom: from, active: active)
        }
        #expect(try resolve(a.uuidString) == a)
        #expect(try resolve("bbbb") == b)
        #expect(try resolve(nil, from: a2) == a2)          // default: the client's own pane
        #expect(try resolve(nil) == b)                     // outside a pane: the active one
        #expect(try resolve("active", from: a) == b)
        #expect(try resolve("self", from: a) == a)
        #expect(throws: ControlError(.ambiguous, "2 panes match aaaa",
                                     candidates: [a.uuidString.lowercased(), a2.uuidString.lowercased()])) {
            try resolve("aaaa")
        }
        #expect(throws: ControlError.self) { try resolve("cccc") }
        // The pane a request came from is gone: notFound, never the active one.
        let gone = UUID()
        #expect(throws: ControlError(.notFound, "the pane this request came from is gone")) {
            try resolve(nil, from: gone)
        }
        #expect(throws: ControlError.self) { try resolve("self") }
    }

    @Test func theSettingGatesWhereRequestsComeFrom() {
        #expect(RemoteControlMode.local.allows(from: a, panes: [a]))
        #expect(!RemoteControlMode.local.allows(from: nil, panes: [a]))
        #expect(!RemoteControlMode.local.allows(from: b, panes: [a]))
        #expect(RemoteControlMode.on.allows(from: nil, panes: []))
        #expect(!RemoteControlMode.off.allows(from: a, panes: [a]))
    }

    @Test func requestParsesTheClientName() throws {
        let req = try ControlRequest.parse(Data(#"{"cmd":"notify","client":"bot-1"}"#.utf8))
        #expect(req.client == "bot-1")
        let inArgs = try ControlRequest.parse(Data(#"{"cmd":"status","args":{"client":"bot-2"}}"#.utf8))
        #expect(inArgs.client == "bot-2")
        #expect(throws: ControlError.self) {
            try ControlRequest.parse(Data(#"{"cmd":"status","client":7}"#.utf8))
        }
    }
}
