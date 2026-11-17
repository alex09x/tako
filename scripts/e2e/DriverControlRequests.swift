/*
 * tako — Prepared public control requests for native race tests
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
import CryptoKit
import Darwin
import Foundation

/// The same one-JSON-line-per-connection protocol as takoctl. Connections
/// and validation precede the timing window; no CLI startup lies between
/// the two requests. No failed/possibly-admitted request is retried.
enum ControlRequestSocket {
    static let maxBytes = 1 << 20
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func path(bundleID: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            throw Failure("no private control-socket directory")
        }
        let digest = SHA256.hash(data: Data(bundleID.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent("tako-ctl-\(digest.prefix(12)).sock").path
    }

    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure("control socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func ready(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while now < deadline {
            var item = pollfd(fd: fd, events: events, revents: 0)
            let timeout = Int32(max(1, min(1000, ceil((deadline - now) * 1000))))
            let count = poll(&item, 1, timeout)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure("control socket poll failed: \(errno)")
            }
            if count > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw Failure("invalid control socket") }
                if item.revents & events != 0 || (events == Int16(POLLIN) && item.revents & Int16(POLLHUP) != 0) { return }
                if item.revents & Int16(POLLERR | POLLHUP) != 0 { throw Failure("control socket closed or failed") }
            }
        }
        throw Failure("control request deadline expired; not retried")
    }

    static func open(_ path: String, expectedPID: pid_t, deadline: TimeInterval) throws -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw Failure("control endpoint is not this user's plain socket")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("could not create control socket: \(errno)") }
        var transferred = false
        defer { if !transferred { close(fd) } }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure("could not make control socket nonblocking") }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure("could not suppress SIGPIPE on control socket")
        }
        var endpoint = try address(path)
        let connected = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw Failure("control connect failed: \(errno)") }
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw Failure("control connect did not complete: \(error)")
            }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer == expectedPID else {
            throw Failure("control socket peer \(peer) is not owned fixture pid \(expectedPID)")
        }
        transferred = true
        return fd
    }

    static func encode(_ request: [String: Any]) throws -> Data {
        guard let command = request["cmd"] as? String, !command.isEmpty,
              JSONSerialization.isValidJSONObject(request) else { throw Failure("invalid control request") }
        var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard data.count < maxBytes else { throw Failure("control request is too large") }
        data.append(0x0a)
        return data
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxBytes, let newline = data.firstIndex(of: 0x0a),
              data.dropFirst(newline + 1).allSatisfy({ [9, 10, 13, 32].contains($0) }),
              let response = try JSONSerialization.jsonObject(with: data.prefix(newline)) as? [String: Any],
              let ok = response["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else {
            throw Failure("malformed control response")
        }
        guard ok.boolValue else { throw Failure("control request refused: \(String(describing: response["error"]))") }
        guard response.keys.contains("result") else { throw Failure("control success has no result") }
        return response
    }

    static func exchange(_ fd: Int32, request: Data, deadline: TimeInterval) throws -> [String: Any] {
        var written = 0
        while written < request.count {
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = request.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: written), request.count - written, 0) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw Failure("control write failed; not retried: \(errno)") }
            written += count
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxBytes {
            try ready(fd, events: Int16(POLLIN), deadline: deadline)
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw Failure("control peer closed without a complete reply") }
            data.append(contentsOf: buffer.prefix(count))
            if data.contains(0x0a) { return try decode(data) }
        }
        throw Failure("control response is too large")
    }
}

extension Driver {
    /// Sequential admitted commands, as before, with both local sockets
    /// prepared before the clock starts. Existing app-side history checks
    /// still prove exact transitions and their unchanged140ms interval.
    func controlPair(_ first: [String: Any], _ second: [String: Any]) throws -> (first: TimeInterval, second: TimeInterval) {
        guard let owned = ownedApps.last(where: { $0.pid == pid }),
              case .running(let current) = identify(pid), current == owned.birth else {
            throw Failure("control race has no current owned app identity")
        }
        let requests = try [first, second].map(ControlRequestSocket.encode)
        let path = try ControlRequestSocket.path(bundleID: bundleID)
        let deadline = ControlRequestSocket.now + 5
        var sockets: [Int32] = []
        defer { sockets.forEach { close($0) } }
        for _ in requests { sockets.append(try ControlRequestSocket.open(path, expectedPID: pid, deadline: deadline)) }
        guard case .running(let prepared) = identify(pid), prepared == owned.birth else {
            throw Failure("owned app identity changed while preparing control race")
        }
        let firstSent = ControlRequestSocket.now
        _ = try ControlRequestSocket.exchange(sockets[0], request: requests[0], deadline: deadline)
        let secondSent = ControlRequestSocket.now
        _ = try ControlRequestSocket.exchange(sockets[1], request: requests[1], deadline: deadline)
        print(String(format: "prepared control requests sent %.3fms apart; both replies admitted", (secondSent - firstSent) * 1000))
        return (firstSent, secondSent)
    }
}
