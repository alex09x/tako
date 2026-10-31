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

struct SessionSocketPreservationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKO_TEST_NEW_ZMX"] != nil))
    func listingDoesNotUnlinkAnUnresponsiveSessionSocket() throws {
        let runtime = try #require(ProcessInfo.processInfo.environment["TAKO_TEST_NEW_ZMX"])
        let home = Home()
        defer { home.tearDown() }
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        let path = namespace.socketPath(for: SessionNamespace.sessionName(for: UUID()))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        #expect(bound == 0)
        guard bound == 0 else { return }
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)
        let result = RuntimeCommand.run(URL(fileURLWithPath: runtime), ["list"], environment: namespace.environment)
        #expect(result != nil)
        #expect(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)
    }
}
