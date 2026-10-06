/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CryptoKit
import Darwin
import Foundation

/// The listening end of `takoctl`: a unix socket only this user can open.
///
/// Requests are read and answered on background threads; only the work a
/// request asks for runs on the main thread, through `handler`. Every stage
/// is bounded: connections at once, requests waiting for the main thread,
/// the time to send a request and to take its answer.
final class ControlServer: @unchecked Sendable {
    /// Connections served at once; more are answered `busy`.
    static let maxConnections = 32
    /// Requests waiting for, or running on, the main thread.
    static let maxMainBacklog = 64
    /// How long a client has, in all, to send its request, and to take the
    /// answer -- whole-operation deadlines, not per-call timeouts, so a
    /// client trickling a byte at a time cannot hold a connection.
    static let readTimeout: TimeInterval = 5
    static let writeTimeout: TimeInterval = 10
    /// How long a request may wait for the main thread before it is dropped
    /// unrun -- less than takoctl's own deadline, so the client hears "not
    /// run" rather than timing out on a request that might still run.
    static let mainWait: TimeInterval = 15

    typealias Handler = @MainActor (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void

    let path: String
    let handler: Handler
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "tako.control.accept")
    let lock = NSLock()
    var connections = 0      // under lock
    var mainBacklog = 0      // under lock
    /// Clients being served, so stopping can cut them off. Each fd is closed
    /// only by its own `finish`.
    var clients = Set<Int32>()   // under lock
    /// Set once by `stop`: nothing this server took is served after it.
    var stopped = false          // under lock
    /// The socket file this server made, to remove only that one on stop.
    private var boundInode: ino_t = 0
    /// `<path>.lock`, held exclusively for as long as this server listens.
    private var ownerLock: Int32 = -1

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    // MARK: - Where the socket lives

    /// The socket for the app with `bundleID`: in this user's private
    /// temporary directory (0700, owned by the user), named after the bundle
    /// id so each build of Tako has its own. The same for `takoctl`, which
    /// gets the path from `TAKO_SOCKET` inside a pane and works it out the
    /// same way outside one.
    static func socketPath(bundleID: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            throw ControlError(.internalError, "no per-user temporary directory")
        }
        let dir = String(cString: buffer)
        let digest = SHA256.hash(data: Data(bundleID.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = (dir as NSString).appendingPathComponent("tako-ctl-\(digest.prefix(12)).sock")
        try checkLength(path)
        return path
    }

    /// A unix socket path must fit `sockaddr_un.sun_path`, in bytes.
    static func checkLength(_ path: String) throws {
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < limit else {
            throw ControlError(.internalError, "socket path is \(path.utf8.count) bytes; the limit is \(limit - 1)")
        }
    }

    /// The directory must be a real directory, this user's, closed to others.
    static func checkDirectory(_ dir: String) throws {
        var st = stat()
        guard lstat(dir, &st) == 0 else { throw ControlError(.internalError, "cannot stat \(dir)") }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            throw ControlError(.internalError, "\(dir) is not a directory")
        }
        guard st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw ControlError(.internalError, "\(dir) is not private to this user")
        }
    }

    // MARK: - Starting and stopping

    enum StartResult: Equatable {
        case listening
        /// Another copy of Tako already answers on this socket; it keeps it.
        case taken
    }

    /// Binds and starts accepting.
    ///
    /// Ownership is a lock, not a probe: whoever holds `<path>.lock` serves
    /// the socket, for as long as it runs. A copy that cannot take the lock
    /// leaves everything alone -- a live server that is merely slow to answer
    /// is never mistaken for a dead one. With the lock held, a socket file
    /// still there was left by a server that is gone, and only one that is
    /// this user's socket is removed.
    func start() throws -> StartResult {
        try Self.checkLength(path)
        try Self.checkDirectory((path as NSString).deletingLastPathComponent)

        let lockFD = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw ControlError(.internalError, "cannot open the socket lock: \(errno)") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let e = errno
            close(lockFD)
            if e == EWOULDBLOCK { return .taken }
            throw ControlError(.internalError, "cannot lock the socket: \(e)")
        }
        var started = false
        defer { if !started { close(lockFD) } }

        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else {
                throw ControlError(.internalError, "\(path) exists and is not this user's socket")
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError(.internalError, "socket: \(errno)") }
        var address = Self.address(path)
        // Created 0600 from the start: no window in which it is open to others.
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw ControlError(.internalError, "bind: \(e)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            throw ControlError(.internalError, "listen: \(errno)")
        }
        if lstat(path, &st) == 0 { boundInode = st.st_ino }
        // Also on the listener: accepted sockets inherit it.
        Self.prepare(fd)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        ownerLock = lockFD
        started = true
        return .listening
    }

    /// Stops accepting and removes the socket file -- only if it is still the
    /// one this server bound.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        // Requests already accepted die with this server: their sockets are
        // shut down (each is closed by its own finish) and work queued for
        // the main thread is refused when it runs. A later server, even with
        // the same path and a more permissive setting, never answers them.
        lock.withLock {
            stopped = true
            for fd in clients { shutdown(fd, SHUT_RDWR) }
        }
        var st = stat()
        if boundInode != 0, lstat(path, &st) == 0, st.st_ino == boundInode {
            unlink(path)
        }
        boundInode = 0
        // Released last: the next owner finds no socket of ours to clear.
        if ownerLock >= 0 {
            close(ownerLock)
            ownerLock = -1
        }
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }   // EAGAIN: no more for now
            // Before anything can be written to it: no SIGPIPE from a peer
            // that is gone, and no write that can block. A client that left
            // before it was accepted may refuse the option; nothing is
            // written to one that did -- it is closed unanswered.
            guard Self.prepare(client) else {
                close(client)
                continue
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            let admitted = lock.withLock {
                guard !stopped, connections < Self.maxConnections else { return false }
                connections += 1
                clients.insert(client)
                return true
            }
            guard admitted else {
                // One nonblocking attempt: the refusal never holds up accepting.
                Self.send(.failure(ControlError(.busy, "too many connections")), to: client,
                          deadline: .now(), once: true)
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
