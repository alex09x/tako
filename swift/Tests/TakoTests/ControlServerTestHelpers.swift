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

let a = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
let a2 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
let b = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!

/// A private directory like the per-user temporary one: 0700, ours.
func privateDir() throws -> String {
    var template = Array((NSTemporaryDirectory() + "tkc.XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
    let dir = String(cString: template)
    chmod(dir, 0o700)
    return dir
}

/// The test's own client sockets: a write to one the server closed must
/// not kill the test process. Set per socket -- the process-wide
/// disposition stays as it is, so the server's own protection is what is
/// being tested.
func noSigpipe(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

func connectTo(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    noSigpipe(fd)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8); raw.copyBytes(from: bytes); raw[bytes.count] = 0
    }
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    return fd
}

/// One request over the socket, as takoctl sends it.
func ask(_ path: String, _ line: String) async throws -> [String: Any] {
    try await Task.detached {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        noSigpipe(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let out = Array((line + "\n").utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }.value
}

