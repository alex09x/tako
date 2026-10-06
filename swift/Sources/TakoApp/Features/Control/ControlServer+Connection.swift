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

extension ControlServer {
    func serve(_ client: Int32) {
        var closed = false
        let closeLock = NSLock()
        let streamClose: @Sendable () -> Void = { [self] in
            let shouldClose = closeLock.withLock { () -> Bool in
                if closed { return false }
                closed = true
                return true
            }
            guard shouldClose else { return }
            lock.withLock {
                clients.remove(client)
                connections -= 1
            }
            close(client)
        }
        let finish: @Sendable (ControlResponse) -> Void = { [self] response in
            Self.send(response, to: client, deadline: .now() + Self.writeTimeout)
            streamClose()
        }
        let gone = ControlResponse.failure(ControlError(.disabled, "remote control stopped"))
        var request: ControlRequest
        do {
            request = try ControlRequest.parse(try Self.readRequest(client, deadline: .now() + Self.readTimeout))
            request.clientFD = client
            request.onStreamClose = streamClose
            // Only while the connection is this server's: once answered, the
            // descriptor is closed and its number may be another file's.
            request.clientGone = { [self] in
                lock.withLock { !clients.contains(client) } || Self.clientGone(client)
            }
        } catch let error as ControlError {
            finish(.failure(error))
            return
        } catch {
            finish(.failure(ControlError(.internalError, "\(error)")))
            return
        }
        if lock.withLock({ stopped }) {
            finish(gone)
            return
        }
        let queued = lock.withLock {
            guard mainBacklog < Self.maxMainBacklog else { return false }
            mainBacklog += 1
            return true
        }
        guard queued else {
            finish(.failure(ControlError(.busy, "too many requests waiting")))
            return
        }
        let handler = self.handler
        let queuedAt = DispatchTime.now()
        DispatchQueue.main.async { [self] in
            let isStopped = lock.withLock {
                mainBacklog -= 1
                return stopped
            }
            if isStopped {
                DispatchQueue.global(qos: .userInitiated).async { finish(gone) }
                return
            }
            // Work that has not started is not started late: not for a
            // client that has gone, nor after the client's own deadline,
            // when it would already have given up and might send it again.
            if Self.clientGone(client) {
                DispatchQueue.global(qos: .userInitiated).async { finish(gone) }
                return
            }
            if DispatchTime.now() > queuedAt + Self.mainWait {
                DispatchQueue.global(qos: .userInitiated).async {
                    finish(.failure(ControlError(.timeout,
                        "not run: Tako was busy for \(Int(Self.mainWait)) s; nothing was done")))
                }
                return
            }
            MainActor.assumeIsolated {
                handler(request) { response in
                    // Answered off the main thread: a client slow to read
                    // never holds it.
                    DispatchQueue.global(qos: .userInitiated).async { finish(response) }
                }
            }
        }
    }

    /// Waits until `fd` is ready for `events` or `deadline` passes.
    static func ready(_ fd: Int32, _ events: Int16, by deadline: DispatchTime) -> Bool {
        while true {
            let now = DispatchTime.now()
            guard deadline > now else { return false }
            let left = (deadline.uptimeNanoseconds - now.uptimeNanoseconds + 999_999) / 1_000_000
            var p = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&p, 1, Int32(min(left, UInt64(Int32.max))))
            if n > 0 { return true }
            if n == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// One request: bytes up to the first newline or end of input, all of it
    /// by `deadline`.
    static func readRequest(_ fd: Int32, deadline: DispatchTime) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            // Checked before every read and every retry, not only when the
            // socket has nothing: data that keeps arriving does not extend it.
            guard DispatchTime.now() < deadline else {
                throw ControlError(.timeout, "no complete request within \(Int(readTimeout)) s")
            }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                    data.append(contentsOf: chunk[0..<newline])
                    break
                }
                data.append(contentsOf: chunk[0..<n])
                if data.count > ControlProtocol.maxRequestBytes {
                    throw ControlError(.invalid, "request larger than \(ControlProtocol.maxRequestBytes) bytes")
                }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                guard ready(fd, Int16(POLLIN), by: deadline) else {
                    throw ControlError(.timeout, "no complete request within \(Int(readTimeout)) s")
                }
            } else {
                throw ControlError(.internalError, "read: \(errno)")
            }
        }
        return data
    }

    /// Writes as much of the answer as the client takes by `deadline`; a
    /// client that does not read is dropped then.
    static func send(_ response: ControlResponse, to fd: Int32, deadline: DispatchTime,
                     once: Bool = false) {
        let data = response.encoded()
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                // One attempt for a refusal; otherwise never past the deadline.
                guard once || DispatchTime.now() < deadline else { return }
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if once { return }
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard ready(fd, Int16(POLLOUT), by: deadline) else { return }
                } else {
                    return
                }
            }
        }
    }

    /// Whether the client has closed or reset its end.
    static func clientGone(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return false }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK) == 0
    }

    /// Nonblocking, close-on-exec, and no SIGPIPE. False when the socket
    /// would not take SO_NOSIGPIPE, which makes writing to it unsafe.
    @discardableResult
    static func prepare(_ fd: Int32) -> Bool {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSigpipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }
        var set: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &set, &size) == 0 && set != 0
    }
}
