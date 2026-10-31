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

struct SessionProfileLeaseTests {
    @Test func onlyOneInstanceCanWriteAProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: SessionProfileLease? = try SessionProfileLease(directory: directory)
        #expect(first != nil)
        #expect(throws: (any Error).self) { try SessionProfileLease(directory: directory) }
        first = nil
        #expect((try? SessionProfileLease(directory: directory)) != nil)
    }
}
