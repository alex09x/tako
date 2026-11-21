// tako — PTY reader lifetime and shared work-pool liveness
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct PTYReaderLivenessTests {
    @Test func releasingTheLastOwnerEndsAnIdleReader() throws {
        var owner: PTY? = try #require(PTY(cols: 80, rows: 24, program: ["/bin/cat"]))
        weak var reader = owner
        let exited = DispatchSemaphore(value: 0)
        owner?.readLoop(targetQueue: .global(qos: .userInitiated),
                        onData: { _ in }, onExit: { exited.signal() })
        owner = nil
        defer { reader?.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while reader != nil && Date() < deadline { usleep(1_000) }
        #expect(reader == nil, "The blocking reader must not retain its PTY owner")
        #expect(exited.wait(timeout: .now() + 1) == .success, "Owner release must end the idle read")
    }

    @Test func idleReadersLeaveTheSharedWorkPoolResponsive() throws {
        var readers: [PTY] = []
        defer { for reader in readers { reader.terminate() } }
        // The hosted stall reached libdispatch's 64-thread soft limit.
        // Each cat is owned by this test and produces no background output.
        for _ in 0..<80 {
            let reader = try #require(PTY(cols: 80, rows: 24, program: ["/bin/cat"]))
            readers.append(reader)
            reader.readLoop(targetQueue: .global(qos: .userInitiated), onData: { _ in }, onExit: {})
        }
        let heartbeat = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { heartbeat.signal() }
        #expect(heartbeat.wait(timeout: .now() + 1) == .success,
                "Idle terminal readers must not starve unrelated shared-queue work")
    }
}
