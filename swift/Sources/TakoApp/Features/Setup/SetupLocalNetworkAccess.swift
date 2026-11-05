// Tako — user-initiated local network consent trigger
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Darwin

enum SetupLocalNetworkAccess {
    /// Best-effort UDP connect technique documented in Apple TN3179.
    /// No send, discovery, or incoming-data operation is performed.
    /// A connect attempt does not establish that permission was granted.
    static func request() -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return false }
        defer { freeifaddrs(interfaces) }
        var attempted = false
        for entry in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                  let pointer = entry.pointee.ifa_addr,
                  pointer.pointee.sa_family == AF_INET6,
                  Int(pointer.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { continue }
            let local = UnsafeRawPointer(pointer).load(as: sockaddr_in6.self)
            let linkLocal = withUnsafeBytes(of: local.sin6_addr) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
            guard linkLocal else { continue }
            for _ in 0..<2 {
                var target = local
                target.sin6_port = UInt16(9).bigEndian
                withUnsafeMutableBytes(of: &target.sin6_addr) { bytes in
                    for index in 8..<16 { bytes[index] = UInt8.random(in: .min ... .max) }
                }
                let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
                guard descriptor >= 0 else { continue }
                withUnsafePointer(to: &target) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = connect(descriptor, $0, socklen_t($0.pointee.sa_len))
                    }
                }
                close(descriptor)
                attempted = true
            }
        }
        return attempted
    }
}
