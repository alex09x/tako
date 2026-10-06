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

    @Test func requestParsesClientAndScopes() throws {
        // 1. Array of scopes and token
        let req1 = try ControlRequest.parse(Data(#"{"cmd":"notify","client":"bot-1","token":"my-token","scopes":["signal","read"]}"#.utf8))
        #expect(req1.client == "bot-1")
        #expect(req1.token == "my-token")
        #expect(req1.requestedScopes == [.signal, .read])
        #expect(req1.scopes == nil)

        // 2. Comma-separated string of scopes
        let req2 = try ControlRequest.parse(Data(#"{"cmd":"notify","scopes":"signal, input"}"#.utf8))
        #expect(req2.requestedScopes == [.signal, .input])

        // 3. Scopes inside args
        let req3 = try ControlRequest.parse(Data(#"{"cmd":"status","args":{"scopes":"layout"}}"#.utf8))
        #expect(req3.requestedScopes == [.layout])

        // 4. Client inside args
        let req4 = try ControlRequest.parse(Data(#"{"cmd":"status","args":{"client":"sub-agent"}}"#.utf8))
        #expect(req4.client == "sub-agent")

        // 5. Unknown scope throws invalid error
        #expect(throws: ControlError.self) {
            try ControlRequest.parse(Data(#"{"cmd":"status","scopes":["unknownScope"]}"#.utf8))
        }

        // 6. Non-string scope item throws invalid error
        #expect(throws: ControlError.self) {
            try ControlRequest.parse(Data(#"{"cmd":"status","scopes":[123]}"#.utf8))
        }
    }

    @Test func responseIncludesScopeOnMissingScopeError() throws {
        let err = ControlError(.missingScope, "requires signal scope", scope: "signal")
        let failure = ControlResponse.failure(err).encoded()
        let object = try JSONSerialization.jsonObject(with: failure) as! [String: Any]
        #expect(object["ok"] as? Bool == false)
        let error = object["error"] as! [String: Any]
        #expect(error["code"] as? String == "missingScope")
        #expect(error["scope"] as? String == "signal")
    }

    @Test func controlScopeRequiredMapping() {
        #expect(ControlScope.required(for: "version").isEmpty)

        // read
        for cmd in ["tree", "text", "last", "find", "events", "screenshot", "history"] {
            #expect(ControlScope.required(for: cmd) == [.read])
        }
        #expect(ControlScope.required(for: "activity") == [.read])
        #expect(ControlScope.required(for: "activity", args: ["action": .string("get")]) == [.read])
        #expect(ControlScope.required(for: "activity", args: ["action": .string("export")]) == [.read])
        #expect(ControlScope.required(for: "activity", args: ["action": .string("clear")]) == [.approval])
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("status")]) == [.read])
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("log")]) == [.read])
        #expect(ControlScope.required(for: "review") == [.read])

        // input
        for cmd in ["send", "type", "key", "broadcast"] {
            #expect(ControlScope.required(for: cmd) == [.input])
        }
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("lock")]) == [.input])
        #expect(ControlScope.required(for: "review", args: ["subcommand": .string("send")]) == [.input])

        // approval (Track G1 P1 findings: cannot self-approve automation or issue grants with ordinary input)
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("allow-automation")]) == [.approval])
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("disallow-automation")]) == [.approval])
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("confirm-automation")]) == [.approval])
        #expect(ControlScope.required(for: "grant") == [.approval])
        #expect(ControlScope.required(for: "grant", args: ["subcommand": .string("request")]) == [])
        #expect(ControlScope.required(for: "grant", args: ["subcommand": .string("create")]) == [.approval])
        #expect(ControlScope.required(for: "grant", args: ["subcommand": .string("revoke")]) == [.approval])
        #expect(ControlScope.required(for: "grant", args: ["subcommand": .string("list")]) == [.approval])

        // run requires both layout and input (execution authority)
        #expect(ControlScope.required(for: "run") == [.layout, .input])
        #expect(ControlScope.required(for: "tab-new", args: ["argv": .array([.string("echo")])]) == [.layout, .input])
        #expect(ControlScope.required(for: "split", args: ["argv": .array([.string("ls")])]) == [.layout, .input])

        // layout
        for cmd in ["tab-new", "split", "close", "focus", "collapse", "expand", "workspace", "layout", "action", "task", "session", "wait", "resume"] {
            #expect(ControlScope.required(for: cmd) == [.layout])
        }

        // signal
        for cmd in ["notify", "status", "progress", "ask", "title", "triggers"] {
            #expect(ControlScope.required(for: cmd) == [.signal])
        }

        // overlay
        for cmd in ["dialog", "overlay"] {
            #expect(ControlScope.required(for: cmd) == [.overlay])
        }
    }

    @Test func serverSideGrantAndAuthorizationGate() throws {
        // 1. Unauthenticated client without token fails closed on any scoped command
        let unauth = try ControlRequest.parse(Data(#"{"cmd":"text"}"#.utf8))
        let authUnauth = ControlCommands.authorize(unauth)
        #expect(authUnauth.scopes == [])
        #expect(throws: ControlError.self) { try ControlCommands.checkScope(for: authUnauth) }

        // 2. Client attempting to self-assert scopes in JSON payload without grant fails closed
        let selfAssert = try ControlRequest.parse(Data(#"{"cmd":"text","scopes":["read","input"]}"#.utf8))
        let authSelf = ControlCommands.authorize(selfAssert)
        #expect(authSelf.scopes == [])
        #expect(throws: ControlError.self) { try ControlCommands.checkScope(for: authSelf) }

        // 3. Issue a server-side grant with signal scope only
        let grant = ControlGrantStore.shared.issueGrant(client: "signal-bot", scopes: [.signal])
        let reqSig = try ControlRequest.parse(Data(#"{"cmd":"status","token":"\#(grant.token)"}"#.utf8))
        let authSig = ControlCommands.authorize(reqSig)
        #expect(authSig.client == "signal-bot")
        #expect(authSig.scopes == [.signal])
        #expect(throws: Never.self) { try ControlCommands.checkScope(for: authSig) }

        // Signal client fails on read command
        let reqRead = try ControlRequest.parse(Data(#"{"cmd":"text","token":"\#(grant.token)"}"#.utf8))
        let authRead = ControlCommands.authorize(reqRead)
        do {
            try ControlCommands.checkScope(for: authRead)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "read")
        }

        // Signal client fails on input command
        let reqType = try ControlRequest.parse(Data(#"{"cmd":"type","token":"\#(grant.token)"}"#.utf8))
        let authType = ControlCommands.authorize(reqType)
        do {
            try ControlCommands.checkScope(for: authType)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "input")
        }

        // 4. Client with only layout scope fails on run because run requires execution authority (input)
        let layoutGrant = ControlGrantStore.shared.issueGrant(client: "layout-bot", scopes: [.layout])
        let reqRun = try ControlRequest.parse(Data(#"{"cmd":"run","token":"\#(layoutGrant.token)"}"#.utf8))
        let authRun = ControlCommands.authorize(reqRun)
        do {
            try ControlCommands.checkScope(for: authRun)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "input")
        }

        // 5. Client with input scope cannot self-approve pane automation switch
        let inputGrant = ControlGrantStore.shared.issueGrant(client: "input-bot", scopes: [.input])
        let reqApprove = try ControlRequest.parse(Data(#"{"cmd":"input","token":"\#(inputGrant.token)","args":{"subcommand":"confirm-automation"}}"#.utf8))
        let authApprove = ControlCommands.authorize(reqApprove)
        do {
            try ControlCommands.checkScope(for: authApprove)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "approval")
        }

        // 6. Client with approval scope can approve automation and issue grants
        let adminGrant = ControlGrantStore.shared.issueGrant(client: "admin-bot", scopes: [.approval])
        let reqAdmin = try ControlRequest.parse(Data(#"{"cmd":"input","token":"\#(adminGrant.token)","args":{"subcommand":"confirm-automation"}}"#.utf8))
        let authAdmin = ControlCommands.authorize(reqAdmin)
        #expect(throws: Never.self) { try ControlCommands.checkScope(for: authAdmin) }

        // 7. General pane caller without a token fails closed with missingScope
        let reqNoToken = try ControlRequest.parse(Data(#"{"cmd":"text"}"#.utf8))
        let authNoToken = ControlCommands.authorize(reqNoToken)
        do {
            try ControlCommands.checkScope(for: authNoToken)
            #expect(Bool(false), "Should have failed without grant token")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "read")
        }
    }
}

@Suite(.serialized)
@MainActor
